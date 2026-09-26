#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <intrin.h>
#include <lmcons.h>
#include <shlobj.h>

#include "machine.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace machine_env {
namespace {

namespace fs = std::filesystem;
constexpr char kServerVersion[] = "0.2.0";
constexpr int kDefaultTtl = 24 * 60 * 60;
constexpr int kNetworkTtl = 10 * 60;

std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()), nullptr,
                                         0, nullptr, nullptr);
    if (size <= 0) return {};
    std::string result(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), size,
                        nullptr, nullptr);
    return result;
}

std::wstring wide(const std::string& value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()), nullptr,
                                         0);
    if (size <= 0) return {};
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), size);
    return result;
}

std::wstring environment_variable(const wchar_t* name) {
    const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
    if (!size) return {};
    std::wstring result(size, L'\0');
    const DWORD written = GetEnvironmentVariableW(name, result.data(), size);
    if (!written || written >= size) return {};
    result.resize(written);
    return result;
}

std::wstring quote_argument(const std::wstring& value) {
    if (value.find_first_of(L" \t\n\v\"") == std::wstring::npos) return value;
    std::wstring result = L"\"";
    unsigned backslashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') {
            ++backslashes;
        } else if (ch == L'"') {
            result.append(backslashes * 2 + 1, L'\\');
            result.push_back(ch);
            backslashes = 0;
        } else {
            result.append(backslashes, L'\\');
            backslashes = 0;
            result.push_back(ch);
        }
    }
    result.append(backslashes * 2, L'\\');
    result.push_back(L'"');
    return result;
}

struct ProcessResult {
    bool ok = false;
    std::string output;
    std::string error;
    DWORD exit_code = 0;
};

ProcessResult run_process(const std::wstring& executable,
                         const std::wstring& arguments,
                         DWORD timeout_ms = 5000) {
    ProcessResult result;
    SECURITY_ATTRIBUTES security{};
    security.nLength = sizeof(security);
    security.bInheritHandle = TRUE;
    HANDLE read_pipe = nullptr;
    HANDLE write_pipe = nullptr;
    if (!CreatePipe(&read_pipe, &write_pipe, &security, 0)) {
        result.error = "CreatePipe failed";
        return result;
    }
    SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdOutput = write_pipe;
    startup.hStdError = write_pipe;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    std::wstring command_line = quote_argument(executable);
    if (!arguments.empty()) {
        command_line.push_back(L' ');
        command_line += arguments;
    }
    std::vector<wchar_t> mutable_command(command_line.begin(),
                                         command_line.end());
    mutable_command.push_back(L'\0');

    PROCESS_INFORMATION process{};
    const BOOL created = CreateProcessW(
        executable.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    CloseHandle(write_pipe);
    if (!created) {
        CloseHandle(read_pipe);
        result.error = "CreateProcess failed with code " +
                       std::to_string(GetLastError());
        return result;
    }

    std::string bytes;
    std::thread reader([&] {
        std::array<char, 4096> buffer{};
        DWORD read = 0;
        while (ReadFile(read_pipe, buffer.data(),
                        static_cast<DWORD>(buffer.size()), &read, nullptr) &&
               read) {
            if (bytes.size() < 1024 * 1024) {
                const std::size_t remaining = 1024 * 1024 - bytes.size();
                bytes.append(buffer.data(),
                             std::min<std::size_t>(read, remaining));
            }
        }
    });

    const DWORD wait = WaitForSingleObject(process.hProcess, timeout_ms);
    if (wait == WAIT_TIMEOUT) {
        TerminateProcess(process.hProcess, ERROR_TIMEOUT);
        WaitForSingleObject(process.hProcess, INFINITE);
        result.error = "process timed out";
    } else if (wait != WAIT_OBJECT_0) {
        result.error = "process wait failed";
    }
    GetExitCodeProcess(process.hProcess, &result.exit_code);
    reader.join();
    if (bytes.size() >= 1024 * 1024 && result.error.empty())
        result.error = "process output exceeded 1 MiB";
    CloseHandle(read_pipe);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);

    if (bytes.size() >= 3 &&
        static_cast<unsigned char>(bytes[0]) == 0xef &&
        static_cast<unsigned char>(bytes[1]) == 0xbb &&
        static_cast<unsigned char>(bytes[2]) == 0xbf)
        bytes.erase(0, 3);
    while (!bytes.empty() &&
           (bytes.back() == '\r' || bytes.back() == '\n' ||
            bytes.back() == ' ' || bytes.back() == '\t'))
        bytes.pop_back();
    result.output = std::move(bytes);
    result.ok = result.error.empty() && result.exit_code == 0;
    return result;
}

std::wstring search_executable(const wchar_t* name) {
    std::array<wchar_t, 32768> buffer{};
    const DWORD size = SearchPathW(nullptr, name, nullptr,
                                   static_cast<DWORD>(buffer.size()),
                                   buffer.data(), nullptr);
    return size && size < buffer.size() ? std::wstring(buffer.data(), size)
                                        : std::wstring{};
}

bool is_windows_apps_path(const std::wstring& path) {
    std::wstring normalized = path;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   [](wchar_t ch) { return std::towlower(ch); });
    return normalized.find(L"\\microsoft\\windowsapps\\") != std::wstring::npos;
}

bool is_python_install_directory(const std::wstring& name) {
    std::wstring normalized = name;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   [](wchar_t ch) { return std::towlower(ch); });
    if (normalized.rfind(L"pythoncore", 0) == 0) return true;
    if (normalized.rfind(L"python", 0) != 0 || normalized.size() <= 6)
        return false;
    return std::iswdigit(normalized[6]) != 0;
}

std::wstring discover_python_executable() {
    const std::wstring local_app_data = environment_variable(L"LOCALAPPDATA");
    const std::wstring user_profile = environment_variable(L"USERPROFILE");
    std::vector<fs::path> roots;
    if (!local_app_data.empty()) {
        roots.emplace_back(fs::path(local_app_data) / L"Python");
        roots.emplace_back(fs::path(local_app_data) / L"Programs" / L"Python");
        roots.emplace_back(fs::path(local_app_data) / L"anaconda3");
        roots.emplace_back(fs::path(local_app_data) / L"miniconda3");
    }
    if (!user_profile.empty()) {
        roots.emplace_back(fs::path(user_profile) / L"anaconda3");
        roots.emplace_back(fs::path(user_profile) / L"miniconda3");
    }

    for (const auto& root : roots) {
        const fs::path direct = root / L"python.exe";
        std::error_code ec;
        if (fs::is_regular_file(direct, ec)) return direct.wstring();

        ec.clear();
        std::vector<fs::path> candidates;
        for (fs::directory_iterator it(root, ec), end; !ec && it != end;
             it.increment(ec)) {
            std::error_code entry_error;
            if (it->is_directory(entry_error) &&
                is_python_install_directory(it->path().filename().wstring()))
                candidates.push_back(it->path());
        }
        std::sort(candidates.rbegin(), candidates.rend());
        for (const auto& candidate : candidates) {
            const fs::path executable = candidate / L"python.exe";
            ec.clear();
            if (fs::is_regular_file(executable, ec))
                return executable.wstring();
        }
    }

    const std::wstring on_path = search_executable(L"python.exe");
    return is_windows_apps_path(on_path) ? std::wstring{} : on_path;
}

std::wstring visual_studio_root() {
    std::wstring program_files_x86 = environment_variable(L"ProgramFiles(x86)");
    if (program_files_x86.empty())
        program_files_x86 = L"C:\\Program Files (x86)";
    const fs::path vswhere =
        fs::path(program_files_x86) /
        L"Microsoft Visual Studio" / L"Installer" / L"vswhere.exe";
    if (!fs::exists(vswhere)) return {};
    const auto result = run_process(
        vswhere.wstring(), L"-latest -property installationPath");
    if (!result.ok || result.output.empty()) return {};
    return wide(result.output);
}

std::wstring registry_string(HKEY root, const wchar_t* key_path,
                             const wchar_t* value_name) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, key_path, 0, KEY_QUERY_VALUE, &key) !=
        ERROR_SUCCESS)
        return {};
    DWORD type = 0;
    DWORD size = 0;
    LONG status = RegQueryValueExW(key, value_name, nullptr, &type, nullptr,
                                   &size);
    if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
        size < sizeof(wchar_t)) {
        RegCloseKey(key);
        return {};
    }
    std::wstring value(size / sizeof(wchar_t), L'\0');
    status = RegQueryValueExW(key, value_name, nullptr, &type,
                              reinterpret_cast<BYTE*>(value.data()), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) return {};
    while (!value.empty() && value.back() == L'\0') value.pop_back();
    if (type == REG_EXPAND_SZ) {
        std::array<wchar_t, 32768> expanded{};
        const DWORD length = ExpandEnvironmentStringsW(
            value.c_str(), expanded.data(),
            static_cast<DWORD>(expanded.size()));
        if (length && length < expanded.size()) return expanded.data();
    }
    return value;
}

std::wstring find_visual_studio_tool(const std::wstring& root,
                                     const wchar_t* relative) {
    if (root.empty()) return {};
    const fs::path direct = fs::path(root) / relative;
    if (fs::exists(direct)) return direct.wstring();

    const fs::path versions = fs::path(root) / L"VC" / L"Tools" / L"MSVC";
    std::error_code ec;
    if (!fs::exists(versions, ec)) return {};
    std::vector<fs::path> candidates;
    for (fs::directory_iterator it(versions, ec), end; !ec && it != end;
         it.increment(ec)) {
        if (it->is_directory(ec)) candidates.push_back(it->path());
    }
    std::sort(candidates.rbegin(), candidates.rend());
    for (const auto& version : candidates) {
        const fs::path candidate =
            version / L"bin" / L"Hostx64" / L"x64" / relative;
        if (fs::exists(candidate)) return candidate.wstring();
    }
    return {};
}

Json string_array(const std::vector<std::string>& values) {
    Json result = Json::array();
    for (const auto& value : values) result.as_array().emplace_back(value);
    return result;
}

std::string current_time_iso() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t time = std::chrono::system_clock::to_time_t(now);
    std::tm utc{};
    gmtime_s(&utc, &time);
    std::ostringstream stream;
    stream << std::put_time(&utc, "%Y-%m-%dT%H:%M:%SZ");
    return stream.str();
}

Json cache_metadata(const std::string& reason, bool hit,
                    std::int64_t cached_at = 0) {
    Json result = Json::object();
    result["hit"] = hit;
    result["reason"] = reason;
    if (cached_at > 0) {
        result["cached_at"] = cached_at;
        result["age_seconds"] =
            static_cast<std::int64_t>(std::time(nullptr)) - cached_at;
    }
    return result;
}

fs::path cache_directory() {
    std::wstring local = environment_variable(L"LOCALAPPDATA");
    if (local.empty()) {
        std::array<wchar_t, MAX_PATH> profile{};
        if (SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr,
                             SHGFP_TYPE_CURRENT, profile.data()) == S_OK)
            local = profile.data();
    }
    if (local.empty()) local = environment_variable(L"USERPROFILE");
    return fs::path(local) / L"machine-env" / L"cache";
}

class CacheMutex {
public:
    CacheMutex() : handle_(CreateMutexW(nullptr, FALSE, L"Local\\machine-env-cache-v2")) {
        if (handle_) WaitForSingleObject(handle_, INFINITE);
    }
    ~CacheMutex() {
        if (handle_) {
            ReleaseMutex(handle_);
            CloseHandle(handle_);
        }
    }
    CacheMutex(const CacheMutex&) = delete;
    CacheMutex& operator=(const CacheMutex&) = delete;

private:
    HANDLE handle_ = nullptr;
};

fs::path cache_file(const std::string& kind) {
    return cache_directory() / (wide(kind + ".json"));
}

std::string cache_read_failure;

Json read_cache_entry(const std::string& kind, int ttl,
                      bool ignore_expiry = false) {
    cache_read_failure = "no cache file";
    CacheMutex mutex;
    const fs::path path = cache_file(kind);
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return Json();
    std::ostringstream contents;
    contents << stream.rdbuf();
    try {
        const Json entry = parse_json(contents.str());
        if (!entry.is_object()) {
            cache_read_failure = "cache has invalid format";
            return Json();
        }
        const Json& time_value = entry.get("cached_at");
        const Json& fingerprint_value = entry.get("fingerprint");
        const Json& payload = entry.get("payload");
        if (!time_value.is_number() || !fingerprint_value.is_string() ||
            !payload.is_object()) {
            cache_read_failure = "cache has invalid fields";
            return Json();
        }
        const Json& machine_value = entry.get("machine_guid");
        if (!machine_value.is_string() ||
            machine_value.as_string() != machine_guid()) {
            cache_read_failure = "cache belongs to another machine";
            return Json();
        }
        const auto cached_at = time_value.as_integer();
        const auto now = static_cast<std::int64_t>(std::time(nullptr));
        if (cached_at > now) {
            cache_read_failure = "cache timestamp is in the future";
            return Json();
        }
        if (fingerprint_value.as_string() != source_fingerprint()) {
            cache_read_failure = "server binary changed";
            return Json();
        }
        if (!ignore_expiry && now - cached_at > ttl) {
            cache_read_failure = "expired (ttl " + std::to_string(ttl) + "s)";
            return Json();
        }
        cache_read_failure = "fresh";
        return entry;
    } catch (const std::exception& error) {
        cache_read_failure = std::string("cache unreadable: ") + error.what();
        return Json();
    }
}

bool write_cache_entry(const std::string& kind, const Json& payload,
                       std::string& error) {
    CacheMutex mutex;
    std::error_code ec;
    const fs::path directory = cache_directory();
    fs::create_directories(directory, ec);
    if (ec) {
        error = "cannot create cache directory: " + ec.message();
        return false;
    }

    Json entry = Json::object();
    entry["cached_at"] = static_cast<std::int64_t>(std::time(nullptr));
    entry["fingerprint"] = source_fingerprint();
    entry["machine_guid"] = machine_guid();
    entry["payload"] = payload;
    const std::string serialized = dump_json(entry);

    const fs::path destination = cache_file(kind);
    const fs::path temporary =
        destination.wstring() + L"." + wide(std::to_string(GetCurrentProcessId()) +
                                           "-" + std::to_string(GetTickCount64())) +
        L".tmp";
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream || !stream.write(serialized.data(),
                                     static_cast<std::streamsize>(serialized.size()))) {
            error = "cannot write temporary cache file";
            fs::remove(temporary, ec);
            return false;
        }
    }
    if (!MoveFileExW(temporary.c_str(), destination.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        error = "cannot replace cache file (Windows error " +
                std::to_string(GetLastError()) + ")";
        fs::remove(temporary, ec);
        return false;
    }
    return true;
}

void annotate_cache(Json& payload, const Json& metadata) {
    payload["_cache"] = metadata;
}

Json cacheable_probe(const std::string& kind, Json payload,
                     const Json& old_metadata) {
    Json result_metadata = old_metadata;
    if (!payload.contains("error")) {
        std::string error;
        if (write_cache_entry(kind, payload, error)) {
            Json cache = Json::object();
            cache["cached"] = true;
            result_metadata.as_object().insert(cache.as_object().begin(),
                                                cache.as_object().end());
        } else {
            result_metadata["cached"] = false;
            result_metadata["not_cached_because"] = error;
        }
    } else {
        result_metadata["cached"] = false;
        result_metadata["not_cached_because"] = payload.get("error");
    }
    annotate_cache(payload, result_metadata);
    return payload;
}

bool is_admin() {
    BOOL member = FALSE;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID administrators = nullptr;
    if (AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                 &administrators)) {
        CheckTokenMembership(nullptr, administrators, &member);
        FreeSid(administrators);
    }
    return member == TRUE;
}

std::string cpu_vendor(char* brand_out, std::size_t brand_size,
                       unsigned& family, unsigned& model,
                       unsigned& stepping, unsigned long long& xcr0,
                       bool& osxsave, Json& isa) {
    int registers[4]{};
    __cpuid(registers, 0);
    const unsigned max_leaf = static_cast<unsigned>(registers[0]);
    char vendor[13]{};
    std::memcpy(vendor, registers + 1, 4);
    std::memcpy(vendor + 4, registers + 3, 4);
    std::memcpy(vendor + 8, registers + 2, 4);

    __cpuid(registers, static_cast<int>(0x80000000u));
    const unsigned max_ext = static_cast<unsigned>(registers[0]);
    char brand[49]{};
    if (max_ext >= 0x80000004u) {
        for (unsigned leaf = 0; leaf < 3; ++leaf) {
            __cpuid(registers, static_cast<int>(0x80000002u + leaf));
            std::memcpy(brand + leaf * 16, registers, 16);
        }
    }
    std::string brand_string(brand);
    const auto first = brand_string.find_first_not_of(' ');
    if (first != std::string::npos) brand_string.erase(0, first);
    std::snprintf(brand_out, brand_size, "%s", brand_string.c_str());

    __cpuid(registers, 1);
    const unsigned eax = static_cast<unsigned>(registers[0]);
    const unsigned ecx = static_cast<unsigned>(registers[2]);
    const unsigned family_base = (eax >> 8) & 0xf;
    const unsigned family_ext = (eax >> 20) & 0xff;
    family = family_base == 0xf ? family_base + family_ext : family_base;
    const unsigned model_base = (eax >> 4) & 0xf;
    const unsigned model_ext = (eax >> 16) & 0xf;
    model = (family_base == 0x6 || family_base == 0xf)
                ? model_base | (model_ext << 4)
                : model_base;
    stepping = eax & 0xf;
    osxsave = (ecx & (1u << 27)) != 0;
    const bool avx_cpu = (ecx & (1u << 28)) != 0;
    xcr0 = osxsave ? _xgetbv(0) : 0;
    const bool ymm = (xcr0 & 0x6) == 0x6;
    const bool zmm = (xcr0 & 0xe6) == 0xe6;

    int leaf7[4]{};
    if (max_leaf >= 7) __cpuidex(leaf7, 7, 0);
    int leaf71[4]{};
    if (max_leaf >= 7 && leaf7[0] >= 1) __cpuidex(leaf71, 7, 1);
    const unsigned ebx7 = static_cast<unsigned>(leaf7[1]);
    const unsigned ecx7 = static_cast<unsigned>(leaf7[2]);
    const unsigned eax71 = static_cast<unsigned>(leaf71[0]);
    const bool avx = avx_cpu && ymm;
    const bool avx512 = avx && zmm && ((ebx7 >> 16) & 1);
    isa = Json::object();
    isa["sse4_2"] = (ecx >> 20) & 1;
    isa["ssse3"] = (ecx >> 9) & 1;
    isa["popcnt"] = (ecx >> 23) & 1;
    isa["avx"] = avx;
    isa["avx2"] = avx && ((ebx7 >> 5) & 1);
    isa["fma"] = avx && ((ecx >> 12) & 1);
    isa["f16c"] = avx && ((ecx >> 29) & 1);
    isa["avx_vnni"] = max_leaf >= 7 && ((eax71 >> 4) & 1);
    isa["avx512f"] = avx512;
    isa["avx512bw"] = avx512 && ((ebx7 >> 30) & 1);
    isa["avx512vnni"] = avx512 && ((ecx7 >> 11) & 1);
    isa["bmi2"] = (ebx7 >> 8) & 1;
    return vendor;
}

Json probe_one_endpoint(const wchar_t* host) {
    Json result = Json::object();
    const auto started = std::chrono::steady_clock::now();
    HINTERNET session = WinHttpOpen(
        L"machine-env/0.2.0",
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result["ok"] = false;
        result["error"] = "WinHttpOpen failed";
        result["ms"] = 0;
        return result;
    }
    WinHttpSetTimeouts(session, 1200, 1200, 1200, 1200);
    HINTERNET connection = WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    HINTERNET request = connection
        ? WinHttpOpenRequest(connection, L"HEAD", L"/", nullptr,
                             WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                             WINHTTP_FLAG_SECURE)
        : nullptr;
    bool ok = request && WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS,
                                            0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
              WinHttpReceiveResponse(request, nullptr);
    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (ok) {
        ok = WinHttpQueryHeaders(request,
                                 WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                 WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
                                 WINHTTP_NO_HEADER_INDEX) != FALSE;
    }
    const DWORD error_code = ok ? ERROR_SUCCESS : GetLastError();
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - started)
                             .count();
    result["ok"] = ok;
    result["ms"] = static_cast<std::int64_t>(elapsed);
    if (ok) result["status"] = static_cast<int>(status);
    else result["error"] = "HTTPS request failed (WinHTTP " +
                           std::to_string(error_code) + ")";
    return result;
}

Json read_cached_status(const std::string& kind, int ttl) {
    const Json entry = read_cache_entry(kind, ttl, true);
    const auto reason = cache_read_failure;
    if (entry.is_object()) {
        const auto cached_at = entry.get("cached_at").as_integer();
        const auto now = static_cast<std::int64_t>(std::time(nullptr));
        const bool fresh = now - cached_at <= ttl;
        Json metadata = cache_metadata(fresh ? "fresh" : "expired (ttl " +
                                        std::to_string(ttl) + "s)",
                                        fresh, cached_at);
        metadata["ttl_seconds"] = ttl;
        return metadata;
    }
    Json metadata = cache_metadata(reason, false);
    metadata["ttl_seconds"] = ttl;
    return metadata;
}

}  // namespace

std::string machine_guid() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"SOFTWARE\\Microsoft\\Cryptography", 0, KEY_QUERY_VALUE,
                      &key) == ERROR_SUCCESS) {
        std::array<wchar_t, 256> value{};
        DWORD size = static_cast<DWORD>(value.size() * sizeof(wchar_t));
        DWORD type = 0;
        const LONG status = RegQueryValueExW(
            key, L"MachineGuid", nullptr, &type,
            reinterpret_cast<BYTE*>(value.data()), &size);
        RegCloseKey(key);
        if (status == ERROR_SUCCESS && type == REG_SZ)
            return utf8(value.data());
    }
    std::array<wchar_t, MAX_COMPUTERNAME_LENGTH + 1> computer{};
    DWORD size = static_cast<DWORD>(computer.size());
    if (GetComputerNameW(computer.data(), &size))
        return "computer:" + utf8(computer.data());
    return "unknown-machine";
}

std::string source_fingerprint() {
    static const std::string fingerprint = [] {
        std::array<wchar_t, 32768> executable{};
        const DWORD size = GetModuleFileNameW(nullptr, executable.data(),
                                              static_cast<DWORD>(executable.size()));
        if (!size || size >= executable.size()) return std::string(kServerVersion);
        std::ifstream stream(fs::path(executable.data()), std::ios::binary);
        std::uint64_t hash = 14695981039346656037ull;
        std::array<char, 8192> bytes{};
        while (stream) {
            stream.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
            for (std::streamsize i = 0; i < stream.gcount(); ++i) {
                hash ^= static_cast<unsigned char>(bytes[static_cast<std::size_t>(i)]);
                hash *= 1099511628211ull;
            }
        }
        std::ostringstream output;
        output << kServerVersion << '-' << std::hex << hash;
        return output.str();
    }();
    return fingerprint;
}

Json probe_hardware() {
    Json result = Json::object();
    unsigned family = 0, model = 0, stepping = 0;
    unsigned long long xcr0 = 0;
    bool osxsave = false;
    Json isa;
    std::array<char, 128> brand{};
    const std::string vendor =
        cpu_vendor(brand.data(), brand.size(), family, model, stepping, xcr0,
                   osxsave, isa);
    int leaves[4]{};
    __cpuid(leaves, 0);
    result["vendor"] = vendor;
    result["brand"] = brand.data();
    result["family"] = static_cast<int>(family);
    result["model"] = static_cast<int>(model);
    result["stepping"] = static_cast<int>(stepping);
    result["max_leaf"] = leaves[0];
    __cpuid(leaves, static_cast<int>(0x80000000u));
    result["max_ext_leaf"] = static_cast<std::int64_t>(
        static_cast<unsigned>(leaves[0]));
    result["xcr0"] = static_cast<std::int64_t>(xcr0);
    result["osxsave"] = osxsave;
    result["isa"] = isa;
    const bool avx512 = isa.get("avx512f").as_bool();
    const bool avx2 = isa.get("avx2").as_bool();
    result["vector_width_bits"] = avx512 ? 512 : (avx2 ? 256 : 128);

    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    if (GlobalMemoryStatusEx(&memory)) {
        SYSTEM_INFO system_info{};
        GetSystemInfo(&system_info);
        Json facts = Json::object();
        facts["total_mem_mb"] = static_cast<std::int64_t>(
            (memory.ullTotalPhys + 512 * 1024) / (1024 * 1024));
        facts["free_mem_mb"] = static_cast<std::int64_t>(
            (memory.ullAvailPhys + 512 * 1024) / (1024 * 1024));
        facts["logical_cpu"] = static_cast<int>(system_info.dwNumberOfProcessors);
        result["memory"] = facts;
        result["memory_source"] = "Win32";
    }
    return result;
}

Json probe_toolchain() {
    static const std::array<std::pair<const wchar_t*, const wchar_t*>, 12> tools{{
        {L"python", L"python.exe"}, {L"pip", L"pip.exe"}, {L"uv", L"uv.exe"},
        {L"git", L"git.exe"}, {L"node", L"node.exe"}, {L"npm", L"npm.exe"},
        {L"cargo", L"cargo.exe"}, {L"go", L"go.exe"}, {L"java", L"java.exe"},
        {L"cmake", L"cmake.exe"}, {L"ninja", L"ninja.exe"}, {L"cl", L"cl.exe"}
    }};
    Json result = Json::object();
    Json found = Json::object();
    Json versions = Json::object();
    Json missing = Json::array();
    Json not_on_path = Json::array();
    const std::wstring vs_root = visual_studio_root();
    result["vs_path"] = utf8(vs_root);
    result["python_root"] = "";
    int tool_count = 0;

    for (const auto& tool : tools) {
        std::wstring path = tool.first == std::wstring(L"python")
                                ? discover_python_executable()
                                : search_executable(tool.second);
        if (path.empty() && tool.first == std::wstring(L"npm"))
            path = search_executable(L"npm.cmd");
        bool off_path = false;
        if (path.empty() && tool.first == std::wstring(L"cl")) {
            path = find_visual_studio_tool(
                vs_root, L"cl.exe");
            off_path = !path.empty();
        } else if (path.empty() && tool.first == std::wstring(L"ninja")) {
            const fs::path candidate = fs::path(vs_root) / L"Common7" / L"IDE" /
                L"CommonExtensions" / L"Microsoft" / L"CMake" / L"Ninja" /
                L"ninja.exe";
            if (!vs_root.empty() && fs::exists(candidate)) {
                path = candidate.wstring();
                off_path = true;
            }
        }
        if (path.empty()) {
            missing.as_array().emplace_back(utf8(tool.first));
            continue;
        }
        found[utf8(tool.first)] = utf8(path);
        ++tool_count;
        if (off_path) not_on_path.as_array().emplace_back(utf8(tool.first));

        // Do not launch Python or pip; tool discovery does not execute user tools.
        if (tool.first == std::wstring(L"python") ||
            tool.first == std::wstring(L"pip") ||
            tool.first == std::wstring(L"cl"))
            continue;
        std::wstring args = L"--version";
        if (tool.first == std::wstring(L"go")) args = L"version";
        const auto version = run_process(path, args);
        if (version.ok && !version.output.empty())
            versions[utf8(tool.first)] = version.output;
    }

    result["tool_count"] = tool_count;
    result["tool_total"] = static_cast<int>(tools.size());
    result["tools"] = found;
    result["versions"] = versions;
    result["not_on_path"] = not_on_path;
    result["missing"] = missing;
    if (found.contains("python")) {
        result["python_root"] =
            utf8(fs::path(wide(found.get("python").as_string())).parent_path().wstring());
    }
    result["machine_guid"] = machine_guid();
    std::array<wchar_t, MAX_COMPUTERNAME_LENGTH + 1> computer{};
    DWORD computer_size = static_cast<DWORD>(computer.size());
    if (GetComputerNameW(computer.data(), &computer_size))
        result["computer_name"] = utf8(computer.data());
    result["probed_at"] = current_time_iso();
    return result;
}

Json probe_environment(bool include_network) {
    Json result = Json::object();
    Json os = Json::object();
    Json shell = Json::object();
    Json paths = Json::object();

    using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
    const auto ntdll = GetModuleHandleW(L"ntdll.dll");
    const auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    RTL_OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    if (rtl_get_version && rtl_get_version(&version) == 0) {
        os["version"] = std::to_string(version.dwMajorVersion) + "." +
                        std::to_string(version.dwMinorVersion);
        os["build"] = static_cast<int>(version.dwBuildNumber);
    }
    const auto product_name = registry_string(
        HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"ProductName");
    os["caption"] = product_name.empty() ? "Microsoft Windows"
                                          : utf8(product_name);
    SYSTEM_INFO info{};
    GetNativeSystemInfo(&info);
    os["arch"] = info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64
                     ? "64-bit"
                     : (info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64
                            ? "ARM64"
                            : "32-bit");
    os["logical_cpu"] = static_cast<int>(info.dwNumberOfProcessors);
    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    if (GlobalMemoryStatusEx(&memory)) {
        os["total_mem_mb"] = static_cast<std::int64_t>(
            (memory.ullTotalPhys + 512 * 1024) / (1024 * 1024));
        os["free_mem_mb"] = static_cast<std::int64_t>(
            (memory.ullAvailPhys + 512 * 1024) / (1024 * 1024));
    }
    int cpu[4]{};
    __cpuid(cpu, 0x80000000);
    if (static_cast<unsigned>(cpu[0]) >= 0x80000004u) {
        char brand[49]{};
        for (unsigned leaf = 0; leaf < 3; ++leaf) {
            __cpuid(cpu, static_cast<int>(0x80000002u + leaf));
            std::memcpy(brand + leaf * 16, cpu, 16);
        }
        os["cpu_name"] = brand;
    }

    std::array<wchar_t, UNLEN + 1> username{};
    DWORD username_size = static_cast<DWORD>(username.size());
    if (GetUserNameW(username.data(), &username_size)) {
        const auto domain = environment_variable(L"USERDOMAIN");
        shell["current_user"] = utf8(domain + L"\\" + username.data());
    }
    shell["is_admin"] = is_admin();
    shell["execution_policy"] = "not probed";
    const std::wstring powershell = search_executable(L"powershell.exe");
    if (!powershell.empty()) {
        const auto ps = run_process(
            powershell,
            L"-NoProfile -NonInteractive -Command "
            L"\"$PSVersionTable.PSVersion.ToString();$PSVersionTable.PSEdition;"
            L"$Host.Name;Get-ExecutionPolicy\"");
        if (ps.ok) {
            std::istringstream values(ps.output);
            std::string ps_version, ps_edition, ps_host, execution_policy;
            std::getline(values, ps_version);
            std::getline(values, ps_edition);
            std::getline(values, ps_host);
            std::getline(values, execution_policy);
            shell["ps_version"] = ps_version;
            shell["ps_edition"] = ps_edition;
            shell["ps_host"] = ps_host;
            shell["execution_policy"] = execution_policy;
            int major = 0;
            try {
                major = std::stoi(ps_version);
            } catch (const std::exception&) {
                major = 0;
            }
            shell["supports_ampersand_ampersand"] = major >= 7;
            shell["has_heredoc"] = major >= 7;
        }
    }

    for (const auto& variable : {
             std::pair<const wchar_t*, const char*>{L"USERPROFILE", "user_profile"},
             {L"APPDATA", "appdata"},
             {L"LOCALAPPDATA", "local_appdata"},
             {L"TEMP", "temp"},
             {L"ProgramFiles", "program_files"},
             {L"ProgramFiles(x86)", "pf_x86"}}) {
        paths[variable.second] = utf8(environment_variable(variable.first));
    }
    Json path_entries = Json::array();
    std::wstring path = environment_variable(L"PATH");
    std::size_t start = 0;
    while (start <= path.size()) {
        const auto end = path.find(L';', start);
        const auto entry = path.substr(start, end == std::wstring::npos
                                                 ? std::wstring::npos
                                                 : end - start);
        if (!entry.empty()) path_entries.as_array().emplace_back(utf8(entry));
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    paths["path_entries"] = path_entries;
    result["os"] = os;
    result["shell"] = shell;
    result["paths"] = paths;
    result["probed_at"] = current_time_iso();

    if (include_network) {
        Json network = Json::object();
        network["github_api"] = probe_one_endpoint(L"api.github.com");
        network["github_raw"] = probe_one_endpoint(L"raw.githubusercontent.com");
        network["huggingface"] = probe_one_endpoint(L"huggingface.co");
        network["pypi"] = probe_one_endpoint(L"pypi.org");
        result["network"] = network;
    }
    return result;
}

Json probe_cache_status() {
    Json result = Json::object();
    result["fingerprint"] = source_fingerprint();
    Json categories = Json::object();
    categories["hardware"] = read_cached_status("hardware", kDefaultTtl);
    categories["toolchain"] = read_cached_status("toolchain", kDefaultTtl);
    categories["environment"] = read_cached_status("environment", kNetworkTtl);
    result["categories"] = categories;
    return result;
}

Json cached_probe(const std::string& kind, bool refresh,
                  bool include_network) {
    const int ttl = kind == "environment" ? kNetworkTtl : kDefaultTtl;
    if (!refresh) {
        const Json entry = read_cache_entry(kind, ttl);
        if (entry.is_object()) {
            Json payload = entry.get("payload");
            const auto timestamp = entry.get("cached_at").as_integer();
            annotate_cache(payload, cache_metadata("fresh", true, timestamp));
            if (kind == "environment" && !include_network)
                payload.as_object().erase("network");
            if (kind == "environment" && !include_network)
                payload["_cache"]["network_probe_skipped"] = true;
            return payload;
        }
    }

    const Json metadata = cache_metadata(
        refresh ? "refresh requested" : cache_read_failure, false);
    const auto started = std::chrono::steady_clock::now();
    Json payload = kind == "hardware"
                       ? probe_hardware()
                       : kind == "toolchain"
                             ? probe_toolchain()
                             : probe_environment(include_network);
    payload["_probe_ms"] = static_cast<std::int64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started)
            .count());
    if (kind == "environment" && !include_network) {
        Json local_metadata = metadata;
        local_metadata["network_probe_skipped"] = true;
        local_metadata["cached"] = false;
        local_metadata["not_cached_because"] = "network probe was skipped";
        annotate_cache(payload, local_metadata);
        return payload;
    }
    return cacheable_probe(kind, std::move(payload), metadata);
}

Json refresh_environment(const std::string& scope) {
    const std::vector<std::string> valid{"all", "hardware", "toolchain",
                                         "environment"};
    if (std::find(valid.begin(), valid.end(), scope) == valid.end()) {
        Json error = Json::object();
        error["error"] = "invalid scope '" + scope + "'";
        error["valid"] = string_array(valid);
        return error;
    }
    Json result = Json::object();
    Json refreshed = Json::array();
    result["scope"] = scope;
    if (scope == "all" || scope == "hardware") {
        Json payload = cached_probe("hardware", true, true);
        if (!payload.contains("error")) refreshed.as_array().emplace_back("hardware");
        result["hardware"] = payload;
    }
    if (scope == "all" || scope == "toolchain") {
        Json payload = cached_probe("toolchain", true, true);
        if (!payload.contains("error")) refreshed.as_array().emplace_back("toolchain");
        result["toolchain"] = payload;
    }
    if (scope == "all" || scope == "environment") {
        Json payload = cached_probe("environment", true, true);
        if (!payload.contains("error")) refreshed.as_array().emplace_back("environment");
        result["environment"] = payload;
    }
    result["refreshed"] = refreshed;
    return result;
}

}  // namespace machine_env
