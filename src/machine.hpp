#pragma once

#include "json.hpp"

#include <string>
#include <vector>

namespace machine_env {

std::string machine_guid();
std::string machine_uuid();
std::string source_fingerprint();
// Ordered developer-tool names. Declared once so the probe and the concise
// summary cannot disagree about which tools exist or how they are ordered.
const std::vector<std::string>& tool_catalog_names();
// Resolves a tool the catalog does not probe: where it is on PATH, and its
// version when reading it is safe. An empty path means it was not found there,
// which is a different answer from not having looked.
Json locate_tool(const std::string& name);
// The version reported by initialize and by --version, so the two cannot
// disagree about which build is running.
const char* server_version();
Json probe_hardware();
Json probe_toolchain();
Json probe_apps();
Json probe_system();
Json probe_network();
Json cached_probe(const std::string& kind, bool refresh);

}  // namespace machine_env
