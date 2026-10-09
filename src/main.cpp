#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>

#include "machine.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cwctype>
#include <iostream>
#include <iomanip>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <utility>

namespace machine_env {
namespace {

Json text_content(const std::string& text) {
    Json item = Json::object();
    item["type"] = "text";
    item["text"] = text;
    Json content = Json::array();
    content.as_array().push_back(item);
    return content;
}

std::string string_field(const Json& value, const std::string& key) {
    const Json& field = value.get(key);
    return field.is_string() ? field.as_string() : std::string();
}

std::string first_line(const std::string& value) {
    const auto end = value.find_first_of("\r\n");
    return value.substr(0, end);
}

// A message is read one byte at a time so the size limit applies while it is
// being read: reading the whole line first and checking its length afterwards
// would let a single huge message be allocated in full before being rejected.
bool read_message(std::istream& input, std::string& line, bool& oversized) {
    constexpr std::size_t kMaxMessageBytes = 8 * 1024 * 1024;
    line.clear();
    oversized = false;
    char byte = 0;
    while (input.get(byte)) {
        if (byte == '\n') return true;
        if (line.size() < kMaxMessageBytes)
            line.push_back(byte);
        else
            oversized = true;
    }
    return !line.empty() || oversized;
}

std::string upper_ascii(const std::string& value) {
    std::string result = value;
    std::transform(result.begin(), result.end(), result.begin(),
                   [](unsigned char ch) {
                       return static_cast<char>(std::toupper(ch));
                   });
    return result;
}

std::string join_tokens(const std::vector<std::string>& values) {
    std::string result;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index) result += ", ";
        result += values[index];
    }
    return result;
}

bool array_contains(const Json& array, const std::string& value) {
    if (!array.is_array()) return false;
    for (const auto& item : array.as_array()) {
        if (item.is_string() && item.as_string() == value) return true;
    }
    return false;
}

std::wstring wide_from_utf8(const std::string& value) {
    if (value.empty()) return {};
    const int size = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0);
    if (size <= 0) return {};
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                             static_cast<int>(value.size()), result.data(),
                             size))
        return {};
    return result;
}

bool is_windows_app_alias(const std::string& path) {
    std::string normalized = path;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   [](unsigned char ch) {
                       return static_cast<char>(std::towlower(ch));
                   });
    return normalized.find("\\microsoft\\windowsapps\\") != std::string::npos;
}

std::string memory_gb(const Json& value, const std::string& key) {
    const Json& field = value.get(key);
    if (!field.is_number()) return {};
    std::ostringstream output;
    output << std::fixed << std::setprecision(1)
           << static_cast<double>(field.as_integer()) / 1024.0 << " GB";
    return output.str();
}

std::string cache_note(const Json& value) {
    const Json& cache = value.get("_cache");
    if (!cache.is_object()) return {};
    std::ostringstream output;
    if (cache.get("hit").is_bool() && cache.get("hit").as_bool()) {
        output << "\n（缓存命中";
        const Json& age = cache.get("age_seconds");
        if (age.is_number()) output << "，" << age.as_integer() << " 秒前";
        output << "）";
    }
    return output.str();
}

// Turn a measured capability into the constraint a caller has to respect, so
// the answer does not have to be discovered by failing once.
std::string shell_syntax_note(const Json& shell) {
    const Json& ampersand =
        shell.get("capabilities").get("ampersand_ampersand");
    if (!ampersand.get("state").is_string()) return {};
    const std::string state = ampersand.get("state").as_string();
    if (state == "unsupported") return "（不支持 &&，改用 ; 或分行）";
    if (state == "unknown") return "（&& 支持情况未验证）";
    return {};
}

// Name the exact shell executable that will run the command, so the answer is
// not merely the version of whichever shell happens to be primary.
std::string shell_executable_label(const Json& shell) {
    const std::string path = string_field(shell, "shell_path");
    const auto separator = path.find_last_of("\\/");
    const std::string name =
        separator == std::string::npos ? path : path.substr(separator + 1);
    return name.empty() ? std::string() : "（" + name + "）";
}

std::string output_encoding_note(const Json& shell) {
    const Json& utf8 =
        shell.get("capabilities").get("non_ascii_pipe_utf8");
    if (!utf8.get("state").is_string()) return {};
    const std::string state = utf8.get("state").as_string();
    if (state == "unsupported") return "（原生输出非 UTF-8，读取可能乱码）";
    if (state == "unknown") return "（输出编码未验证）";
    return {};
}

// Commas separate alternatives; spaces inside one alternative stay part of the
// phrase. Otherwise "visual studio" would also match "Supernova Games Studios".
std::vector<std::string> parse_filter(const std::string& text) {
    std::vector<std::string> tokens;
    std::string current;
    const auto commit = [&tokens, &current]() {
        std::size_t begin = 0;
        while (begin < current.size() &&
               (current[begin] == ' ' || current[begin] == '\t'))
            ++begin;
        std::size_t end = current.size();
        while (end > begin &&
               (current[end - 1] == ' ' || current[end - 1] == '\t'))
            --end;
        if (end > begin) tokens.push_back(current.substr(begin, end - begin));
        current.clear();
    };
    for (const char ch : text) {
        if (ch == ',' || ch == ';') {
            commit();
            continue;
        }
        current.push_back(
            static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
    }
    commit();
    return tokens;
}

bool matches_filter(const std::vector<std::string>& tokens,
                    const std::string& text) {
    if (tokens.empty()) return true;
    std::string lowered = text;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(),
                   [](unsigned char ch) {
                       return static_cast<char>(std::tolower(ch));
                   });
    for (const auto& token : tokens)
        if (lowered.find(token) != std::string::npos) return true;
    return false;
}

std::string summarize_toolchain(const Json& value,
                                const std::vector<std::string>& filter) {
    std::ostringstream output;
    const Json& tools = value.get("tools");
    const Json& not_on_path = value.get("not_on_path");
    // The catalog supplies the set and the order, so a tool cannot be probed and
    // then be missing from the concise answer. A tool that was looked up by name
    // because the catalog does not know it is appended to that order.
    std::vector<std::string> order = tool_catalog_names();
    if (tools.is_object()) {
        for (const auto& entry : tools.as_object()) {
            if (std::find(order.begin(), order.end(), entry.first) ==
                order.end())
                order.push_back(entry.first);
        }
    }

    const auto is_off_path = [&not_on_path](const std::string& name) {
        return array_contains(not_on_path, name);
    };

    bool first = true;
    bool selected_known = false;
    if (tools.is_object()) {
        for (const auto& name : order) {
            const std::string path = string_field(tools, name);
            const std::string version = string_field(value.get("versions"), name);
            const bool version_unknown =
                array_contains(value.get("version_unknown"), name);
            // Whether the filter selected a tool the probe knows is a different
            // question from whether that tool was found.
            if (matches_filter(filter, name)) selected_known = true;
            // An alias is only dropped when a version was measured: dropping it
            // after a failed probe would report an installed tool as missing.
            if (path.empty() ||
                (is_windows_app_alias(path) && version.empty() &&
                 !version_unknown))
                continue;
            // Match the tool name only: a path can contain another tool's name
            // ("...\CMake\Ninja\ninja.exe") and would return unrelated tools.
            if (!matches_filter(filter, name)) continue;
            if (!first) output << "\n";
            first = false;
            output << "- " << upper_ascii(name) << " = " << path;
            if (!version.empty())
                output << " (" << first_line(version) << ")";
            else if (version_unknown)
                output << " (版本未知)";
            if (is_off_path(name)) output << " 不在PATH";
            if (name == "pip" &&
                value.get("python_pip_mismatch").is_bool() &&
                value.get("python_pip_mismatch").as_bool())
                output << " 与PYTHON不同源";
        }
    }
    // A requested name that is not on PATH is still an answer: saying so is the
    // difference between "it is not there" and "nothing was looked for".
    const Json& unresolved = value.get("unresolved_tools");
    if (unresolved.is_array()) {
        for (const auto& item : unresolved.as_array()) {
            if (!item.is_string()) continue;
            const std::string name = item.as_string();
            if (!matches_filter(filter, name)) continue;
            if (!first) output << "\n";
            first = false;
            output << "- " << upper_ascii(name) << " = 未在 PATH 中找到";
        }
    }
    // Saying that nothing matched is the difference between nothing being there
    // and nothing having been compared, which is the same reason a looked-up
    // name is answered instead of omitted.
    if (first && tools.is_object()) {
        if (filter.empty()) {
            output << "未检测到任何已知工具";
        } else if (selected_known) {
            // The filter named something the probe covers, so the tool is
            // absent; that is not the same as the filter matching nothing.
            output << "未检测到：" << join_tokens(filter);
        } else {
            output << "没有匹配的工具：" << join_tokens(filter);
        }
    }
    // Visual Studio detection has its own failure mode: the locator can fail to
    // answer, and the tools it would have found then look uninstalled.
    if (value.get("vs_detection").is_string() &&
        value.get("vs_detection").as_string() == "unknown")
        output << "\n（Visual Studio 检测未完成，cl/msbuild/ninja 可能被漏报）";
    return output.str();
}

std::string summarize_apps(const Json& value,
                           const std::vector<std::string>& filter) {
    const Json& apps = value.get("apps");
    if (!apps.is_array()) return dump_json(value);
    const std::size_t total = apps.as_array().size();
    // A partial inventory must not be presented as a complete one.
    const bool incomplete =
        value.get("enumeration_incomplete").is_bool() &&
        value.get("enumeration_incomplete").as_bool();
    const std::string caveat =
        incomplete ? "（注册表枚举未完成，清单可能不完整）" : std::string();
    if (filter.empty())
        return "已安装应用：" + std::to_string(total) +
               " 项（未列出；可用 filter 按名称、发布者或版本查询）" + caveat;
    std::ostringstream output;
    constexpr std::size_t kMaxShown = 50;
    std::size_t matched = 0;
    std::size_t shown = 0;
    for (const auto& app : apps.as_array()) {
        const std::string name = string_field(app, "name");
        const std::string version = first_line(string_field(app, "version"));
        const std::string publisher = string_field(app, "publisher");
        if (!matches_filter(filter, name + " " + version + " " + publisher))
            continue;
        ++matched;
        // Counting continues past the display cap so the note can state how
        // many matched rather than how many are installed.
        if (shown == kMaxShown) continue;
        if (shown > 0) output << "\n";
        // The version is parenthesised because appending it after a space
        // leaves the boundary between name and version to be guessed.
        output << "- " << name;
        if (!version.empty()) output << " (" << version << ")";
        const std::string location = string_field(app, "install_location");
        if (!location.empty()) output << "\n  位置：" << location;
        ++shown;
    }
    if (shown == 0)
        return "没有匹配的已安装应用（共 " + std::to_string(total) + " 项）" +
               caveat;
    if (matched > shown)
        output << "\n（匹配 " << matched << " 项，仅显示前 " << shown
               << " 条）";
    return output.str() + caveat;
}

std::string summarize_network(const Json& value) {
    const Json& endpoints = value.get("endpoints");
    if (!endpoints.is_object()) return dump_json(value);
    static const std::array<std::pair<const char*, const char*>, 4> order{{
        {"github_api", "GitHub API"},
        {"github_raw", "GitHub Raw"},
        {"huggingface", "Hugging Face"},
        {"pypi", "PyPI"}}};
    std::ostringstream output;
    output << "网络连通性";
    int reachable = 0;
    int checked = 0;
    for (const auto& entry : order) {
        const Json& endpoint = endpoints.get(entry.first);
        if (!endpoint.is_object()) continue;
        ++checked;
        const bool ok =
            endpoint.get("ok").is_bool() && endpoint.get("ok").as_bool();
        if (ok) ++reachable;
        output << "\n- " << entry.second << "：";
        if (ok) {
            output << "可达";
            const Json& status = endpoint.get("status");
            if (status.is_number())
                output << "（HTTP " << status.as_integer() << "）";
        } else {
            output << "不可达";
            const std::string reason = string_field(endpoint, "reason");
            if (!reason.empty()) output << "（原因：" << reason << "）";
        }
        const Json& ms = endpoint.get("ms");
        if (ms.is_number()) output << " " << ms.as_integer() << "ms";
    }
    output << "\n可达 " << reachable << "/" << checked << " 个目标";
    return output.str();
}

std::string summarize_payload(const std::string& name, const Json& value,
                              const std::vector<std::string>& filter) {
    if (!value.is_object()) return dump_json(value);
    if (value.contains("error")) return dump_json(value);

    if (name == "get_tools" || name == "toolchain")
        return summarize_toolchain(value, filter) + cache_note(value);
    if (name == "get_apps" || name == "apps")
        return summarize_apps(value, filter) + cache_note(value);
    if (name == "get_network" || name == "network")
        return summarize_network(value) + cache_note(value);
    if (name == "get_system" || name == "system") {
        std::ostringstream output;
        output << "系统配置";
        const Json& os = value.get("os");
        if (os.is_object()) {
            const std::string caption = string_field(os, "caption");
            if (!caption.empty()) output << "\n操作系统：" << caption;
            const std::string version = string_field(os, "version");
            const Json& build = os.get("build");
            if (!version.empty()) {
                output << " " << version;
                if (build.is_number()) output << " (build " << build.as_integer() << ")";
            }
            const std::string arch = string_field(os, "arch");
            if (!arch.empty()) output << "\n架构：" << arch;
            const std::string cpu = string_field(os, "cpu_name");
            if (!cpu.empty()) output << "\nCPU：" << cpu;
            const auto total = memory_gb(os, "total_mem_mb");
            if (!total.empty()) output << "\n内存：" << total;
        }
        const Json& shell = value.get("shell");
        if (shell.is_object()) {
            const std::string version = string_field(shell, "ps_version");
            const std::string clean_version = first_line(version);
            if (!clean_version.empty())
                output << "\nPowerShell：" << clean_version
                       << shell_executable_label(shell)
                       << shell_syntax_note(shell)
                       << output_encoding_note(shell);
            // Elevation decides whether a command will fail before it is run.
            const Json& admin = shell.get("is_admin");
            if (admin.is_bool())
                output << "\n权限：" << (admin.as_bool() ? "管理员" : "标准用户");
        }
        const Json& paths = value.get("paths");
        if (paths.is_object() &&
            string_field(paths, "path_source") == "process")
            output << "\nPATH：取自进程环境，可能过期";
        const Json& policies = value.get("policies");
        if (policies.is_object()) {
            const Json& acp = policies.get("acp");
            if (acp.is_number())
                output << "\nANSI 代码页：" << acp.as_integer();
        }
        const Json& hardware = value.get("hardware");
        if (hardware.is_object()) {
            const Json& width = hardware.get("vector_width_bits");
            if (width.is_number())
                output << "\n可用向量宽度：" << width.as_integer() << " 位";
            const Json& adapters = hardware.get("gpu");
            if (adapters.is_array()) {
                std::size_t indirect_count = 0;
                for (const auto& adapter : adapters.as_array()) {
                    const Json& indirect = adapter.get("virtual");
                    if (indirect.is_bool() && indirect.as_bool()) {
                        ++indirect_count;
                        continue;
                    }
                    output << "\nGPU：" << string_field(adapter, "name");
                    // Kept in MB so it can be compared directly with what the
                    // vendor tooling reports for the same adapter.
                    const Json& memory = adapter.get("vram_mb");
                    if (memory.is_number())
                        output << "（显存 " << memory.as_integer() << " MB）";
                    else
                        output << "（显存未报告）";
                }
                if (indirect_count)
                    output << "\n虚拟显示适配器：" << indirect_count << " 个";
                // Kept outside the loop so it survives the empty case, which is
                // exactly when a cut-short walk would otherwise look like a
                // machine with no display adapters at all.
                if (hardware.get("gpu_enumeration_incomplete").is_bool())
                    output << "\nGPU 枚举未完成，列表可能不全";
                else if (adapters.as_array().empty())
                    output << "\nGPU：未检测到（枚举已完成）";
            }
        }
        return output.str() + cache_note(value);
    }
    return dump_json(value);
}

Json tool_result(const std::string& name, Json value, bool detail,
                 const std::vector<std::string>& filter) {
    Json result = Json::object();
    if (detail) {
        result["content"] = text_content(dump_json(value));
        result["structuredContent"] = value;
    } else {
        const std::string summary = summarize_payload(name, value, filter);
        result["content"] = text_content(summary);
    }
    return result;
}

Json tool_definition(const char* name, const char* description,
                     const Json& input_schema) {
    Json tool = Json::object();
    tool["name"] = name;
    tool["description"] = description;
    tool["inputSchema"] = input_schema;
    return tool;
}

Json object_schema() {
    Json result = Json::object();
    result["type"] = "object";
    result["properties"] = Json::object();
    result["additionalProperties"] = false;
    return result;
}

Json boolean_schema(const char* description) {
    Json result = Json::object();
    result["type"] = "boolean";
    result["description"] = description;
    return result;
}

Json string_schema(const char* description) {
    Json result = Json::object();
    result["type"] = "string";
    result["description"] = description;
    return result;
}

Json tools() {
    Json list = Json::array();

    Json system = object_schema();
    system["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    system["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    list.as_array().push_back(tool_definition(
        "get_system",
        "Windows, shell, and hardware facts including display adapters and their memory, plus measured shell capabilities and machine policies. Local only: it never makes a network request.",
        system));

    Json tool_list = object_schema();
    tool_list["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    tool_list["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    tool_list["properties"]["name"] = string_schema(
        "Only report tools matching this text, for example \"cmake\" or \"cmake, ninja\". A name the probed catalog does not contain is looked up on PATH instead of being omitted.");
    list.as_array().push_back(tool_definition(
        "get_tools",
        "Locate developer tools and report each executable path, version, and PATH status. A name outside the probed catalog is looked up on PATH rather than silently omitted.",
        tool_list));

    Json apps = object_schema();
    apps["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    apps["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    apps["properties"]["filter"] = string_schema(
        "Match installed applications by name, publisher, or version. Without it only the total count is returned.");
    list.as_array().push_back(tool_definition(
        "get_apps",
        "Installed applications from the Windows uninstall registry, including software with no command-line entry point. Shows name, version, publisher, and install location.",
        apps));

    Json network = object_schema();
    network["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    network["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    list.as_array().push_back(tool_definition(
        "get_network",
        "Check HTTPS reachability of GitHub, Hugging Face, and PyPI. This is the only tool that makes outbound requests; failures report the reason.",
        network));
    return list;
}

bool optional_boolean(const Json& arguments, const char* name,
                      bool default_value, bool& value, std::string& error) {
    const Json& item = arguments.get(name);
    if (std::holds_alternative<std::nullptr_t>(item.value)) {
        value = default_value;
        return true;
    }
    if (!item.is_bool()) {
        error = std::string("argument '") + name + "' must be a boolean";
        return false;
    }
    value = item.as_bool();
    return true;
}

Json rpc_error(const Json& id, int code, const std::string& message) {
    Json response = Json::object();
    response["jsonrpc"] = "2.0";
    response["id"] = id;
    Json error = Json::object();
    error["code"] = code;
    error["message"] = message;
    response["error"] = error;
    return response;
}

// The catalog is a fixed list, so a requested tool outside it would produce no
// output at all, and silence is indistinguishable from "not present". Looking
// the name up on PATH turns that silence into an answer.
void resolve_requested_tools(Json& payload,
                             const std::vector<std::string>& filter) {
    if (filter.empty() || !payload.get("tools").is_object()) return;
    const auto& catalog = tool_catalog_names();
    for (const auto& name : filter) {
        if (name.empty() ||
            std::find(catalog.begin(), catalog.end(), name) != catalog.end())
            continue;
        // A phrase narrows a filter; it is not the name of a program.
        if (name.find(' ') != std::string::npos ||
            name.find('\t') != std::string::npos)
            continue;
        const Json located = locate_tool(name);
        const std::string path = string_field(located, "path");
        if (path.empty()) {
            Json& unresolved = payload["unresolved_tools"];
            if (!unresolved.is_array()) unresolved = Json::array();
            unresolved.as_array().emplace_back(name);
            continue;
        }
        payload["tools"][name] = path;
        Json& versions = payload["versions"];
        if (!versions.is_object()) versions = Json::object();
        Json& unknown = payload["version_unknown"];
        if (!unknown.is_array()) unknown = Json::array();
        const std::string version = string_field(located, "version");
        if (!version.empty())
            versions[name] = version;
        else
            unknown.as_array().emplace_back(name);
    }
}

// The app filter shapes the summary while it is rendered, which a detailed
// result never does: that one hands the payload back as it stands. Narrowing it
// here is what stops the filter from being accepted and then ignored, leaving a
// caller who asked for a subset holding every installed application instead.
// count keeps meaning the size of the inventory, which is the total the summary
// reports and the whole that the subset was drawn from.
void narrow_apps(Json& payload, const std::vector<std::string>& filter) {
    const Json& apps = payload.get("apps");
    if (filter.empty() || !apps.is_array()) return;
    Json kept = Json::array();
    for (const auto& app : apps.as_array()) {
        const std::string name = string_field(app, "name");
        const std::string version = first_line(string_field(app, "version"));
        const std::string publisher = string_field(app, "publisher");
        if (matches_filter(filter, name + " " + version + " " + publisher))
            kept.as_array().push_back(app);
    }
    payload["apps"] = kept;
}

Json dispatch(const Json& request, bool& has_response) {
    has_response = true;
    if (!request.is_object()) return rpc_error(nullptr, -32600, "invalid request");
    const Json& version_value = request.get("jsonrpc");
    if (version_value.is_string() && version_value.as_string() != "2.0")
        return rpc_error(request.get("id"), -32600,
                         "unsupported JSON-RPC version");
    const Json& method_value = request.get("method");
    const Json& id = request.get("id");
    const bool notification = !request.contains("id");
    if (!method_value.is_string()) {
        if (notification) {
            has_response = false;
            return Json();
        }
        return rpc_error(id, -32600, "request method must be a string");
    }
    const std::string method = method_value.as_string();
    if (notification && method.rfind("notifications/", 0) == 0) {
        has_response = false;
        return Json();
    }
    if (notification) {
        has_response = false;
        return Json();
    }

    if (method == "initialize") {
        Json result = Json::object();
        const Json& requested = request.get("params").get("protocolVersion");
        const std::string requested_version =
            requested.is_string() ? requested.as_string() : std::string();
        const bool supported =
            requested_version == "2025-11-25" ||
            requested_version == "2025-06-18" ||
            requested_version == "2025-03-26" ||
            requested_version == "2024-11-05";
        result["protocolVersion"] =
            supported ? requested_version : "2025-11-25";
        result["capabilities"]["tools"]["listChanged"] = false;
        result["serverInfo"]["name"] = "machine-env-cpp";
        result["serverInfo"]["version"] = server_version();
        // This is the rule that is actually injected on every request, so it
        // carries only what has to be obeyed instead of restating the tool
        // schemas the client already sends. It is the only copy of the rule:
        // verify.ps1 checks that the injected text carries the obligations it
        // exists for rather than comparing it with a second file.
        result["instructions"] =
            "本机环境必须实测，不得凭操作系统惯例、旧记忆或猜测推断。涉及系统、shell、"
            "工具路径或版本、已装软件、硬件（含 GPU）、编码或权限，或要为本机选择构建、"
            "测试、运行命令时，先查本 MCP 再作答。本 MCP 只读：未经用户明确要求或批准，"
            "不下载、不安装、不运行安装程序，不修改全局环境。未检测到即说明缺失或给出"
            "替代方案，不要假设已安装；source=unknown 表示未验证，不得当作支持。"
            "留意返回值中的约束（如不支持 &&、原生输出非 UTF-8）并据此改写命令。";
        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = result;
        return response;
    }
    if (method == "ping") {
        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = Json::object();
        return response;
    }
    if (method == "tools/list") {
        Json result = Json::object();
        result["tools"] = tools();
        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = result;
        return response;
    }
    if (method == "tools/call") {
        const Json& params = request.get("params");
        const Json& name_value = params.get("name");
        if (!name_value.is_string())
            return rpc_error(id, -32602, "tool name is required");
        const std::string name = name_value.as_string();
        Json arguments = params.get("arguments");
        if (std::holds_alternative<std::nullptr_t>(arguments.value))
            arguments = Json::object();
        if (!arguments.is_object())
            return rpc_error(id, -32602, "tool arguments must be an object");

        struct ToolSpec {
            const char* kind;
            const char* filter_name;
            std::vector<const char*> arguments;
        };
        static const std::map<std::string, ToolSpec> specs{
            {"get_system", {"system", nullptr, {"refresh", "detail"}}},
            {"get_tools",
             {"toolchain", "name", {"refresh", "detail", "name"}}},
            {"get_apps", {"apps", "filter", {"refresh", "detail", "filter"}}},
            {"get_network", {"network", nullptr, {"refresh", "detail"}}}};
        const auto spec = specs.find(name);
        if (spec == specs.end())
            return rpc_error(id, -32602, "unknown tool: " + name);
        // The declared schema forbids extra properties, so ignore none silently.
        for (const auto& argument : arguments.as_object()) {
            const auto& allowed = spec->second.arguments;
            if (std::find(allowed.begin(), allowed.end(), argument.first) ==
                allowed.end())
                return rpc_error(id, -32602,
                                 "unknown argument: " + argument.first);
        }
        const std::string kind = spec->second.kind;
        Json payload;
        std::string validation_error;
        bool detail = false;
        bool refresh = false;
        std::vector<std::string> filter;
        if (!optional_boolean(arguments, "detail", false, detail,
                              validation_error))
            return rpc_error(id, -32602, validation_error);
        if (!optional_boolean(arguments, "refresh", false, refresh,
                              validation_error))
            return rpc_error(id, -32602, validation_error);
        const char* filter_name = spec->second.filter_name;
        if (filter_name && arguments.contains(filter_name)) {
            const Json& value = arguments.get(filter_name);
            if (!value.is_string())
                return rpc_error(id, -32602,
                                 std::string("argument '") + filter_name +
                                     "' must be a string");
            filter = parse_filter(value.as_string());
        }
        payload = cached_probe(kind, refresh);
        if (kind == "toolchain") resolve_requested_tools(payload, filter);
        if (detail && kind == "apps") narrow_apps(payload, filter);

        Json result = Json::object();
        if (payload.contains("error")) {
            // A tool that could not run is a tool error, not a data payload; a
            // client must not read the failure as a probe result.
            result["content"] = text_content(dump_json(payload));
            result["isError"] = true;
        } else {
            result = tool_result(name, std::move(payload), detail, filter);
        }
        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = result;
        return response;
    }
    // No resources capability is declared, so this method stays unknown rather
    // than serving a capability the client was never told about.
    return rpc_error(id, -32601, "method not found: " + method);
}

int selftest() {
    const auto parsed = parse_json(
        R"({"text":"中文 \ud83d\ude80","array":[true,7,null],"number":-2.5e2})");
    if (parsed.at("text").as_string() != "中文 🚀" ||
        parsed.at("array").as_array().size() != 3 ||
        parsed.at("number").as_integer() != -250)
        throw std::runtime_error("JSON parser round-trip test failed");

    // Deep nesting must be rejected instead of overflowing the stack.
    bool depth_rejected = false;
    try {
        parse_json(std::string(400, '['));
    } catch (const std::exception&) {
        depth_rejected = true;
    }
    if (!depth_rejected)
        throw std::runtime_error("JSON parser accepted deeply nested input");

    const Json hardware = probe_hardware();
    if (!hardware.get("brand").is_string() ||
        hardware.get("brand").as_string().empty() ||
        !hardware.get("isa").is_object())
        throw std::runtime_error("hardware probe returned incomplete data");
    // The adapter list is always present, even when it is empty, so a caller
    // can tell "no adapter was found" from "adapters were not probed".
    const Json adapters = hardware.get("gpu");
    if (!adapters.is_array())
        throw std::runtime_error("display adapter probe returned no array");
    for (const auto& adapter : adapters.as_array()) {
        const Json& memory = adapter.get("vram_mb");
        if (string_field(adapter, "name").empty() ||
            !adapter.get("virtual").is_bool() ||
            (memory.is_number() && memory.as_integer() <= 0))
            throw std::runtime_error("display adapter entry is incomplete");
    }

    const Json local_environment = probe_system();
    if (!local_environment.get("os").is_object() ||
        !local_environment.get("paths").is_object() ||
        !local_environment.get("hardware").is_object() ||
        !local_environment.get("policies").is_object() ||
        local_environment.contains("network"))
        throw std::runtime_error("system probe contract failed");
    const auto is_directory = [](const std::wstring& path) {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
               (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    };
    if (!is_directory(L"C:\\Windows") ||
        is_directory(L"C:\\Windows\\System32\\cmd.exe"))
        throw std::runtime_error("PATH entry directory validation test failed");
    for (const auto& entry :
         local_environment.get("paths").get("path_entries").as_array()) {
        if (!entry.is_string() ||
            !is_directory(wide_from_utf8(entry.as_string())))
            throw std::runtime_error("environment returned an invalid PATH directory");
    }

    const auto is_file = [](const std::wstring& path) {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES &&
               (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
    };
    const Json& shell = local_environment.get("shell");
    const std::string shell_kind = string_field(shell, "shell_kind");
    const std::string shell_version =
        first_line(string_field(shell, "ps_version"));
    // Elevation decides whether elevated commands will work, so it must always
    // be present and boolean.
    if (!shell.get("is_admin").is_bool())
        throw std::runtime_error("elevation state test failed");
    if (!shell_kind.empty()) {
        if (shell_kind != "pwsh" && shell_kind != "windows-powershell")
            throw std::runtime_error("shell kind test failed");
        if (!is_file(wide_from_utf8(string_field(shell, "shell_path"))))
            throw std::runtime_error("shell path test failed");
        if (!shell_version.empty()) {
            int shell_major = 0;
            try {
                shell_major = std::stoi(shell_version);
            } catch (const std::exception&) {
                shell_major = 0;
            }
            const Json& capabilities = shell.get("capabilities");
            const Json& ampersand = capabilities.get("ampersand_ampersand");
            const Json& here_string = capabilities.get("here_string");
            if (!capabilities.is_object() ||
                ampersand.get("source").as_string() != "measured" ||
                here_string.get("source").as_string() != "measured" ||
                ampersand.get("state").as_string() == "unknown" ||
                here_string.get("state").as_string() == "unknown")
                throw std::runtime_error("measured shell capability test failed");
            // PowerShell 5.1 has no "&&"; a probe that reports otherwise is
            // claiming support it never observed.
            if (shell_major == 5 &&
                ampersand.get("state").as_string() == "supported")
                throw std::runtime_error(
                    "measured shell capability contradicts PowerShell 5.1");
            if (shell_kind == "pwsh" && shell_major < 7)
                throw std::runtime_error("pwsh was not probed as the primary shell");
            if (shell_kind == "windows-powershell" && shell_major >= 7)
                throw std::runtime_error("pwsh was not preferred as the primary shell");
        }
    }

    const Json refreshed_system = cached_probe("system", true);
    if (refreshed_system.contains("error") ||
        !refreshed_system.get("_cache").get("cached").as_bool())
        throw std::runtime_error("system cache write test failed");
    const Json cached_system = cached_probe("system", false);
    if (!cached_system.get("_cache").get("hit").as_bool() ||
        cached_system.get("os").get("caption").as_string() !=
            refreshed_system.get("os").get("caption").as_string())
        throw std::runtime_error("system cache round-trip test failed");
    // A local system probe must never carry network data.
    if (cached_system.contains("network"))
        throw std::runtime_error("system probe leaked network data");
    bool has_response = false;
    const Json negotiated = dispatch(
        parse_json(R"({"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"not-supported"}})"),
        has_response);
    if (!has_response ||
        negotiated.get("result").get("protocolVersion").as_string() !=
            "2025-11-25")
        throw std::runtime_error("MCP protocol negotiation test failed");

    const Json init = dispatch(
        parse_json(R"({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}})"),
        has_response);
    if (!has_response ||
        init.get("result").get("serverInfo").get("name").as_string() !=
            "machine-env-cpp")
        throw std::runtime_error("MCP initialize dispatch test failed");
    const Json listing = dispatch(
        parse_json(R"({"jsonrpc":"2.0","id":2,"method":"tools/list"})"),
        has_response);
    if (!has_response ||
        listing.get("result").get("tools").as_array().size() != 4)
        throw std::runtime_error("MCP tools/list dispatch test failed");
    static const std::array<const char*, 4> expected_tools{{
        "get_system", "get_tools", "get_apps", "get_network"}};
    for (const char* expected : expected_tools) {
        bool present = false;
        for (const auto& tool : listing.get("result").get("tools").as_array())
            if (tool.get("name").is_string() &&
                tool.get("name").as_string() == expected)
                present = true;
        if (!present)
            throw std::runtime_error(std::string("missing tool: ") + expected);
    }
    const Json apps_probe = probe_apps();
    if (!apps_probe.get("apps").is_array() ||
        !apps_probe.get("count").is_number() ||
        apps_probe.get("count").as_integer() !=
            static_cast<std::int64_t>(apps_probe.get("apps").as_array().size()))
        throw std::runtime_error("installed application inventory test failed");
    // Completeness must always be stated, never implied.
    if (!apps_probe.get("enumeration_incomplete").is_bool())
        throw std::runtime_error("inventory completeness test failed");
    // A running binary must be verifiable; an unreadable one must not be cached.
    if (source_fingerprint().empty())
        throw std::runtime_error("running binary fingerprint is unavailable");
    for (const auto& app : apps_probe.get("apps").as_array()) {
        if (!app.get("name").is_string() || app.get("name").as_string().empty())
            throw std::runtime_error("installed application entry has no name");
    }
    const Json detected_tools = probe_toolchain();
    if (!detected_tools.get("tools").is_object() ||
        detected_tools.contains("missing") ||
        detected_tools.contains("tool_total"))
        throw std::runtime_error("toolchain installed-only result test failed");
    if (!detected_tools.get("machine_id").is_string() ||
        detected_tools.get("machine_id").as_string().empty())
        throw std::runtime_error("toolchain machine identity test failed");
    // The raw Windows MachineGuid identifies the installation to anything that
    // reads it, so only the derived id may leave the server.
    if (detected_tools.contains("machine_guid"))
        throw std::runtime_error("the raw MachineGuid is exposed");
    if (machine_uuid() != machine_uuid())
        throw std::runtime_error("machine identity is not stable");
    Json sample_system = Json::object();
    sample_system["os"]["caption"] = "Windows 11 Pro";
    sample_system["os"]["version"] = "10.0";
    sample_system["os"]["build"] = 26300;
    sample_system["os"]["arch"] = "64-bit";
    sample_system["os"]["cpu_name"] = "Test CPU";
    sample_system["os"]["total_mem_mb"] = 32768;
    sample_system["shell"]["ps_version"] = "5.1.26100";
    sample_system["shell"]["shell_path"] =
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
    sample_system["shell"]["is_admin"] = true;
    sample_system["shell"]["capabilities"]["ampersand_ampersand"]["state"] =
        "unsupported";
    sample_system["shell"]["capabilities"]["ampersand_ampersand"]["source"] =
        "measured";
    sample_system["policies"]["acp"] = 936;
    sample_system["hardware"]["vector_width_bits"] = 256;
    sample_system["hardware"]["gpu"] = Json::array();
    Json physical = Json::object();
    physical["name"] = "Test GPU";
    physical["vram_mb"] = 8188;
    physical["virtual"] = false;
    sample_system["hardware"]["gpu"].as_array().push_back(std::move(physical));
    Json indirect = Json::object();
    indirect["name"] = "Test Indirect Display";
    indirect["virtual"] = true;
    sample_system["hardware"]["gpu"].as_array().push_back(std::move(indirect));
    const Json summary = tool_result("get_system", sample_system, false, {});
    if (summary.contains("structuredContent") ||
        summary.get("content").as_array().size() != 1)
        throw std::runtime_error("concise summary contract test failed");
    const std::string summary_text =
        summary.get("content").as_array()[0].get("text").as_string();
    if (summary_text.find("Windows 11 Pro") == std::string::npos ||
        summary_text.find("不支持 &&") == std::string::npos ||
        summary_text.find("ANSI 代码页：936") == std::string::npos ||
        summary_text.find("（powershell.exe）") == std::string::npos ||
        summary_text.find("权限：管理员") == std::string::npos ||
        summary_text.find("GPU：Test GPU（显存 8188 MB）") == std::string::npos ||
        summary_text.find("虚拟显示适配器：1 个") == std::string::npos)
        throw std::runtime_error("concise system summary test failed");
    const Json detailed = tool_result("get_system", sample_system, true, {});
    if (!detailed.get("structuredContent").get("hardware").is_object())
        throw std::runtime_error("detailed tool result test failed");
    Json sample_toolchain = Json::object();
    sample_toolchain["computer_name"] = "TEST-PC";
    sample_toolchain["machine_id"] = "test-machine-id";
    sample_toolchain["tools"]["cl"] = "C:\\VS\\cl.exe";
    sample_toolchain["tools"]["git"] = "C:\\Git\\git.exe";
    sample_toolchain["tools"]["python"] =
        "C:\\Python\\python.exe";
    sample_toolchain["versions"]["python"] = "3.14.0";
    sample_toolchain["tools"]["node"] =
        "C:\\Users\\Test\\AppData\\Local\\Microsoft\\WindowsApps\\node.exe";
    sample_toolchain["tools"]["docker"] = "C:\\Docker\\docker.exe";
    sample_toolchain["tools"]["code"] = "C:\\VSCode\\bin\\code.cmd";
    sample_toolchain["tools"]["winget"] = "C:\\Windows\\winget.exe";
    sample_toolchain["tools"]["7z"] = "C:\\Program Files\\7-Zip\\7z.exe";
    sample_toolchain["tools"]["makensis"] =
        "C:\\Program Files (x86)\\NSIS\\makensis.exe";
    sample_toolchain["tools"]["iscc"] = "C:\\Inno Setup\\ISCC.exe";
    sample_toolchain["tools"]["clang"] = "C:\\LLVM\\bin\\clang.exe";
    sample_toolchain["tools"]["pnpm"] = "C:\\Node\\pnpm.cmd";
    sample_toolchain["not_on_path"] = Json::array();
    sample_toolchain["not_on_path"].as_array().emplace_back("cl");
    const std::string toolchain_summary =
        summarize_payload("get_tools", sample_toolchain, {});
    const std::string expected_toolchain_summary =
        "- PYTHON = C:\\Python\\python.exe (3.14.0)\n"
        "- GIT = C:\\Git\\git.exe\n"
        "- CL = C:\\VS\\cl.exe 不在PATH\n"
        "- DOCKER = C:\\Docker\\docker.exe\n"
        "- CODE = C:\\VSCode\\bin\\code.cmd\n"
        "- WINGET = C:\\Windows\\winget.exe\n"
        "- 7Z = C:\\Program Files\\7-Zip\\7z.exe\n"
        "- MAKENSIS = C:\\Program Files (x86)\\NSIS\\makensis.exe\n"
        "- ISCC = C:\\Inno Setup\\ISCC.exe\n"
        "- CLANG = C:\\LLVM\\bin\\clang.exe\n"
        "- PNPM = C:\\Node\\pnpm.cmd";
    if (toolchain_summary != expected_toolchain_summary)
        throw std::runtime_error("toolchain memory format/order test failed");

    // A version that could not be read must not look like a tool that has no
    // version, and it must not make an installed tool disappear either.
    Json unknown_version = Json::object();
    unknown_version["tools"]["git"] = "C:\\Git\\git.exe";
    unknown_version["version_unknown"] = Json::array();
    unknown_version["version_unknown"].as_array().emplace_back("git");
    if (summarize_payload("get_tools", unknown_version, {})
            .find("GIT = C:\\Git\\git.exe (版本未知)") == std::string::npos)
        throw std::runtime_error("unknown version marker test failed");
    Json alias_unknown = Json::object();
    alias_unknown["tools"]["node"] =
        "C:\\Users\\Test\\AppData\\Local\\Microsoft\\WindowsApps\\node.exe";
    alias_unknown["version_unknown"] = Json::array();
    alias_unknown["version_unknown"].as_array().emplace_back("node");
    if (summarize_payload("get_tools", alias_unknown, {}).find("NODE =") ==
        std::string::npos)
        throw std::runtime_error("alias with an unknown version was dropped");

    // A requested tool the catalog does not know must be answered rather than
    // omitted: silence would be read as "not present".
    if (locate_tool("definitely-not-a-real-tool-xyz").get("path").is_string())
        throw std::runtime_error("locate_tool produced a path for a fake name");
    Json unresolved_sample = Json::object();
    unresolved_sample["tools"] = Json::object();
    unresolved_sample["unresolved_tools"] = Json::array();
    unresolved_sample["unresolved_tools"].as_array().emplace_back("gh");
    if (summarize_payload("get_tools", unresolved_sample, parse_filter("gh"))
            .find("GH = 未在 PATH 中找到") == std::string::npos)
        throw std::runtime_error("an unresolved requested tool was omitted");

    // A filter that selected a known tool which is not present is a different
    // answer from a filter that matched nothing at all.
    Json absent_sample = Json::object();
    absent_sample["tools"] = Json::object();
    if (summarize_payload("get_tools", absent_sample, parse_filter("cmake"))
            .find("未检测到：cmake") == std::string::npos)
        throw std::runtime_error("an absent known tool was called no match");
    if (summarize_payload("get_tools", absent_sample,
                          parse_filter("no such phrase"))
            .find("没有匹配的工具") == std::string::npos)
        throw std::runtime_error("a filter matching nothing did not say so");

    // An app list must keep the version distinguishable from the name, and a
    // truncated list must state how many matched, not how many are installed.
    Json apps_sample = Json::object();
    apps_sample["apps"] = Json::array();
    for (int index = 0; index < 60; ++index) {
        Json app = Json::object();
        app["name"] = std::string("Sample App ") + std::to_string(index);
        app["version"] = std::string("1.0.") + std::to_string(index);
        apps_sample["apps"].as_array().push_back(std::move(app));
    }
    const std::string apps_text =
        summarize_payload("get_apps", apps_sample, parse_filter("sample"));
    if (apps_text.find("- Sample App 0 (1.0.0)") == std::string::npos)
        throw std::runtime_error("an app name and version are not distinguished");
    if (apps_text.find("匹配 60 项，仅显示前 50 条") == std::string::npos)
        throw std::runtime_error("a truncated app list did not state how many matched");

    const std::string filtered_tools = summarize_payload(
        "get_tools", sample_toolchain, parse_filter("cmake, clang"));
    if (filtered_tools.find("CLANG") == std::string::npos ||
        filtered_tools.find("GIT") != std::string::npos)
        throw std::runtime_error("tool name filter test failed");

    Json path_noise = Json::object();
    path_noise["tools"]["node"] = "C:\\Program Files\\nodejs\\node.exe";
    path_noise["tools"]["pnpm"] = "C:\\Node\\pnpm.cmd";
    path_noise["not_on_path"] = Json::array();
    const std::string node_only =
        summarize_payload("get_tools", path_noise, parse_filter("node"));
    if (node_only.find("NODE") == std::string::npos ||
        node_only.find("PNPM") != std::string::npos)
        throw std::runtime_error("tool filter matched a path instead of a name");

    // A phrase must match as a whole, so a shared word cannot pull in noise.
    if (parse_filter("visual studio").size() != 1 ||
        !matches_filter(parse_filter("visual studio"), "Visual Studio 2026") ||
        matches_filter(parse_filter("visual studio"), "Supernova Games Studios") ||
        parse_filter("cmake, ninja").size() != 2)
        throw std::runtime_error("filter phrase semantics test failed");

    Json sample_apps = Json::object();
    sample_apps["apps"] = Json::array();
    Json first_app = Json::object();
    first_app["name"] = "Python 3.14.3";
    first_app["version"] = "3.14.3";
    first_app["install_location"] = "C:\\Python314";
    sample_apps["apps"].as_array().push_back(first_app);
    Json second_app = Json::object();
    second_app["name"] = "CMake";
    sample_apps["apps"].as_array().push_back(second_app);
    const std::string apps_default =
        summarize_payload("get_apps", sample_apps, {});
    if (apps_default.find("2 项") == std::string::npos ||
        apps_default.find("CMake") != std::string::npos)
        throw std::runtime_error("apps default summary test failed");
    const std::string apps_filtered = summarize_payload(
        "get_apps", sample_apps, parse_filter("python"));
    if (apps_filtered.find("Python 3.14.3") == std::string::npos ||
        apps_filtered.find("CMake") != std::string::npos)
        throw std::runtime_error("apps filter test failed");

    Json sample_network = Json::object();
    sample_network["endpoints"]["github_api"]["ok"] = true;
    sample_network["endpoints"]["github_api"]["status"] = 200;
    sample_network["endpoints"]["huggingface"]["ok"] = false;
    sample_network["endpoints"]["huggingface"]["reason"] = "timeout";
    const std::string network_summary =
        summarize_payload("get_network", sample_network, {});
    if (network_summary.find("timeout") == std::string::npos ||
        network_summary.find("可达 1/2") == std::string::npos)
        throw std::runtime_error("network summary test failed");

    std::cout << "JSON parser: OK\n";
    std::cout << "CPUID probe: " << hardware.get("brand").as_string() << "\n";
    std::cout << "Local Windows probe: OK\n";
    std::cout << "Shell probe: " << shell_kind << " " << shell_version << "\n";
    std::cout << "Cache write/read: OK\n";
    std::cout << "PATH directory filtering and system cache: OK\n";
    std::cout << "MCP initialize: OK\n";
    std::cout << "MCP tools/list (4 tools): OK\n";
    std::cout << "Concise and detailed tool results: OK\n";
    std::cout << "Measured shell capabilities: OK\n";
    std::cout << "Toolchain format, order, and name filter: OK\n";
    std::cout << "Installed application inventory and filter: OK\n";
    std::cout << "Network summary and failure reason: OK\n";
    std::cout << "Protocol negotiation: OK\n";
    std::cout << "SELFTEST: PASS\n";
    return 0;
}

}  // namespace
}  // namespace machine_env

int wmain(int argc, wchar_t** argv) {
    using namespace machine_env;
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);

    try {
        if (argc > 1 && std::wstring(argv[1]) == L"--version") {
            std::cout << "machine-env-cpp " << server_version() << "\n";
            return 0;
        }
        if (argc > 1 && std::wstring(argv[1]) == L"--selftest")
            return selftest();

        const std::string fingerprint = source_fingerprint();
        std::cerr << "machine-env-cpp MCP server ready (fingerprint "
                  << (fingerprint.empty() ? "unverified" : fingerprint)
                  << ")\n";
        std::string line;
        bool oversized = false;
        while (read_message(std::cin, line, oversized)) {
            if (oversized) {
                std::cerr << "machine-env-cpp: rejected oversized JSON-RPC message\n";
                // Answer rather than stay silent, so the client is not left
                // waiting for a response that never comes.
                std::cout << dump_json(rpc_error(Json(), -32600,
                                                 "message exceeds 8 MiB"))
                          << '\n' << std::flush;
                continue;
            }
            // A client that emits a BOM would otherwise fail every handshake.
            if (line.size() >= 3 &&
                static_cast<unsigned char>(line[0]) == 0xef &&
                static_cast<unsigned char>(line[1]) == 0xbb &&
                static_cast<unsigned char>(line[2]) == 0xbf)
                line.erase(0, 3);
            if (line.empty()) continue;
            try {
                const Json request = parse_json(line);
                bool send_response = false;
                Json response;
                try {
                    response = dispatch(request, send_response);
                } catch (const std::exception& error) {
                    // A probe that failed is an internal error for this request,
                    // not a parse error, and must echo the request id.
                    response = rpc_error(request.get("id"), -32603, error.what());
                    send_response = true;
                }
                if (send_response)
                    std::cout << dump_json(response) << '\n' << std::flush;
            } catch (const std::exception& error) {
                Json response = Json::object();
                response["jsonrpc"] = "2.0";
                response["id"] = nullptr;
                Json detail = Json::object();
                detail["code"] = -32700;
                detail["message"] = error.what();
                response["error"] = detail;
                std::cout << dump_json(response) << '\n' << std::flush;
            }
        }
    } catch (const std::exception& error) {
        std::cerr << "machine-env-cpp fatal: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
