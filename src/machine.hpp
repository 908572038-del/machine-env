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
Json probe_hardware();
Json probe_toolchain();
Json probe_apps();
Json probe_system();
Json probe_network();
Json cached_probe(const std::string& kind, bool refresh);

}  // namespace machine_env
