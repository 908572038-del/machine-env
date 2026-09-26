#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>

#include "machine.hpp"

#include <algorithm>
#include <array>
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

std::string summarize_toolchain(const Json& value) {
    std::ostringstream output;
    output << "## 机器: " << string_field(value, "computer_name") << " ["
           << string_field(value, "machine_guid") << "]";
    const Json& tools = value.get("tools");
    const Json& not_on_path = value.get("not_on_path");
    static const std::array<std::pair<const char*, const char*>, 12> order{{
        {"python", "PYTHON"}, {"pip", "PIP"}, {"uv", "UV"}, {"git", "GIT"},
        {"node", "NODE"}, {"npm", "NPM"}, {"cargo", "CARGO"}, {"go", "GO"},
        {"java", "JAVA"}, {"cmake", "CMAKE"}, {"ninja", "NINJA"},
        {"cl", "CL"}}};

    const auto is_off_path = [&not_on_path](const std::string& name) {
        if (!not_on_path.is_array()) return false;
        for (const auto& item : not_on_path.as_array()) {
            if (item.is_string() && item.as_string() == name) return true;
        }
        return false;
    };

    if (tools.is_object()) {
        for (const auto& tool : order) {
            const std::string name = tool.first;
            const std::string path = string_field(tools, name);
            if (path.empty() || is_windows_app_alias(path)) continue;
            output << "\n- " << tool.second << " = " << path;
            if (is_off_path(name)) output << " (不在PATH)";
        }
    }
    return output.str();
}

std::string summarize_payload(const std::string& name, const Json& value) {
    if (!value.is_object()) return dump_json(value);
    if (value.contains("error")) return dump_json(value);

    if (name == "get_hardware" || name == "hardware") {
        std::ostringstream output;
        output << "系统配置";
        const std::string brand = string_field(value, "brand");
        if (!brand.empty()) output << "\nCPU：" << brand;
        const Json& memory = value.get("memory");
        if (memory.is_object()) {
            const auto total = memory_gb(memory, "total_mem_mb");
            if (!total.empty()) output << "\n内存：" << total;
            const Json& cpus = memory.get("logical_cpu");
            if (cpus.is_number())
                output << "\n逻辑处理器：" << cpus.as_integer();
        }
        const Json& width = value.get("vector_width_bits");
        if (width.is_number())
            output << "\n可用向量宽度：" << width.as_integer() << " 位";
        return output.str();
    }
    if (name == "get_toolchain" || name == "toolchain")
        return summarize_toolchain(value);
    if (name == "get_environment" || name == "environment") {
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
                output << "\nPowerShell：" << clean_version;
        }
        const Json& network = value.get("network");
        if (network.is_object()) {
            int reachable = 0;
            for (const auto& endpoint : network.as_object()) {
                if (endpoint.second.get("ok").is_bool() &&
                    endpoint.second.get("ok").as_bool())
                    ++reachable;
            }
            output << "\n网络连通性：" << reachable << "/"
                   << network.as_object().size() << " 个目标可达";
        }
        return output.str();
    }
    if (name == "get_cache_status") {
        std::ostringstream output;
        output << "缓存状态";
        const Json& categories = value.get("categories");
        if (categories.is_object()) {
            static const std::map<std::string, std::string> labels{
                {"environment", "环境"}, {"hardware", "硬件"},
                {"toolchain", "开发工具"}};
            for (const auto& category : categories.as_object()) {
                const auto label = labels.find(category.first);
                output << "\n"
                       << (label == labels.end() ? category.first : label->second)
                       << "：" << string_field(category.second, "reason");
            }
        }
        return output.str();
    }
    if (name == "refresh_env") {
        std::ostringstream output;
        output << "环境刷新结果";
        for (const auto& category : {
                 std::pair<const char*, const char*>{"hardware", "硬件"},
                 {"toolchain", "开发工具"},
                 {"environment", "系统环境"}}) {
            const Json& item = value.get(category.first);
            if (item.is_object())
                output << "\n\n" << category.second << "\n"
                       << summarize_payload(category.first, item);
        }
        return output.str();
    }
    return dump_json(value);
}

Json tool_result(const std::string& name, Json value, bool detail) {
    Json result = Json::object();
    if (detail) {
        result["content"] = text_content(dump_json(value));
        result["structuredContent"] = value;
    } else {
        const std::string summary = summarize_payload(name, value);
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

    Json hardware = object_schema();
    hardware["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    hardware["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    list.as_array().push_back(tool_definition(
        "get_hardware",
        "CPU identity and OS-usable ISA capabilities from CPUID/XCR0, plus memory.",
        hardware));

    Json toolchain = object_schema();
    toolchain["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    toolchain["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    list.as_array().push_back(tool_definition(
        "get_toolchain",
        "Locate installed compilers, interpreters, and developer tools.",
        toolchain));

    Json environment = object_schema();
    environment["properties"]["refresh"] =
        boolean_schema("Bypass the cache and re-probe.");
    environment["properties"]["detail"] =
        boolean_schema("Return the full JSON result instead of a concise summary.");
    environment["properties"]["include_network"] = boolean_schema(
        "Check GitHub, Hugging Face, and PyPI reachability. False skips network.");
    list.as_array().push_back(tool_definition(
        "get_environment",
        "Report Windows, shell, and path facts; optionally check network reachability.",
        environment));

    Json refresh = object_schema();
    Json scope = string_schema("Categories to re-probe.");
    Json scope_enum = Json::array();
    for (const char* name : {"all", "hardware", "toolchain", "environment"})
        scope_enum.as_array().emplace_back(name);
    scope["enum"] = scope_enum;
    refresh["properties"]["scope"] = scope;
    refresh["properties"]["detail"] =
        boolean_schema("Return full JSON results instead of concise summaries.");
    list.as_array().push_back(tool_definition(
        "refresh_env", "Force a fresh probe for one or all categories.", refresh));

    Json status = object_schema();
    status["properties"]["detail"] =
        boolean_schema("Return the full cache metadata.");
    list.as_array().push_back(tool_definition(
        "get_cache_status", "Report per-category cache freshness.", status));
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

Json dispatch(const Json& request, bool& has_response) {
    has_response = true;
    if (!request.is_object()) return rpc_error(nullptr, -32600, "invalid request");
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
        result["serverInfo"]["version"] = "0.2.0";
        result["instructions"] =
            "Observed Windows machine facts: CPU ISA, toolchain, OS, shell, paths, "
            "and optional network state. Prefer these tools over guesses.";
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

        Json payload;
        std::string validation_error;
        bool detail = false;
        bool refresh = false;
        if (name == "get_hardware" || name == "get_toolchain" ||
            name == "get_environment") {
            if (!optional_boolean(arguments, "detail", false, detail,
                                  validation_error))
                return rpc_error(id, -32602, validation_error);
            if (!optional_boolean(arguments, "refresh", false, refresh,
                                  validation_error))
                return rpc_error(id, -32602, validation_error);
            if (name == "get_environment") {
                bool include_network = true;
                if (!optional_boolean(arguments, "include_network", true,
                                      include_network, validation_error))
                    return rpc_error(id, -32602, validation_error);
                payload = cached_probe("environment", refresh, include_network);
            } else {
                payload = cached_probe(name == "get_hardware" ? "hardware"
                                                                : "toolchain",
                                       refresh, true);
            }
        } else if (name == "refresh_env") {
            if (!optional_boolean(arguments, "detail", false, detail,
                                  validation_error))
                return rpc_error(id, -32602, validation_error);
            std::string scope = "all";
            if (arguments.contains("scope")) {
                const Json& value = arguments.get("scope");
                if (!value.is_string())
                    return rpc_error(id, -32602, "argument 'scope' must be a string");
                scope = value.as_string();
            }
            payload = refresh_environment(scope);
        } else if (name == "get_cache_status") {
            if (!optional_boolean(arguments, "detail", false, detail,
                                  validation_error))
                return rpc_error(id, -32602, validation_error);
            payload = probe_cache_status();
        } else {
            return rpc_error(id, -32602, "unknown tool: " + name);
        }

        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = tool_result(name, std::move(payload), detail);
        return response;
    }
    if (method == "resources/list") {
        Json response = Json::object();
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"]["resources"] = Json::array();
        return response;
    }
    return rpc_error(id, -32601, "method not found: " + method);
}

int selftest() {
    const auto parsed = parse_json(
        R"({"text":"中文 \ud83d\ude80","array":[true,7,null],"number":-2.5e2})");
    if (parsed.at("text").as_string() != "中文 🚀" ||
        parsed.at("array").as_array().size() != 3 ||
        parsed.at("number").as_integer() != -250)
        throw std::runtime_error("JSON parser round-trip test failed");

    const Json hardware = probe_hardware();
    if (!hardware.get("brand").is_string() ||
        hardware.get("brand").as_string().empty() ||
        !hardware.get("isa").is_object())
        throw std::runtime_error("hardware probe returned incomplete data");

    const Json local_environment = probe_environment(false);
    if (!local_environment.get("os").is_object() ||
        !local_environment.get("paths").is_object() ||
        local_environment.contains("network"))
        throw std::runtime_error("local environment probe contract failed");

    const Json refreshed_hardware = cached_probe("hardware", true, true);
    if (refreshed_hardware.contains("error"))
        throw std::runtime_error("hardware cache write test failed");
    const Json cached_hardware = cached_probe("hardware", false, true);
    if (!cached_hardware.get("_cache").get("hit").as_bool() ||
        cached_hardware.get("brand").as_string() !=
            refreshed_hardware.get("brand").as_string())
        throw std::runtime_error("hardware cache round-trip test failed");

    const Json invalid_scope = refresh_environment("invalid");
    if (!invalid_scope.contains("error"))
        throw std::runtime_error("refresh scope validation test failed");
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
        listing.get("result").get("tools").as_array().size() != 5)
        throw std::runtime_error("MCP tools/list dispatch test failed");
    const Json summary = tool_result("get_hardware", hardware, false);
    if (summary.contains("structuredContent") ||
        summary.get("content").as_array().size() != 1 ||
        summary.get("content").as_array()[0].get("text").as_string().find("CPU：") ==
            std::string::npos ||
        dump_json(summary).size() >= dump_json(hardware).size())
        throw std::runtime_error("concise hardware summary test failed");
    const Json detailed = tool_result("get_hardware", hardware, true);
    if (!detailed.get("structuredContent").get("isa").is_object())
        throw std::runtime_error("detailed tool result test failed");
    Json sample_toolchain = Json::object();
    sample_toolchain["computer_name"] = "TEST-PC";
    sample_toolchain["machine_guid"] = "test-guid";
    sample_toolchain["tools"]["cl"] = "C:\\VS\\cl.exe";
    sample_toolchain["tools"]["git"] = "C:\\Git\\git.exe";
    sample_toolchain["tools"]["python"] =
        "C:\\Python\\python.exe";
    sample_toolchain["tools"]["node"] =
        "C:\\Users\\Test\\AppData\\Local\\Microsoft\\WindowsApps\\node.exe";
    sample_toolchain["not_on_path"] = Json::array();
    sample_toolchain["not_on_path"].as_array().emplace_back("cl");
    const std::string toolchain_summary =
        summarize_payload("get_toolchain", sample_toolchain);
    const std::string expected_toolchain_summary =
        "## 机器: TEST-PC [test-guid]\n"
        "- PYTHON = C:\\Python\\python.exe\n"
        "- GIT = C:\\Git\\git.exe\n"
        "- CL = C:\\VS\\cl.exe (不在PATH)";
    if (toolchain_summary != expected_toolchain_summary)
        throw std::runtime_error("toolchain memory format/order test failed");

    std::cout << "JSON parser: OK\n";
    std::cout << "CPUID probe: " << hardware.get("brand").as_string() << "\n";
    std::cout << "Local Windows probe: OK\n";
    std::cout << "Cache write/read: OK\n";
    std::cout << "MCP initialize: OK\n";
    std::cout << "MCP tools/list: OK\n";
    std::cout << "Concise and detailed tool results: OK\n";
    std::cout << "Toolchain memory format and order: OK\n";
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
            std::cout << "machine-env-cpp 0.2.0\n";
            return 0;
        }
        if (argc > 1 && std::wstring(argv[1]) == L"--selftest")
            return selftest();

        std::cerr << "machine-env-cpp MCP server ready (fingerprint "
                  << source_fingerprint() << ")\n";
        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.empty()) continue;
            if (line.size() > 8 * 1024 * 1024) {
                std::cerr << "machine-env-cpp: rejected oversized JSON-RPC message\n";
                continue;
            }
            try {
                const Json request = parse_json(line);
                bool send_response = false;
                const Json response = dispatch(request, send_response);
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
