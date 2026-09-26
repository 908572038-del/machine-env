#pragma once

#include "json.hpp"

#include <string>

namespace machine_env {

std::string machine_guid();
std::string source_fingerprint();
Json probe_hardware();
Json probe_toolchain();
Json probe_environment(bool include_network);
Json probe_cache_status();
Json refresh_environment(const std::string& scope);
Json cached_probe(const std::string& kind, bool refresh, bool include_network);

}  // namespace machine_env
