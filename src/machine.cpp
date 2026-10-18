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
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace machine_env {
namespace {

namespace fs = std::filesystem;
constexpr char kServerVersion[] = "0.3.1";
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

// Windows offers no way to enumerate a probe's descendants, so the tree kill
// is best effort through a job object. The count below is per thread because a
// probe runs wholly on one thread: it lets probe_system report what its own
// launches did without a concurrent probe contaminating the answer. It counts
// launches that could not be bound to a job, i.e. the ones that fell back to
// terminating the direct child alone.
thread_local unsigned long long tree_kill_fallbacks = 0;

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
    // Give the child its own stdin and discard its stderr. Inheriting the
    // server's stdin would let a probing tool consume the JSON-RPC request
    // stream, and merging stderr into the captured pipe would let a single
    // warning line shift every value a caller reads by position.
    HANDLE null_device = CreateFileW(
        L"NUL", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0,
        nullptr);
    startup.hStdInput =
        null_device ? null_device : GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdError =
        null_device ? null_device : GetStdHandle(STD_ERROR_HANDLE);

    std::wstring command_line = quote_argument(executable);
    if (!arguments.empty()) {
        command_line.push_back(L' ');
        command_line += arguments;
    }
    std::vector<wchar_t> mutable_command(command_line.begin(),
                                         command_line.end());
    mutable_command.push_back(L'\0');

    // One job per probe. KILL_ON_JOB_CLOSE is what makes cleanup complete: it
    // reaps grandchildren along with the child, and it is also what releases
    // the pipe write end a surviving descendant would otherwise hold open.
    // Every step here is optional: a probe that cannot get a job still runs,
    // it just loses the tree-wide kill.
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                     &limits, sizeof(limits))) {
            CloseHandle(job);
            job = nullptr;
        }
    }

    PROCESS_INFORMATION process{};
    const BOOL created = CreateProcessW(
        executable.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    CloseHandle(write_pipe);
    if (null_device) CloseHandle(null_device);
    if (!created) {
        if (job) CloseHandle(job);
        CloseHandle(read_pipe);
        result.error = "CreateProcess failed with code " +
                       std::to_string(GetLastError());
        return result;
    }

    if (job && !AssignProcessToJobObject(job, process.hProcess)) {
        // Typical cause: the server itself runs inside a job that does not
        // allow nesting. Losing the tree kill is acceptable; failing the probe
        // is not, so the direct-child path stays available.
        CloseHandle(job);
        job = nullptr;
    }
    if (!job) ++tree_kill_fallbacks;

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
    if (wait != WAIT_OBJECT_0) {
        // Terminate the whole tree, not only the direct child: a surviving
        // grandchild keeps the pipe write end open, so the reader thread would
        // never see end-of-file and the cancel below would be load-bearing
        // instead of a last resort. When no job could be applied this degrades
        // to exactly the previous behaviour.
        if (job) {
            TerminateJobObject(job, ERROR_TIMEOUT);
        } else {
            TerminateProcess(process.hProcess, ERROR_TIMEOUT);
        }
        // The direct child reports its exit first, then closing the job reaps
        // whatever descendants it left behind, which is what finally releases
        // the pipe the reader is blocked on.
        WaitForSingleObject(process.hProcess, INFINITE);
        if (job) {
            CloseHandle(job);
            job = nullptr;
        }
        // A grandchild can still hold the write end if it broke away from the
        // job, so cancelling the pending read stays as the last resort.
        CancelSynchronousIo(reader.native_handle());
        result.error =
            wait == WAIT_TIMEOUT ? "process timed out" : "process wait failed";
    }
    GetExitCodeProcess(process.hProcess, &result.exit_code);
    // On the normal path the child exited by itself, but closing the job still
    // matters: a descendant it left running would hold the pipe open and block
    // the join below for as long as that descendant lived.
    if (job) CloseHandle(job);
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

// Defined below, after the registry helpers it reads the path with.
std::wstring system_path();

std::wstring search_executable(const wchar_t* name) {
    // An explicit path replaces the default search order, which would also
    // consult the current directory and the process environment.
    const std::wstring path = system_path();
    std::array<wchar_t, 32768> buffer{};
    const DWORD size = SearchPathW(path.empty() ? nullptr : path.c_str(), name,
                                   nullptr,
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

bool is_existing_directory(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

// Version components are compared as numbers, not as text: otherwise "3.9"
// would outrank "3.14" and an older toolset would be preferred.
std::vector<long long> numeric_parts(const std::wstring& text) {
    std::vector<long long> parts;
    long long current = -1;
    for (const wchar_t ch : text) {
        if (ch >= L'0' && ch <= L'9') {
            if (current < 0) current = 0;
            if (current < 100000000000000LL)
                current = current * 10 + (ch - L'0');
        } else if (current >= 0) {
            parts.push_back(current);
            current = -1;
        }
    }
    if (current >= 0) parts.push_back(current);
    return parts;
}

void sort_newest_first(std::vector<fs::path>& directories) {
    std::sort(directories.begin(), directories.end(),
              [](const fs::path& left, const fs::path& right) {
                  return numeric_parts(left.filename().wstring()) >
                         numeric_parts(right.filename().wstring());
              });
}

// Order directories by their numeric components so "v3.14" outranks "v3.9"
// without a hardcoded version list that would go stale.
std::vector<fs::path> directories_by_newest(const fs::path& parent,
                                            const std::wstring& prefix) {
    std::vector<fs::path> found;
    std::error_code ec;
    for (fs::directory_iterator it(parent, ec), end; !ec && it != end;
         it.increment(ec)) {
        std::error_code entry_error;
        if (!it->is_directory(entry_error)) continue;
        const std::wstring name = it->path().filename().wstring();
        if (!prefix.empty() && name.rfind(prefix, 0) != 0) continue;
        found.push_back(it->path());
    }
    sort_newest_first(found);
    return found;
}

std::wstring discover_python_executable() {
    // PATH is consulted before any install directory is scanned. The question
    // being answered is "where is the python this machine will run", and the
    // bare name is what a caller types, so the copy PATH points at is the one
    // that matters. Scanning first used to answer with a second installation
    // that PATH does not reach, and then mark it as not on PATH: a truthful
    // pair of facts that together describe an interpreter nobody will run, and
    // that made the pip beside the *other* installation look mismatched.
    const std::wstring on_path = search_executable(L"python.exe");
    if (!on_path.empty() && !is_windows_apps_path(on_path)) return on_path;

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
        sort_newest_first(candidates);
        for (const auto& candidate : candidates) {
            const fs::path executable = candidate / L"python.exe";
            ec.clear();
            if (fs::is_regular_file(executable, ec))
                return executable.wstring();
        }
    }

    // A WindowsApps alias is a stub that leads to the Store, not an
    // installation, and nothing was found that actually runs.
    return {};
}

// Not finding Visual Studio and failing to look for it are different answers,
// so the caller is told which one happened instead of receiving an empty path
// that reads as "not installed".
//
// An empty answer from a query that succeeded only means "not installed" when
// the query covers every instance. This one did not: vswhere hides pre-release
// channels by default, under which a complete IDE carrying its own compiler is
// invisible (measured: Visual Studio Community Insiders 18.5 alongside Build
// Tools, where only the latter was reported). Preferring a stable instance and
// falling back to a pre-release one keeps that IDE's tools discoverable while
// leaving an empty answer meaning genuinely absent.
std::wstring visual_studio_root(std::string& detection) {
    // Nothing has been observed yet, and "not checked" must not be reported as
    // "not installed".
    detection = "unknown";
    std::wstring program_files_x86 = environment_variable(L"ProgramFiles(x86)");
    if (program_files_x86.empty())
        program_files_x86 = L"C:\\Program Files (x86)";
    const fs::path vswhere =
        fs::path(program_files_x86) /
        L"Microsoft Visual Studio" / L"Installer" / L"vswhere.exe";
    // A missing locator is a look that failed, not an absent product.
    if (!fs::exists(vswhere)) return {};
    const auto stable = run_process(
        vswhere.wstring(), L"-latest -products * -property installationPath");
    if (!stable.ok) return {};
    if (!stable.output.empty()) {
        detection = "ok";
        return wide(stable.output);
    }
    const auto prerelease = run_process(
        vswhere.wstring(),
        L"-latest -prerelease -products * -property installationPath");
    if (!prerelease.ok) return {};
    if (prerelease.output.empty()) {
        // The query completed and covered every channel, so nothing is there.
        detection = "absent";
        return {};
    }
    detection = "ok";
    return wide(prerelease.output);
}

// Reading a value from a key that is already open. The helpers below that take
// a root and a path open and close one key per value, which is fine for a
// single value but multiplies when several values live in the same key.
bool query_registry_dword(HKEY key, const wchar_t* value_name, DWORD& value) {
    DWORD type = 0;
    DWORD size = sizeof(value);
    const LONG status = RegQueryValueExW(
        key, value_name, nullptr, &type, reinterpret_cast<BYTE*>(&value), &size);
    return status == ERROR_SUCCESS && type == REG_DWORD && size == sizeof(DWORD);
}

std::wstring query_registry_string(HKEY key, const wchar_t* value_name) {
    DWORD type = 0;
    DWORD size = 0;
    LONG status = RegQueryValueExW(key, value_name, nullptr, &type, nullptr,
                                   &size);
    if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
        size < sizeof(wchar_t))
        return {};
    std::wstring value(size / sizeof(wchar_t), L'\0');
    status = RegQueryValueExW(key, value_name, nullptr, &type,
                              reinterpret_cast<BYTE*>(value.data()), &size);
    if (status != ERROR_SUCCESS) return {};
    while (!value.empty() && value.back() == L'\0') value.pop_back();
    if (type == REG_EXPAND_SZ) {
        std::array<wchar_t, 32768> expanded{};
        const DWORD length = ExpandEnvironmentStringsW(
            value.c_str(), expanded.data(),
            static_cast<DWORD>(expanded.size()));
        // Reporting "%ProgramFiles%\Foo" as an install location would look like
        // a usable path, so an unexpanded value counts as unknown instead.
        if (!length || length >= expanded.size()) return {};
        return expanded.data();
    }
    return value;
}

bool registry_dword(HKEY root, const wchar_t* key_path,
                    const wchar_t* value_name, DWORD& value) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, key_path, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
        return false;
    const bool found = query_registry_dword(key, value_name, value);
    RegCloseKey(key);
    return found;
}

bool registry_qword(HKEY root, const wchar_t* key_path,
                    const wchar_t* value_name, unsigned long long& value) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, key_path, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
        return false;
    DWORD type = 0;
    DWORD size = sizeof(value);
    const LONG status = RegQueryValueExW(
        key, value_name, nullptr, &type, reinterpret_cast<BYTE*>(&value), &size);
    RegCloseKey(key);
    return status == ERROR_SUCCESS && type == REG_QWORD &&
           size == sizeof(unsigned long long);
}

std::wstring registry_string(HKEY root, const wchar_t* key_path,
                             const wchar_t* value_name) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, key_path, 0, KEY_QUERY_VALUE, &key) !=
        ERROR_SUCCESS)
        return {};
    std::wstring value = query_registry_string(key, value_name);
    RegCloseKey(key);
    return value;
}

// One key held for the handful of values read from it, closed on every exit
// path. The application inventory skips an entry from several places, which is
// exactly where a manually closed handle gets missed.
class RegistryKey {
public:
    RegistryKey(HKEY root, const wchar_t* key_path) {
        if (RegOpenKeyExW(root, key_path, 0, KEY_QUERY_VALUE, &key_) !=
            ERROR_SUCCESS)
            key_ = nullptr;
    }
    ~RegistryKey() {
        if (key_) RegCloseKey(key_);
    }
    HKEY get() const { return key_; }
    bool valid() const { return key_ != nullptr; }
    RegistryKey(const RegistryKey&) = delete;
    RegistryKey& operator=(const RegistryKey&) = delete;

private:
    HKEY key_ = nullptr;
};

// The PATH a newly started shell receives lives in the registry: the
// machine-wide value first, then the per-user one, which is the order Windows
// composes them in. The server's own copy was captured when it started, so a
// tool installed and added to PATH afterwards would be reported as missing by
// every later probe, including one that asked to refresh. Re-reading the
// registry on each probe is what keeps a refresh meaningful.
std::wstring read_registry_path() {
    const std::wstring machine = registry_string(
        HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment",
        L"Path");
    const std::wstring user =
        registry_string(HKEY_CURRENT_USER, L"Environment", L"Path");
    if (machine.empty()) return user;
    if (user.empty()) return machine;
    return machine + L";" + user;
}

// Finding one executable needs the PATH, so a probe that looks for fifty of
// them would open the same two keys fifty times to answer one question. These
// make a probe pay for it once. The cache is scoped, not timed, and never
// outlives the probe: outside a PathSnapshot system_path still reads the
// registry, so a refresh after a PATH change still sees the change.
thread_local int path_snapshot_depth = 0;
thread_local bool path_snapshot_valid = false;
thread_local std::wstring path_snapshot_value;

std::wstring system_path() {
    if (path_snapshot_valid) return path_snapshot_value;
    return read_registry_path();
}

// Depth counted so a nested probe shares the outer read, and the value is
// dropped as soon as the outermost snapshot ends. RAII keeps that true on every
// exit path, including an exception thrown mid-probe.
class PathSnapshot {
public:
    PathSnapshot() {
        if (path_snapshot_depth++ == 0) {
            path_snapshot_value = read_registry_path();
            path_snapshot_valid = true;
        }
    }
    ~PathSnapshot() {
        if (--path_snapshot_depth == 0) {
            path_snapshot_valid = false;
            path_snapshot_value.clear();
        }
    }
    PathSnapshot(const PathSnapshot&) = delete;
    PathSnapshot& operator=(const PathSnapshot&) = delete;
};

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
    sort_newest_first(candidates);
    for (const auto& version : candidates) {
        const fs::path candidate =
            version / L"bin" / L"Hostx64" / L"x64" / relative;
        if (fs::exists(candidate)) return candidate.wstring();
    }
    return {};
}

std::wstring find_packaging_tool(const std::wstring& name,
                                 const std::wstring& vs_root) {
    const std::wstring program_files =
        environment_variable(L"ProgramFiles");
    const std::wstring program_files_x86 =
        environment_variable(L"ProgramFiles(x86)");
    std::vector<fs::path> candidates;

    if (name == L"7z") {
        for (const auto& root : {program_files, program_files_x86}) {
            if (!root.empty())
                candidates.emplace_back(fs::path(root) / L"7-Zip" / L"7z.exe");
        }
    } else if (name == L"makensis") {
        for (const auto& root : {program_files_x86, program_files}) {
            if (!root.empty())
                candidates.emplace_back(fs::path(root) / L"NSIS" / L"makensis.exe");
        }
    } else if (name == L"iscc") {
        for (const auto& root : {program_files_x86, program_files}) {
            if (root.empty()) continue;
            for (const auto& directory :
                 directories_by_newest(fs::path(root), L"Inno Setup"))
                candidates.emplace_back(directory / L"ISCC.exe");
        }
    } else if (name == L"candle" || name == L"light") {
        for (const auto& root : {program_files_x86, program_files}) {
            if (root.empty()) continue;
            for (const auto& toolset :
                 directories_by_newest(fs::path(root), L"WiX Toolset"))
                for (const auto& version : directories_by_newest(toolset, L"v"))
                    candidates.emplace_back(version / L"bin" /
                                            (name + L".exe"));
        }
    } else if (name == L"msbuild" && !vs_root.empty()) {
        candidates.emplace_back(fs::path(vs_root) / L"MSBuild" / L"Current" /
                                L"Bin" / L"MSBuild.exe");
        candidates.emplace_back(fs::path(vs_root) / L"MSBuild" / L"Current" /
                                L"Bin" / L"amd64" / L"MSBuild.exe");
    } else if ((name == L"makeappx" || name == L"signtool") &&
               !program_files_x86.empty()) {
        // The SDK major version and its sub-versions change over time, so scan
        // instead of assuming a "10" root or a specific build number.
        const fs::path kits = fs::path(program_files_x86) / L"Windows Kits";
        for (const auto& kit : directories_by_newest(kits, L"")) {
            const fs::path bin = kit / L"bin";
            for (const auto& version : directories_by_newest(bin, L""))
                candidates.emplace_back(version / L"x64" / (name + L".exe"));
            // Older SDK layouts keep the architectures directly under bin.
            candidates.emplace_back(bin / L"x64" / (name + L".exe"));
        }
    }

    for (const auto& candidate : candidates) {
        std::error_code ec;
        if (fs::is_regular_file(candidate, ec)) return candidate.wstring();
    }
    return {};
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

// Collapse a tool's raw "--version" output into a short version token so the
// toolchain result stays a pure, low-noise probe. Multi-line output keeps only
// its first line; well-known redundant prefixes and trailing trivia are
// stripped. Tools whose raw text is already a plain version are left intact.
std::string normalize_version(const std::string& raw) {
    std::string value =
        raw.substr(0, raw.find_first_of("\r\n"));
    while (!value.empty() &&
           (value.back() == ' ' || value.back() == '\t' ||
            value.back() == '\r'))
        value.pop_back();
    const std::size_t start = value.find_first_not_of(" \t");
    if (start != std::string::npos) value.erase(0, start);

    const std::array<std::string, 9> prefixes{{
        "git version ", "cmake version ", "bsdtar ", "GNU bash, version ",
        "Python ", "tar (", "wget ", "curl ", "v"}};
    for (const auto& prefix : prefixes) {
        if (value.rfind(prefix, 0) == 0) {
            value.erase(0, prefix.size());
            break;
        }
    }
    if (!value.empty() && value.back() == ' ') value.pop_back();
    if (!value.empty()) return value;
    return raw;
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

// A write removes its own temporary file when it fails, but nothing runs after
// a kill or a crash, so every interrupted write leaves one behind and nothing
// ever collects them. Measured on this machine after one round of stress tests
// that killed the process: 4384 orphans, 292 MB, beside six real entries under
// 20 KB -- the cache was 15000 times larger than the data it held. Sweeping is
// one directory iteration at startup, and the one-hour age guard keeps a
// concurrent install's fresh temp out of it.
void sweep_orphan_temporaries(const fs::path& directory) {
    std::error_code ec;
    const auto cutoff = fs::file_time_type::clock::now() - std::chrono::hours(1);
    for (fs::directory_iterator it(directory, ec), end; !ec && it != end;
         it.increment(ec)) {
        std::error_code entry_error;
        const fs::path path = it->path();
        if (path.extension() != L".tmp") continue;
        const auto written = fs::last_write_time(path, entry_error);
        if (entry_error || written > cutoff) continue;
        fs::remove(path, entry_error);
    }
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
    const fs::path directory = fs::path(local) / L"machine-env" / L"cache";
    static std::once_flag swept;
    std::call_once(swept, [&directory] { sweep_orphan_temporaries(directory); });
    return directory;
}

// Every lock below is only ever waited for with a bound: a stuck holder must
// cost a degraded operation, never a frozen caller.
constexpr wchar_t kCacheMutexName[] = L"Local\\machine-env-cache-v2";
// Far longer than writing one entry and renaming it takes, so a timeout means
// the holder is stuck rather than merely slow.
constexpr DWORD kCacheMutexWaitMs = 2000;
// One probe per kind at a time across processes. A waiter that cannot get this
// within the bound probes anyway instead of waiting forever.
constexpr DWORD kProbeMutexWaitMs = 3000;
// A refresh asked for inside this window of the last write is answered from
// that write: at that age the entry is what a fresh probe would produce, and
// five clients starting together would otherwise run five full probes.
constexpr int kRefreshMinIntervalMs = 5000;

class NamedMutex {
public:
    NamedMutex(const wchar_t* name, DWORD timeout_ms)
        : handle_(CreateMutexW(nullptr, FALSE, name)) {
        if (handle_) {
            // An abandoned mutex is a lock this caller now owns: the previous
            // holder died, and any file it left half-written is exactly what
            // the checksum and the atomic rename already reject.
            const DWORD wait = WaitForSingleObject(handle_, timeout_ms);
            acquired_ = wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED;
        }
    }
    ~NamedMutex() {
        if (handle_) {
            if (acquired_) ReleaseMutex(handle_);
            CloseHandle(handle_);
        }
    }
    // A caller that did not get the lock continues in a degraded mode instead
    // of failing: losing the race may cost a redundant probe, never the answer.
    bool acquired() const { return acquired_; }
    NamedMutex(const NamedMutex&) = delete;
    NamedMutex& operator=(const NamedMutex&) = delete;

private:
    HANDLE handle_ = nullptr;
    bool acquired_ = false;
};

std::wstring probe_mutex_name(const std::string& kind) {
    return std::wstring(L"Local\\machine-env-probe-") + wide(kind);
}

fs::path cache_file(const std::string& kind) {
    return cache_directory() / (wide(kind + ".json"));
}

// Why the last read missed, recorded for the caller that asked. It is
// thread_local rather than shared because a reason belongs to one read: with
// requests running concurrently, a shared string would let one request's
// "checksum mismatch" be reported as another request's miss reason, which is a
// silent wrong answer rather than a crash.
thread_local std::string cache_read_failure;

// A cache entry carries a checksum over everything that decides the answer, so
// a file that was edited, truncated, or half-written by something else is
// rejected and re-probed instead of being served as fact. The point is that a
// wrong answer must not be silent; the checksum detects corruption rather than
// forgery, since anything able to rewrite the file could also recompute it.
std::string cache_checksum(const Json& entry) {
    Json covered = Json::object();
    for (const char* key :
         {"cached_at", "fingerprint", "machine_guid", "payload"}) {
        if (entry.contains(key)) covered[key] = entry.get(key);
    }
    // Object keys serialize in sorted order and numbers use a fixed precision,
    // so the same content always yields the same bytes and the same checksum.
    const std::string serialized = dump_json(covered);
    std::uint64_t hash = 14695981039346656037ull;
    for (const char byte : serialized) {
        hash ^= static_cast<unsigned char>(byte);
        hash *= 1099511628211ull;
    }
    std::ostringstream output;
    output << std::hex << hash;
    return output.str();
}

Json read_cache_entry(const std::string& kind, int ttl,
                      bool ignore_expiry = false) {
    cache_read_failure = "no cache file";
    // Deliberately lock-free, not an oversight. Waiting for the writer lock
    // here made a contended read cost the full lock bound before degrading,
    // which is the most expensive thing this probe could do for no safety
    // gain. Three properties make a lockless read safe:
    //   1. A writer never touches the destination in place: it writes a
    //      separate "<destination>.<pid>-<tick>.tmp" and only then replaces the
    //      destination with MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH), and
    //      an NTFS rename within one directory is atomic.
    //   2. So a reader can only ever observe the previous complete entry or the
    //      new complete entry, never a half-written file.
    //   3. Anything that still slips through is caught: the checksum covers
    //      cached_at, fingerprint, machine_guid and payload, so a torn or
    //      mixed entry is rejected as a miss and re-probed, never served.
    // Nothing here writes back, so there is no heal step to skip either.
    const fs::path path = cache_file(kind);
    std::ifstream stream(path, std::ios::binary);
    // A concurrent rename can leave the destination unopenable for an instant,
    // which is not the same as the entry being absent. Retrying only when the
    // file is actually there keeps a cold cache immediate while a busy one is
    // not reported as a miss: a spurious miss is what makes concurrent callers
    // repeat work that the cache was supposed to save.
    for (int attempt = 0; !stream && attempt < 3; ++attempt) {
        if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) break;
        Sleep(1);
        stream.open(path, std::ios::binary);
    }
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
        // Verify before trusting anything the entry says: an entry written by
        // an older build has no checksum, so it is discarded once and then
        // rewritten in the current form.
        const Json& checksum_value = entry.get("checksum");
        if (!checksum_value.is_string()) {
            cache_read_failure = "cache has no checksum";
            return Json();
        }
        if (checksum_value.as_string() != cache_checksum(entry)) {
            cache_read_failure = "cache failed its checksum";
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
        const std::string current_fingerprint = source_fingerprint();
        if (current_fingerprint.empty()) {
            cache_read_failure = "server binary could not be verified";
            return Json();
        }
        if (fingerprint_value.as_string() != current_fingerprint) {
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
    NamedMutex mutex(kCacheMutexName, kCacheMutexWaitMs);
    if (!mutex.acquired()) {
        // Skipping the write is the point of the bound: waiting any longer
        // would stall the caller for a cache that is only an optimisation.
        // not_cached_because carries this back, so a degraded write is
        // reported rather than silently lost.
        error = "cache busy";
        return false;
    }
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
    entry["checksum"] = cache_checksum(entry);
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
    // A probe that ran out of its budget answered with whatever finished. That
    // is worth returning, but storing it would serve "did not answer in time"
    // as a fact for the whole TTL of the entry, long after the host recovered.
    const Json& over_budget = payload.get("budget_exhausted");
    const bool partial = over_budget.is_bool() && over_budget.as_bool();
    if (!payload.contains("error") && !partial) {
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
    } else if (payload.contains("error")) {
        result_metadata["cached"] = false;
        result_metadata["not_cached_because"] = payload.get("error");
    } else {
        result_metadata["cached"] = false;
        result_metadata["not_cached_because"] = "budget exhausted";
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
    isa["avx_vnni"] = avx && ((eax71 >> 4) & 1);
    isa["avx512f"] = avx512;
    isa["avx512bw"] = avx512 && ((ebx7 >> 30) & 1);
    isa["avx512vnni"] = avx512 && ((ecx7 >> 11) & 1);
    isa["bmi2"] = (ebx7 >> 8) & 1;
    return vendor;
}

// "Unreachable" alone is not actionable, so classify the failure the caller
// would otherwise have to re-discover by hand.
const char* network_failure_reason(DWORD error_code) {
    switch (error_code) {
        case ERROR_WINHTTP_NAME_NOT_RESOLVED:
            return "dns";
        case ERROR_WINHTTP_CANNOT_CONNECT:
            return "connect";
        case ERROR_WINHTTP_TIMEOUT:
            return "timeout";
        case ERROR_WINHTTP_SECURE_FAILURE:
            return "tls";
        case ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED:
            return "client-certificate-required";
        case ERROR_WINHTTP_INVALID_SERVER_RESPONSE:
        case ERROR_WINHTTP_UNRECOGNIZED_SCHEME:
            return "response";
        default:
            return "other";
    }
}

Json probe_one_endpoint(const wchar_t* host) {
    Json result = Json::object();
    const auto started = std::chrono::steady_clock::now();
    // Built from the version constant so the two cannot drift apart.
    static const std::wstring user_agent =
        L"machine-env/" + wide(kServerVersion);
    HINTERNET session = WinHttpOpen(
        user_agent.c_str(),
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result["ok"] = false;
        result["error"] = "WinHttpOpen failed";
        result["ms"] = 0;
        return result;
    }
    // Per-phase cap. A host blackholed at the DNS layer can still block for the
    // system resolver's own timeout (~4s here) regardless of this value, but
    // probe_network runs the hosts concurrently so the call costs the slowest
    // endpoint rather than their sum. A hard wall-clock deadline would need a
    // cancellation/watchdog design rather than a shorter per-phase timeout.
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
    if (ok) {
        result["status"] = static_cast<int>(status);
    } else {
        result["reason"] = network_failure_reason(error_code);
        result["error"] = "HTTPS request failed (WinHTTP " +
                          std::to_string(error_code) + ")";
    }
    return result;
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

std::string machine_uuid() {
    std::string input = machine_guid();
    if (input.empty() || input == "unknown-machine") {
        std::array<wchar_t, MAX_COMPUTERNAME_LENGTH + 1> computer{};
        DWORD size = static_cast<DWORD>(computer.size());
        if (GetComputerNameW(computer.data(), &size))
            input = "computer:" + utf8(computer.data());
    }
    std::uint64_t hash = 14695981039346656037ull;
    for (unsigned char ch : input) {
        hash ^= ch;
        hash *= 1099511628211ull;
    }
    std::ostringstream output;
    output << "m-" << std::hex << hash;
    return output.str();
}

// An empty result means the running executable could not be read, so its
// identity is unknown; a cache entry must never be accepted in that state.
std::string source_fingerprint() {
    static const std::string fingerprint = [] {
        std::array<wchar_t, 32768> executable{};
        const DWORD size = GetModuleFileNameW(nullptr, executable.data(),
                                              static_cast<DWORD>(executable.size()));
        if (!size || size >= executable.size()) return std::string();
        std::ifstream stream(fs::path(executable.data()), std::ios::binary);
        if (!stream) return std::string();
        std::uint64_t hash = 14695981039346656037ull;
        std::array<char, 8192> bytes{};
        while (stream) {
            stream.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
            for (std::streamsize i = 0; i < stream.gcount(); ++i) {
                hash ^= static_cast<unsigned char>(bytes[static_cast<std::size_t>(i)]);
                hash *= 1099511628211ull;
            }
        }
        // A partial read must not masquerade as a complete fingerprint.
        if (stream.bad()) return std::string();
        std::ostringstream output;
        output << kServerVersion << '-' << std::hex << hash;
        return output.str();
    }();
    return fingerprint;
}

// Display adapters are read from the display class key instead of WMI: the
// Win32_VideoController.AdapterRAM field is 32-bit, so it saturates and reports
// 4 GB for a 24 GB card. The class key carries the driver's own 64-bit figure,
// which agrees with what the vendor tooling reports for the same adapter.
Json probe_display_adapters(bool& enumeration_incomplete) {
    const wchar_t* display_class =
        L"SYSTEM\\CurrentControlSet\\Control\\Class\\"
        L"{4d36e968-e325-11ce-bfc1-08002be10318}";
    enumeration_incomplete = false;
    Json adapters = Json::array();
    HKEY class_key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, display_class, 0,
                      KEY_ENUMERATE_SUB_KEYS, &class_key) != ERROR_SUCCESS) {
        // An empty list is a legitimate answer for "no display adapter", so a
        // failed walk has to be distinguishable from a complete one.
        enumeration_incomplete = true;
        return adapters;
    }
    for (DWORD index = 0;; ++index) {
        std::array<wchar_t, 64> subkey{};
        DWORD subkey_size = static_cast<DWORD>(subkey.size());
        const LONG status = RegEnumKeyExW(class_key, index, subkey.data(),
                                          &subkey_size, nullptr, nullptr,
                                          nullptr, nullptr);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) {
            // A partial walk must not look like a machine with fewer adapters
            // than it actually has.
            enumeration_incomplete = true;
            break;
        }
        // Adapter instances live in four-digit subkeys. The class key also
        // holds Properties and Configuration, which describe no adapter.
        bool instance = subkey_size == 4;
        for (DWORD i = 0; instance && i < subkey_size; ++i)
            if (subkey[i] < L'0' || subkey[i] > L'9') instance = false;
        if (!instance) continue;
        const std::wstring path = std::wstring(display_class) + L"\\" +
                                  std::wstring(subkey.data(), subkey_size);
        const auto description =
            registry_string(HKEY_LOCAL_MACHINE, path.c_str(), L"DriverDesc");
        if (description.empty()) {
            // An instance that cannot be described is still an instance, so the
            // list is short rather than empty of that adapter.
            enumeration_incomplete = true;
            continue;
        }
        Json adapter = Json::object();
        adapter["name"] = utf8(description);
        const auto provider =
            registry_string(HKEY_LOCAL_MACHINE, path.c_str(), L"ProviderName");
        if (!provider.empty()) adapter["provider"] = utf8(provider);
        const auto driver =
            registry_string(HKEY_LOCAL_MACHINE, path.c_str(), L"DriverVersion");
        if (!driver.empty()) adapter["driver_version"] = utf8(driver);
        const auto matching = registry_string(
            HKEY_LOCAL_MACHINE, path.c_str(), L"MatchingDeviceId");
        if (!matching.empty()) adapter["matching_device_id"] = utf8(matching);
        // A physical adapter is enumerated on a hardware bus. An indirect
        // display driver has no hardware behind it and a root-enumerated
        // adapter is not a device, so both are reported but never counted as
        // something that can be used.
        std::wstring bus = matching;
        const auto separator = bus.find(L'\\');
        if (separator != std::wstring::npos) bus.resize(separator);
        adapter["virtual"] = _wcsicmp(bus.c_str(), L"pci") != 0 &&
                             _wcsicmp(bus.c_str(), L"acpi") != 0;
        unsigned long long memory = 0;
        if (registry_qword(HKEY_LOCAL_MACHINE, path.c_str(),
                           L"HardwareInformation.qwMemorySize", memory) &&
            memory > 0) {
            adapter["vram_mb"] = static_cast<std::int64_t>(
                memory / (1024ull * 1024ull));
        }
        adapters.as_array().push_back(std::move(adapter));
    }
    RegCloseKey(class_key);
    // Physical adapters come first, largest memory first, so the adapter that
    // decides what can run locally is the one that reads first.
    std::stable_sort(adapters.as_array().begin(), adapters.as_array().end(),
                     [](const Json& left, const Json& right) {
                         const bool left_virtual = left.get("virtual").is_bool() &&
                                                   left.get("virtual").as_bool();
                         const bool right_virtual =
                             right.get("virtual").is_bool() &&
                             right.get("virtual").as_bool();
                         if (left_virtual != right_virtual)
                             return !left_virtual;
                         const Json& left_memory = left.get("vram_mb");
                         const Json& right_memory = right.get("vram_mb");
                         return (left_memory.is_number()
                                     ? left_memory.as_integer()
                                     : 0) >
                                (right_memory.is_number()
                                     ? right_memory.as_integer()
                                     : 0);
                     });
    return adapters;
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

    bool adapters_incomplete = false;
    result["gpu"] = probe_display_adapters(adapters_incomplete);
    if (adapters_incomplete) result["gpu_enumeration_incomplete"] = true;

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

// Declared once, outside the probe, so the probe and the concise summary cannot
// disagree about which tools exist or in what order they are reported. A tool
// added here shows up in both, with no second list to keep in step.
const std::array<std::pair<const wchar_t*, const wchar_t*>, 47> kProbeTools{{
    {L"python", L"python.exe"}, {L"pip", L"pip.exe"}, {L"uv", L"uv.exe"},
    {L"git", L"git.exe"}, {L"node", L"node.exe"}, {L"npm", L"npm.exe"},
    {L"cargo", L"cargo.exe"}, {L"go", L"go.exe"}, {L"java", L"java.exe"},
    {L"cmake", L"cmake.exe"}, {L"ninja", L"ninja.exe"}, {L"cl", L"cl.exe"},
    {L"docker", L"docker.exe"}, {L"wsl", L"wsl.exe"},
    {L"pwsh", L"pwsh.exe"}, {L"code", L"code.exe"},
    {L"code-insiders", L"code-insiders.exe"}, {L"winget", L"winget.exe"},
    {L"choco", L"choco.exe"}, {L"scoop", L"scoop.exe"},
    {L"7z", L"7z.exe"}, {L"7zz", L"7zz.exe"}, {L"tar", L"tar.exe"},
    {L"makensis", L"makensis.exe"}, {L"iscc", L"ISCC.exe"},
    {L"wix", L"wix.exe"}, {L"candle", L"candle.exe"},
    {L"light", L"light.exe"}, {L"nuget", L"nuget.exe"},
    {L"dotnet", L"dotnet.exe"}, {L"msbuild", L"MSBuild.exe"},
    {L"makeappx", L"MakeAppx.exe"}, {L"signtool", L"signtool.exe"},
    {L"clang", L"clang.exe"}, {L"clang-cl", L"clang-cl.exe"},
    {L"gcc", L"gcc.exe"}, {L"rustc", L"rustc.exe"},
    {L"make", L"make.exe"}, {L"nmake", L"nmake.exe"},
    {L"meson", L"meson.exe"}, {L"bazel", L"bazel.exe"},
    {L"xmake", L"xmake.exe"}, {L"pnpm", L"pnpm.exe"},
    {L"yarn", L"yarn.exe"}, {L"bun", L"bun.exe"},
    {L"deno", L"deno.exe"}, {L"corepack", L"corepack.exe"}
}};

const std::vector<std::string>& tool_catalog_names() {
    static const std::vector<std::string> names = [] {
        std::vector<std::string> result;
        result.reserve(kProbeTools.size());
        for (const auto& tool : kProbeTools) result.push_back(utf8(tool.first));
        return result;
    }();
    return names;
}

const char* server_version() { return kServerVersion; }

int refresh_min_interval_ms() { return kRefreshMinIntervalMs; }

Json locate_tool(const std::string& name) {
    Json result = Json::object();
    const std::wstring base = wide(name);
    // SearchPathW only appends an extension when lpExtension is given, so the
    // suffix has to be part of the name: passing a bare name looks for a file
    // literally called that and never finds the executable.
    const wchar_t* const suffixes[] = {L".exe", L".cmd", L".bat"};
    for (const wchar_t* suffix : suffixes) {
        const std::wstring found = search_executable((base + suffix).c_str());
        if (found.empty()) continue;
        result["path"] = utf8(found);
        // Reading a version means running the file, so it stays limited to a
        // plain executable, the same limit discovery already holds itself to.
        if (_wcsicmp(suffix, L".exe") == 0) {
            const auto version = run_process(found, L"--version");
            if (version.ok && !version.output.empty())
                result["version"] = normalize_version(version.output);
        }
        return result;
    }
    return result;
}

Json probe_toolchain(bool include_versions) {
    // One PATH read for every executable this probe looks for.
    const PathSnapshot path_snapshot;
    Json result = Json::object();
    Json found = Json::object();
    Json versions = Json::object();
    Json version_unknown = Json::array();
    Json not_on_path = Json::array();
    std::string vs_detection;
    const std::wstring vs_root = visual_studio_root(vs_detection);
    result["vs_path"] = utf8(vs_root);
    result["vs_detection"] = vs_detection;
    result["python_root"] = "";
    std::wstring python_directory;
    bool pip_mismatch = false;
    int tool_count = 0;

    for (const auto& tool : kProbeTools) {
        std::wstring path;
        bool off_path = false;
        if (tool.first == std::wstring(L"python")) {
            path = discover_python_executable();
            if (!path.empty()) {
                python_directory = fs::path(path).parent_path().wstring();
                // python is picked by a search order rather than by PATH, so a
                // path that differs from what PATH resolves to is not the
                // interpreter the bare name "python" will run, and has to say
                // so instead of looking reachable by name.
                const std::wstring on_path = search_executable(L"python.exe");
                if (on_path.empty() ||
                    _wcsicmp(on_path.c_str(), path.c_str()) != 0)
                    off_path = true;
            }
        } else if (tool.first == std::wstring(L"pip") &&
                   !python_directory.empty()) {
            // Pair pip with the interpreter that will actually run, so an agent
            // does not install packages for a different Python installation.
            std::error_code pip_error;
            for (const wchar_t* name : {L"pip.exe", L"pip3.exe"}) {
                const fs::path candidate =
                    fs::path(python_directory) / L"Scripts" / name;
                if (fs::is_regular_file(candidate, pip_error)) {
                    path = candidate.wstring();
                    break;
                }
                pip_error.clear();
            }
        }
        if (path.empty() && tool.first != std::wstring(L"python"))
            path = search_executable(tool.second);
        if (path.empty()) {
            if (tool.first == std::wstring(L"npm"))
                path = search_executable(L"npm.cmd");
            else if (tool.first == std::wstring(L"code"))
                path = search_executable(L"code.cmd");
            else if (tool.first == std::wstring(L"code-insiders"))
                path = search_executable(L"code-insiders.cmd");
            else if (tool.first == std::wstring(L"pnpm"))
                path = search_executable(L"pnpm.cmd");
            else if (tool.first == std::wstring(L"yarn"))
                path = search_executable(L"yarn.cmd");
            else if (tool.first == std::wstring(L"corepack"))
                path = search_executable(L"corepack.cmd");
            else if (tool.first == std::wstring(L"scoop")) {
                path = search_executable(L"scoop.cmd");
                if (path.empty()) path = search_executable(L"scoop.ps1");
            }
        }
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
        if (path.empty() &&
            (tool.first == std::wstring(L"7z") ||
             tool.first == std::wstring(L"makensis") ||
             tool.first == std::wstring(L"iscc") ||
             tool.first == std::wstring(L"candle") ||
             tool.first == std::wstring(L"light") ||
             tool.first == std::wstring(L"msbuild") ||
             tool.first == std::wstring(L"makeappx") ||
             tool.first == std::wstring(L"signtool"))) {
            path = find_packaging_tool(tool.first, vs_root);
            off_path = !path.empty();
        }
        if (tool.first == std::wstring(L"pip") && !path.empty() &&
            !python_directory.empty()) {
            const fs::path pip_root = fs::path(path).parent_path().parent_path();
            result["pip_root"] = utf8(pip_root.wstring());
            const std::wstring path_pip = search_executable(L"pip.exe");
            if (!path_pip.empty() && _wcsicmp(path_pip.c_str(), path.c_str()) != 0)
                off_path = true;
            if (_wcsicmp(pip_root.c_str(), python_directory.c_str()) != 0)
                pip_mismatch = true;
        }
        if (path.empty()) continue;
        found[utf8(tool.first)] = utf8(path);
        ++tool_count;
        if (off_path) not_on_path.as_array().emplace_back(utf8(tool.first));

        // Skip version probing for tools that are expensive, shell wrappers, or
        // whose "--version" text is long/verbose. Discovery never executes
        // user tooling that isn't a plain .exe. Running anything at all is
        // skipped unless the caller asked for versions: locating a tool is a
        // filesystem question, and answering it used to cost one child process
        // per tool (measured: the whole call went from ~1.3s to tens of ms).
        if (!include_versions) continue;
        if (tool.first == std::wstring(L"python") ||
            tool.first == std::wstring(L"pip") ||
            tool.first == std::wstring(L"cl") ||
            tool.first == std::wstring(L"msbuild") ||
            tool.first == std::wstring(L"makeappx") ||
            tool.first == std::wstring(L"signtool") ||
            tool.first == std::wstring(L"nmake") ||
            tool.first == std::wstring(L"tar") ||
            path.size() < 4 ||
            _wcsicmp(path.c_str() + path.size() - 4, L".exe") != 0)
            continue;
        std::wstring args = L"--version";
        if (tool.first == std::wstring(L"go")) args = L"version";
        if (tool.first == std::wstring(L"pwsh"))
            args = L"-NoLogo -NoProfile -Command \"$PSVersionTable.PSVersion.ToString()\"";
        if (tool.first == std::wstring(L"dotnet")) args = L"--version";
        if (tool.first == std::wstring(L"makensis")) args = L"/VERSION";
        if (tool.first == std::wstring(L"wix") ||
            tool.first == std::wstring(L"7zz"))
            args = L"--version";
        if (tool.first == std::wstring(L"clang") ||
            tool.first == std::wstring(L"clang-cl") ||
            tool.first == std::wstring(L"gcc") ||
            tool.first == std::wstring(L"rustc") ||
            tool.first == std::wstring(L"make") ||
            tool.first == std::wstring(L"meson") ||
            tool.first == std::wstring(L"bazel") ||
            tool.first == std::wstring(L"xmake") ||
            tool.first == std::wstring(L"bun") ||
            tool.first == std::wstring(L"deno"))
            args = L"--version";
        const auto version = run_process(path, args);
        if (version.ok && !version.output.empty())
            versions[utf8(tool.first)] = normalize_version(version.output);
        else
            // A tool whose version could not be read is not a tool without a
            // version, so the two outcomes must not look the same.
            version_unknown.as_array().emplace_back(utf8(tool.first));
    }

    result["tool_count"] = tool_count;
    result["tools"] = found;
    result["versions"] = versions;
    result["version_unknown"] = version_unknown;
    // An empty versions map has two very different causes: no version could be
    // read, or none was asked for. Recording which one it is keeps a caller
    // from reading "not asked" as "unknown".
    result["versions_included"] = include_versions;
    result["not_on_path"] = not_on_path;
    result["python_pip_mismatch"] = pip_mismatch;
    if (found.contains("python")) {
        result["python_root"] =
            utf8(fs::path(wide(found.get("python").as_string())).parent_path().wstring());
    }
    result["machine_id"] = machine_uuid();
    // The raw MachineGuid is deliberately not reported: it identifies this
    // installation to anything that reads it, and the derived id already answers
    // whether two results came from the same machine.
    std::array<wchar_t, MAX_COMPUTERNAME_LENGTH + 1> computer{};
    DWORD computer_size = static_cast<DWORD>(computer.size());
    if (GetComputerNameW(computer.data(), &computer_size))
        result["computer_name"] = utf8(computer.data());
    result["probed_at"] = current_time_iso();
    return result;
}

// "Unreachable" alone is not actionable, so a capability carries the evidence
// behind it: measured was observed, and unknown means it was not verified and
// must not be read as support.
Json capability_of_state(const char* state, const char* source) {
    Json result = Json::object();
    result["state"] = state;
    result["source"] = source;
    return result;
}

const char* measured_state(bool supported) {
    return supported ? "supported" : "unsupported";
}

std::wstring base64_utf16(const std::wstring& text) {
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string bytes;
    bytes.reserve(text.size() * 2);
    for (const wchar_t value : text) {
        bytes.push_back(static_cast<char>(value & 0xff));
        bytes.push_back(static_cast<char>((value >> 8) & 0xff));
    }
    std::string encoded;
    encoded.reserve((bytes.size() + 2) / 3 * 4);
    for (std::size_t index = 0; index < bytes.size(); index += 3) {
        const std::size_t remaining = bytes.size() - index;
        const unsigned first = static_cast<unsigned char>(bytes[index]);
        const unsigned second =
            remaining > 1 ? static_cast<unsigned char>(bytes[index + 1]) : 0u;
        const unsigned third =
            remaining > 2 ? static_cast<unsigned char>(bytes[index + 2]) : 0u;
        const unsigned chunk = (first << 16) | (second << 8) | third;
        encoded.push_back(alphabet[(chunk >> 18) & 0x3f]);
        encoded.push_back(alphabet[(chunk >> 12) & 0x3f]);
        encoded.push_back(remaining > 1 ? alphabet[(chunk >> 6) & 0x3f] : '=');
        encoded.push_back(remaining > 2 ? alphabet[chunk & 0x3f] : '=');
    }
    return std::wstring(encoded.begin(), encoded.end());
}

// Shell syntax support is decided by parsing the construct rather than trusting
// a version number, so the reported answer is observed behavior. The answers
// arrive in the same process invocation as the version fields: starting a shell
// costs far more than the questions do, so asking them separately made the
// system probe pay for several cold starts.
Json probe_shell_capabilities(const ProcessResult& probe) {
    Json capabilities = Json::object();
    capabilities["ampersand_ampersand"] = capability_of_state("unknown", "unknown");
    capabilities["here_string"] = capability_of_state("unknown", "unknown");
    capabilities["non_ascii_pipe_utf8"] = capability_of_state("unknown", "unknown");
    if (!probe.ok) return capabilities;

    // Read only the capability line, so a version string that happens to
    // contain "amp=" cannot be mistaken for an answer.
    std::string answers;
    std::istringstream lines(probe.output);
    std::string line;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("caps=", 0) == 0) {
            answers = line.substr(5);
            break;
        }
    }
    const auto has = [&answers](const char* needle) {
        return answers.find(needle) != std::string::npos;
    };
    // Answering "neither ok nor no" is not a measurement, so the field stays
    // unknown rather than being read as unsupported.
    if (has("amp=ok") || has("amp=no"))
        capabilities["ampersand_ampersand"] =
            capability_of_state(measured_state(has("amp=ok")), "measured");
    if (has("here=ok") || has("here=no"))
        capabilities["here_string"] =
            capability_of_state(measured_state(has("here=ok")), "measured");

    // Non-ASCII text is only trustworthy if it survives the shell-to-pipe path
    // as UTF-8; otherwise reading the output yields mojibake. It is the last
    // thing the script writes, so the test is that the output ends with it.
    if (!probe.output.empty()) {
        const std::string marker = std::string("mark=") + utf8(L"\u6807\u8bb0");
        const bool intact =
            probe.output.size() >= marker.size() &&
            probe.output.compare(probe.output.size() - marker.size(),
                                 marker.size(), marker) == 0;
        capabilities["non_ascii_pipe_utf8"] =
            capability_of_state(measured_state(intact), "measured");
    }
    return capabilities;
}

Json probe_machine_policies() {
    Json policies = Json::object();
    policies["acp"] = static_cast<int>(GetACP());
    policies["oem_cp"] = static_cast<int>(GetOEMCP());
    // Both values are REG_DWORD, so a string reader would silently drop them.
    DWORD long_paths = 0;
    if (registry_dword(HKEY_LOCAL_MACHINE,
                       L"SYSTEM\\CurrentControlSet\\Control\\FileSystem",
                       L"LongPathsEnabled", long_paths))
        policies["long_paths_enabled"] = long_paths != 0;
    DWORD developer_mode = 0;
    if (registry_dword(
            HKEY_LOCAL_MACHINE,
            L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock",
            L"AllowDevelopmentWithoutDevLicense", developer_mode))
        policies["developer_mode"] = developer_mode != 0;
    return policies;
}

// The uninstall keys are what "Apps & features" reads, so they are the
// authoritative inventory. Entries Windows hides are skipped, and duplicates
// across the 64-bit, 32-bit, and per-user hives are collapsed.
Json probe_apps() {
    Json result = Json::object();
    std::map<std::string, Json> unique;
    bool enumeration_incomplete = false;
    const std::array<std::pair<HKEY, const wchar_t*>, 3> hives{{
        {HKEY_LOCAL_MACHINE,
         L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall"},
        {HKEY_LOCAL_MACHINE,
         L"SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"},
        {HKEY_CURRENT_USER,
         L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall"},
    }};
    for (const auto& hive : hives) {
        HKEY key = nullptr;
        if (RegOpenKeyExW(hive.first, hive.second, 0, KEY_READ, &key) !=
            ERROR_SUCCESS) {
            // A hive that cannot be opened hides every application it holds, so
            // the inventory has to say it is short rather than look complete.
            enumeration_incomplete = true;
            continue;
        }
        for (DWORD index = 0;; ++index) {
            std::array<wchar_t, 512> subkey_name{};
            DWORD subkey_size = static_cast<DWORD>(subkey_name.size());
            const LONG enum_status =
                RegEnumKeyExW(key, index, subkey_name.data(), &subkey_size,
                              nullptr, nullptr, nullptr, nullptr);
            if (enum_status == ERROR_NO_MORE_ITEMS) break;
            if (enum_status != ERROR_SUCCESS) {
                // A partial inventory must say so rather than look complete.
                enumeration_incomplete = true;
                break;
            }
            const std::wstring subkey =
                std::wstring(hive.second) + L"\\" + subkey_name.data();
            // One open per application: all five values below live in this key,
            // and opening it per value cost four extra opens for every entry in
            // every hive, for an answer this one handle already holds.
            const RegistryKey app_key(hive.first, subkey.c_str());
            if (!app_key.valid()) continue;
            DWORD system_component = 0;
            if (query_registry_dword(app_key.get(), L"SystemComponent",
                                     system_component) &&
                system_component != 0)
                continue;
            const auto display =
                query_registry_string(app_key.get(), L"DisplayName");
            if (display.empty()) continue;
            Json app = Json::object();
            app["name"] = utf8(display);
            const auto version =
                query_registry_string(app_key.get(), L"DisplayVersion");
            if (!version.empty()) app["version"] = utf8(version);
            const auto publisher =
                query_registry_string(app_key.get(), L"Publisher");
            if (!publisher.empty()) app["publisher"] = utf8(publisher);
            std::wstring location =
                query_registry_string(app_key.get(), L"InstallLocation");
            // Some installers store the path wrapped in quotes; strip them so the
            // reported location can be used as a path directly.
            if (location.size() >= 2 && location.front() == L'"' &&
                location.back() == L'"')
                location = location.substr(1, location.size() - 2);
            if (!location.empty()) app["install_location"] = utf8(location);
            const std::string app_name = app.get("name").as_string();
            const Json& app_version = app.get("version");
            unique[app_name + '\n' +
                   (app_version.is_string() ? app_version.as_string()
                                            : std::string())] = app;
        }
        RegCloseKey(key);
    }
    Json apps = Json::array();
    for (const auto& entry : unique) apps.as_array().push_back(entry.second);
    result["count"] = static_cast<std::int64_t>(apps.as_array().size());
    result["apps"] = apps;
    result["enumeration_incomplete"] = enumeration_incomplete;
    result["probed_at"] = current_time_iso();
    return result;
}

// Joins on scope exit. A probe that throws between starting a helper thread and
// joining it would otherwise destroy a joinable std::thread, which terminates
// the whole server.
class ThreadJoiner {
public:
    explicit ThreadJoiner(std::thread& thread) : thread_(thread) {}
    ~ThreadJoiner() {
        if (thread_.joinable()) thread_.join();
    }
    ThreadJoiner(const ThreadJoiner&) = delete;
    ThreadJoiner& operator=(const ThreadJoiner&) = delete;

private:
    std::thread& thread_;
};

Json probe_system() {
    // One PATH read for the two shell lookups below, and for anything else this
    // probe searches for.
    const PathSnapshot path_snapshot;
    // Snapshot before the probe: the counter is per thread, so the difference
    // at the end covers exactly the processes this call launched, including
    // the ones started inside probe_shell_capabilities.
    const unsigned long long tree_kill_fallbacks_before = tree_kill_fallbacks;
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
    std::uint32_t build_number = 0;
    if (rtl_get_version && rtl_get_version(&version) == 0) {
        os["version"] = std::to_string(version.dwMajorVersion) + "." +
                        std::to_string(version.dwMinorVersion);
        build_number = version.dwBuildNumber;
        os["build"] = static_cast<int>(build_number);
    }
    const auto product_name = registry_string(
        HKEY_LOCAL_MACHINE,
        L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"ProductName");
    std::string caption = product_name.empty() ? "Microsoft Windows"
                                               : utf8(product_name);
    // The registry ProductName still reports "Windows 10" on Windows 11, so the
    // build number (22000 and above) is authoritative for the marketing name.
    const std::string legacy_caption = "Windows 10";
    if (build_number >= 22000 && caption.rfind(legacy_caption, 0) == 0)
        caption.replace(0, legacy_caption.size(), "Windows 11");
    os["caption"] = caption;
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
        // Free physical memory alone does not answer whether a large
        // allocation will fit: a reservation is charged against the commit
        // limit, which can be far smaller when the page file is limited.
        os["commit_limit_mb"] = static_cast<std::int64_t>(
            (memory.ullTotalPageFile + 512 * 1024) / (1024 * 1024));
        os["commit_available_mb"] = static_cast<std::int64_t>(
            (memory.ullAvailPageFile + 512 * 1024) / (1024 * 1024));
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
    // A terminal defaults to pwsh when it is installed, so probing only
    // powershell.exe would under-report capabilities such as "&&".
    const std::wstring pwsh = search_executable(L"pwsh.exe");
    const std::wstring powershell = search_executable(L"powershell.exe");
    const std::wstring& primary_shell = pwsh.empty() ? powershell : pwsh;
    // Everything the primary shell is asked, in one start. Each answer is
    // prefixed rather than positional: a field the shell fails to answer stays
    // absent instead of shifting the values after it, and a warning line cannot
    // be read as a version. The last thing written is the marker, with no
    // trailing newline, because it is judged by being the end of the output.
    const std::wstring shell_script =
        L"$o=@()\n"
        L"try{$o+='ver='+$PSVersionTable.PSVersion.ToString()}catch{}\n"
        L"try{$o+='edi='+$PSVersionTable.PSEdition}catch{}\n"
        L"try{$o+='host='+$Host.Name}catch{}\n"
        L"try{$o+='pol='+[string](Get-ExecutionPolicy)}catch{}\n"
        L"$c=@()\n"
        L"try{[void][scriptblock]::Create('$null && $null');$c+='amp=ok'}"
        L"catch{$c+='amp=no'}\n"
        L"$hs=\"@'\"+[Environment]::NewLine+'x'+[Environment]::NewLine+\"'@\"\n"
        L"try{[void][scriptblock]::Create($hs);$c+='here=ok'}"
        L"catch{$c+='here=no'}\n"
        L"$o+='caps='+($c -join ';')\n"
        L"[Console]::Out.Write((($o -join \"`n\") + \"`nmark=\" + [char]0x6807 "
        L"+ [char]0x8BB0))";
    if (!primary_shell.empty()) {
        shell["shell_path"] = utf8(primary_shell);
        shell["shell_kind"] = pwsh.empty() ? "windows-powershell" : "pwsh";
        // The legacy version is a second shell start and does not depend on the
        // first, so it runs alongside it: the call then costs the slower of the
        // two instead of their sum. It is still only probed when a different
        // powershell.exe actually exists.
        const bool probe_legacy = !pwsh.empty() && !powershell.empty();
        ProcessResult legacy;
        std::thread legacy_thread;
        {
            // Joins on scope exit, so no path can leave a joinable thread
            // behind (which would terminate the process).
            ThreadJoiner joiner(legacy_thread);
            if (probe_legacy) {
                legacy_thread = std::thread([&legacy, &powershell] {
                    // Only the version is needed here; asking for more would
                    // depend on module autoloading and can fail intermittently.
                    legacy = run_process(
                        powershell,
                        L"-NoProfile -NonInteractive -Command "
                        L"\"$PSVersionTable.PSVersion.ToString()\"");
                });
            }
            const auto ps = run_process(
                primary_shell,
                L"-NoProfile -NonInteractive -EncodedCommand " +
                    base64_utf16(shell_script));
            if (ps.ok) {
                // Keyed by the prefix, so only what was actually answered is
                // recorded: a missing answer stays absent instead of becoming
                // an empty string.
                std::map<std::string, std::string> answered;
                std::istringstream lines(ps.output);
                std::string line;
                while (std::getline(lines, line)) {
                    while (!line.empty() &&
                           (line.back() == '\r' || line.back() == '\n' ||
                            line.back() == ' ' || line.back() == '\t'))
                        line.pop_back();
                    const std::size_t equals = line.find('=');
                    if (equals == std::string::npos) continue;
                    answered.emplace(line.substr(0, equals),
                                     line.substr(equals + 1));
                }
                const std::array<std::pair<const char*, const char*>, 4> fields{{
                    {"ver", "ps_version"},
                    {"edi", "ps_edition"},
                    {"host", "ps_host"},
                    {"pol", "execution_policy"}}};
                for (const auto& field : fields) {
                    const auto found = answered.find(field.first);
                    if (found != answered.end() && !found->second.empty())
                        shell[field.second] = found->second;
                }
            }
            // Measured, so it stays right even if the version rule would not be.
            shell["capabilities"] = probe_shell_capabilities(ps);
        }
        if (probe_legacy && legacy.ok && !legacy.output.empty()) {
            const std::string legacy_version =
                legacy.output.substr(0, legacy.output.find_first_of("\r\n"));
            if (!legacy_version.empty())
                shell["windows_powershell_version"] = legacy_version;
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
    int ignored_path_entries = 0;
    // The registry is authoritative because it is what a new shell inherits;
    // the process copy is only a fallback for the rare case it cannot be read.
    const std::wstring registry_path = system_path();
    const std::wstring process_path = environment_variable(L"PATH");
    std::wstring path = registry_path.empty() ? process_path : registry_path;
    paths["path_source"] = registry_path.empty() ? "process" : "registry";
    paths["process_path_differs"] =
        !path.empty() && !process_path.empty() &&
        _wcsicmp(path.c_str(), process_path.c_str()) != 0;
    std::size_t start = 0;
    while (start <= path.size()) {
        const auto end = path.find(L';', start);
        std::wstring entry = path.substr(start, end == std::wstring::npos
                                                    ? std::wstring::npos
                                                    : end - start);
        if (entry.size() >= 2 && entry.front() == L'"' &&
            entry.back() == L'"')
            entry = entry.substr(1, entry.size() - 2);
        if (!entry.empty() && is_existing_directory(entry)) {
            path_entries.as_array().emplace_back(utf8(entry));
        } else if (!entry.empty()) {
            ++ignored_path_entries;
        }
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    paths["path_entries"] = path_entries;
    paths["ignored_path_entry_count"] = ignored_path_entries;
    result["os"] = os;
    result["shell"] = shell;
    result["paths"] = paths;
    result["policies"] = probe_machine_policies();
    result["hardware"] = probe_hardware();
    // Observed rather than assumed: "job" means every process this probe
    // launched was bound to a job object, so a timeout kills the whole tree;
    // "fallback" means at least one launch had to be terminated as a single
    // process. It sits at the top level so it is visible in detail output
    // without changing the concise summary.
    result["process_tree_kill"] =
        tree_kill_fallbacks == tree_kill_fallbacks_before ? "job" : "fallback";
    result["probed_at"] = current_time_iso();
    return result;
}

// Network reachability is its own probe so that local system facts never cause
// an outbound request unless the caller asked for exactly that.
Json probe_network(bool offline, const std::vector<std::string>& skip,
                   int budget_ms) {
    Json result = Json::object();
    Json endpoints = Json::object();
    // The four hosts are independent, so probing them one after another pays
    // their latencies additively: one slow or unreachable endpoint that waits
    // out its timeout would hold the whole answer hostage (measured: a single
    // Hugging Face timeout of ~3s dominated a 4.2s serial call). Running them
    // concurrently makes the call cost the slowest endpoint instead of the
    // sum, without changing any result field that callers already rely on.
    struct Target {
        const char* key;
        const wchar_t* host;
    };
    static const Target targets[] = {
        {"github_api", L"api.github.com"},
        {"github_raw", L"raw.githubusercontent.com"},
        {"huggingface", L"huggingface.co"},
        {"pypi", L"pypi.org"},
    };
    constexpr std::size_t count = sizeof(targets) / sizeof(targets[0]);

    // A skipped endpoint is answered without touching the network: offline
    // skips all of them, skip names individual ones. The reason is recorded so
    // "deliberately not checked" stays distinct from "checked and unreachable",
    // which is what lets a restricted or privacy-sensitive caller avoid a host
    // that only stalls (measured: blackholed names cost ~4s at the resolver).
    std::array<bool, count> should_probe{};
    for (std::size_t i = 0; i < count; ++i) {
        const std::string key = targets[i].key;
        const bool listed =
            std::find(skip.begin(), skip.end(), key) != skip.end();
        should_probe[i] = !offline && !listed;
        if (should_probe[i]) continue;
        Json entry = Json::object();
        entry["ok"] = false;
        entry["skipped"] = true;
        entry["ms"] = 0;
        entry["reason"] = offline ? "offline" : "skipped";
        endpoints[key] = entry;
    }

    std::array<Json, count> probed;
    std::array<bool, count> finished{};
    // The budget turns this call into a race against its own workers: once the
    // deadline passes the function returns while a probe may still be inside
    // WinHTTP. Those workers therefore cannot write into this stack frame, so
    // the result slots live in a shared state that outlives the call and is
    // released by whichever worker finishes last.
    struct SharedState {
        std::mutex mutex;
        std::condition_variable ready;
        std::array<Json, count> results;
        std::array<bool, count> done{};
        std::size_t started = 0;
        std::size_t finished = 0;
    };
    auto state = std::make_shared<SharedState>();
    const auto started_at = std::chrono::steady_clock::now();

    std::size_t planned = 0;
    for (std::size_t i = 0; i < count; ++i)
        if (should_probe[i]) ++planned;
    {
        // Published before any thread starts: a worker that finished before the
        // count was known would otherwise let the wait see "all done".
        std::lock_guard<std::mutex> lock(state->mutex);
        state->started = planned;
    }
    for (std::size_t i = 0; i < count; ++i) {
        if (!should_probe[i]) continue;
        // probe_one_endpoint opens and closes its own WinHTTP session, so the
        // probes share no mutable state and are safe to run side by side.
        // targets has static storage duration and is used directly; capturing
        // it in the lambda would be rejected (static variables cannot be
        // captured), so only the shared state and the index are captured. The
        // state is captured by value precisely so a detached worker keeps it
        // alive on its own.
        std::thread([state, i]() {
            Json one = probe_one_endpoint(targets[i].host);
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->results[i] = std::move(one);
                state->done[i] = true;
                ++state->finished;
            }
            state->ready.notify_all();
        }).detach();
    }

    bool budget_exhausted = false;
    if (planned > 0) {
        std::unique_lock<std::mutex> lock(state->mutex);
        const auto all_done = [&state] {
            return state->finished >= state->started;
        };
        if (budget_ms <= 0) {
            // A caller asking for no budget wants every endpoint answered, which
            // is what the cache writer needs before it stores a result.
            state->ready.wait(lock, all_done);
        } else {
            budget_exhausted = !state->ready.wait_until(
                lock, started_at + std::chrono::milliseconds(budget_ms),
                all_done);
        }
    }
    // Read the slots under the same mutex the workers use: a probe that lands
    // right after the deadline must not be read while it is being written.
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        for (std::size_t i = 0; i < count; ++i) {
            finished[i] = state->done[i];
            if (finished[i]) probed[i] = std::move(state->results[i]);
        }
    }
    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - started_at)
                                .count();
    bool any_over_budget = false;
    for (std::size_t i = 0; i < count; ++i) {
        if (!should_probe[i]) continue;
        if (finished[i]) {
            endpoints[targets[i].key] = std::move(probed[i]);
            continue;
        }
        // Not answered in time is a third answer, distinct from unreachable:
        // the host was asked and did not answer within the caller's deadline.
        any_over_budget = true;
        Json entry = Json::object();
        entry["ok"] = false;
        entry["timed_out"] = true;
        entry["ms"] = static_cast<std::int64_t>(elapsed_ms);
        entry["reason"] = "budget";
        endpoints[targets[i].key] = entry;
    }
    if (offline) result["offline"] = true;
    if (budget_ms > 0) result["budget_ms"] = budget_ms;
    if (any_over_budget) result["budget_exhausted"] = true;
    result["endpoints"] = endpoints;
    result["probed_at"] = current_time_iso();
    return result;
}

// Elevation belongs to this process, not to the machine: the same machine
// answers differently depending on how the client was started, so it is
// recomputed on every call instead of being served from the cache.
Json with_live_session_facts(const std::string& kind, Json payload) {
    if (kind == "system" && payload.get("shell").is_object())
        payload["shell"]["is_admin"] = is_admin();
    return payload;
}

// One cache entry per probe category. System and network facts change often, so
// they expire quickly; the tool and application inventories are stable.
Json cached_probe(const std::string& kind, bool refresh, int network_budget_ms) {
    // Versions get an entry of their own rather than sharing the plain tool
    // inventory: a payload built without versions must never be served to a
    // caller who asked for them, and versions are stable enough to keep for a
    // day once measured.
    const int ttl = (kind == "toolchain" || kind == "toolchain_versions" ||
                     kind == "apps")
                        ? kDefaultTtl
                        : kNetworkTtl;
    if (!refresh) {
        const Json entry = read_cache_entry(kind, ttl);
        if (entry.is_object()) {
            Json payload = entry.get("payload");
            const auto timestamp = entry.get("cached_at").as_integer();
            annotate_cache(payload, cache_metadata("fresh", true, timestamp));
            return with_live_session_facts(kind, std::move(payload));
        }
    }

    const auto run_probe = [&]() {
        const Json metadata = cache_metadata(
            refresh ? "refresh requested" : cache_read_failure, false);
        Json payload = kind == "system"      ? probe_system()
                       : kind == "toolchain" ? probe_toolchain(false)
                       : kind == "toolchain_versions" ? probe_toolchain(true)
                       : kind == "apps"      ? probe_apps()
                                             : probe_network(false, {}, network_budget_ms);
        return with_live_session_facts(
            kind, cacheable_probe(kind, std::move(payload), metadata));
    };

    if (!refresh) return run_probe();

    // A refresh is not a licence to probe unconditionally: five clients that
    // start together would otherwise run five full probes at once, which is how
    // a refresh storm turns into minutes of duplicated work. Two gates, cheapest
    // first. An entry written inside the minimum interval answers the refresh
    // as it stands; a per-kind lock across processes then makes one caller the
    // only one that probes.
    const auto coalesced = [&kind](Json& result) {
        // ignore_expiry is safe here: the age check below is far tighter than
        // any entry's TTL, and read_cache_entry still rejects a bad checksum, a
        // foreign machine, or a timestamp in the future.
        const Json entry = read_cache_entry(kind, 0, true);
        if (!entry.is_object()) return false;
        Json payload = entry.get("payload");
        // A partial or failed result is never stored, but the check keeps an
        // entry written by something else from being served as a refresh.
        if (!payload.is_object() || payload.contains("error")) return false;
        const Json& over_budget = payload.get("budget_exhausted");
        if (over_budget.is_bool() && over_budget.as_bool()) return false;
        const auto cached_at = entry.get("cached_at").as_integer();
        const auto age_ms =
            (static_cast<std::int64_t>(std::time(nullptr)) - cached_at) * 1000;
        if (age_ms < 0 || age_ms >= kRefreshMinIntervalMs) return false;
        Json cache = cache_metadata("refresh coalesced", true, cached_at);
        // cached stays true: the refreshed answer the caller asked for is in
        // the cache. reason says the probe itself was skipped.
        cache["cached"] = true;
        annotate_cache(payload, cache);
        result = with_live_session_facts(kind, std::move(payload));
        return true;
    };
    Json result;
    if (coalesced(result)) return result;

    // The lock covers the probe and the write that publishes its result, so a
    // waiter always sees either a fresh entry (handled above) or no entry and
    // then does the work itself. It is separate from the cache lock on purpose:
    // that one orders file writes, this one orders probes. If it cannot be
    // acquired the other instance is still probing, and probing anyway is
    // deliberate — a stalled holder must not cost this caller its answer.
    NamedMutex probe_lock(probe_mutex_name(kind).c_str(), kProbeMutexWaitMs);
    if (coalesced(result)) return result;
    return run_probe();
}

}  // namespace machine_env
