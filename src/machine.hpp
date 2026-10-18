#pragma once

#include "json.hpp"

#include <cstdint>
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
// The coalescing window a refresh is subject to. Exported so the argument
// description can be written from the same number the behaviour uses: a
// description that states a window in words is the one place a constant change
// silently becomes a lie.
int refresh_min_interval_ms();
Json probe_hardware();
// Reading a version means starting the tool, which costs tens to hundreds of
// milliseconds each and can spawn ~20 processes for the whole catalog. Versions
// are therefore opt-in: the default probe answers where each tool is without
// running any of them. A caller that asks for versions gets them from a cache
// of their own, so the fast path never pays for them and they never go stale in
// a payload built without them.
Json probe_toolchain(bool include_versions = false);
Json probe_apps();
Json probe_system();
// Wall-clock budget for a whole network probe. A host blackholed at the DNS
// layer can stall the resolver past every per-phase WinHTTP timeout, so a
// per-phase cap alone cannot bound the call; this is the deadline for the call
// itself. Kept here so the tool schema default, the argument bounds, and the
// cached probe cannot disagree about it.
constexpr int kNetworkBudgetMs = 2500;
constexpr int kNetworkBudgetMinMs = 200;
constexpr int kNetworkBudgetMaxMs = 10000;
// offline disables every outbound request; skip lists endpoint keys (github_api,
// github_raw, huggingface, pypi) to leave unprobed and report as skipped. Both
// are the caller-facing gate for restricted or privacy-sensitive environments.
// budget_ms bounds the call: endpoints still unresolved at the deadline are
// reported as over budget rather than waited out. A budget of 0 or less waits
// for every endpoint instead.
Json probe_network(bool offline, const std::vector<std::string>& skip,
                   int budget_ms = kNetworkBudgetMs);
// network_budget_ms bounds only a probe that actually runs: a cached answer is
// by construction a complete one, since a probe that ran out of budget is never
// stored, so a caller-supplied budget never invalidates it.
Json cached_probe(const std::string& kind, bool refresh,
                  int network_budget_ms = kNetworkBudgetMs);
// Counted where a probe actually starts, not where a request arrives: a caller
// that joins a running probe, reads a cache entry, or is answered by the
// coalescing window starts no probe. `total` counts probes since start, `peak`
// is the largest number that were ever running at the same time. Read only by
// the diagnostics line; no behaviour depends on either number.
std::uint64_t probe_attempts_started_total();
std::uint64_t probe_inflight_peak();

}  // namespace machine_env
