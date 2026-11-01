# Cache, concurrency and latency

[Back to the README](../README.md)

The tool inventories are cached for an hour and the application inventory for 24
hours: an inventory that outlives the install it was taken before is the failure
mode of a long TTL, and locating tools without running them costs well under a
second, so the shorter window is affordable. System facts and network state are
cached for 10 minutes. Cache files live under the current
user's `%LOCALAPPDATA%\machine-env\cache`; writes are atomic and protected by a
named Windows mutex. Entries are invalidated when the server executable
changes — an entry records the binary's fingerprint, so an upgrade re-probes
instead of answering from a snapshot taken by a different build — or when their
TTL expires. A cached answer is therefore never one the previous build measured
under different rules. Cache failures do not prevent probes from
returning results. PATH results contain existing directories only; file paths
and nonexistent entries are omitted and counted.

The cache mutex is held for at most two seconds, and only for a **write**: reads
take no lock at all, because a write publishes by renaming a temporary file over
the destination, so a reader sees either the previous complete entry or the new
one and never a half-written file; the checksum then rejects anything that was
truncated or mixed by another writer. A write that cannot take the lock is
skipped and reported as `not_stored_because: "cache busy"` rather than blocking,
because freezing every instance behind one stuck writer is worse than
re-probing.

`refresh` is coalesced rather than taken literally. A refresh that arrives within
five seconds of a completed probe of the same kind is answered from that entry and
says so (`_cache.question: "refresh coalesced"`), so a client cannot make the
server re-probe by asking twice. Across processes, one probe per kind is elected
through a named lock, so five editors opening at once cost one probe instead of
five. Waiting for that lock is bounded: a stalled holder costs a duplicate probe,
never the answer. A partial result (one that ran out of its budget) is never
served as a refresh and never stored.

Inside one process, a call that needs a probe of a kind already being probed joins
that probe instead of starting a second one, and reports what happened rather than
passing the answer off as its own work. `_cache` answers two questions, one field
each, and a client never has to reconcile three flags that could disagree:

- `answer` — where this answer came from: `fresh` (a probe this call waited for),
  `cache` (an entry, still inside its TTL), `shared` (a probe another caller was
  already running) or `stale` (an older entry, kept because the new probe did not
  answer). `hit` stays as a plain "came out of an entry" boolean beside it.
- `question` — why that rather than a new probe: `fresh`, `cache`, `refresh
  requested`, `refresh coalesced`, `attempt shared`, `probe still running` or
  `probe failed, stale kept`.
- `age_seconds` — present whenever the answer came from an entry, including a
  `stale` one.
- `stored` / `not_stored_because` — whether **this** call persisted a fresh
  measurement, and why not. Storing says nothing about where the data came from.

`_cache` describes the call, so it is stripped before a payload is written: an
entry that carried one call's metadata would later be served as a hit with
another call's `answer` in it.

| what the caller got | `_cache.answer` | `_cache.question` |
|---|---|---|
| the answer of a probe it ran itself, stored | `fresh` | `refresh requested`, or the reason the entry was not read |
| the answer of a probe it ran itself, not stored (budget ran out, or it failed) | `fresh` | same, with `stored: false` and `not_stored_because` |
| a fresh entry | `cache` | `cache`, with `hit: true` |
| an entry from inside the coalescing window | `cache` | `refresh coalesced` |
| the answer of a probe already running for someone else | `shared` | `attempt shared` |
| an older entry, because the probe it waited on is still running past its patience | `stale` | `probe still running` |
| an older entry, because the probe it waited on failed | `stale` | `probe failed, stale kept` |

A real probe is exactly `answer: "fresh"` with `stored: true`.

Joining is why a burst of identical refreshes costs one probe rather than one per
caller: measured on this machine, 100 concurrent `get_network` refreshes went from
4430 ms at 521 threads to 1690 ms at 136. The patience a joiner gives a probe is
its own budget, never the holder's speed, and a joiner that runs out of patience
falls back to an older entry before it falls back to probing.

The default call shape joins too, and there it is a saving in work rather than in
time: 100 concurrent plain `get_network` calls used to be 100 network probes
(`attempts=100 inflight_peak=100`) and are now one. Wall clock barely moves —
2510 ms before, 2514 ms after — because that path is bounded by the probe's own
budget, not by how many probes run. Anyone citing a latency number for joining
should say which of the two they mean.

A caller with a different `timeout_ms` does not join: the table is keyed by the
question, not by the kind, so two callers asking for different network budgets
never receive each other's partial answer.

A ceiling on simultaneous probes of one kind exists as a backstop
(`MACHINE_ENV_PROBE_CONCURRENCY`, 16 by default, `0` disables it). It is a bound
on resources, not a source of speed, and it is **not** what makes the burst above
cheap — joining is. Do not credit it with a latency number.

Probes that start child processes kill the whole tree on timeout through a job
object, so a grandchild cannot outlive the timeout and hold the output pipe
open. `get_system` reports `process_tree_kill` as `job`, or `fallback` when the
job object was unavailable and only the direct child could be terminated.

Registry work is done once per question rather than once per lookup. A toolchain
probe reads the PATH value from the registry a single time and answers every
lookup from that snapshot (registry opens for one probe: 113 before, 3 now),
while an application inventory opens each application's key once instead of once
per field (667 before, 336 now — one per entry), which cut `get_apps` cold time by
about a fifth. The snapshot lasts exactly one probe: nothing is cached across
requests, so `refresh` still sees a PATH edited a moment ago.

Requests are read in 64 KB blocks instead of one byte at a time, which is what
makes receiving a large message cheap (rejecting a 9 MB message went from ~330ms
to ~2ms). The block read asks for whatever is already on the pipe and returns as
soon as one byte arrives: `istream::read` returns only when the buffer is full or
the input has ended, so against a client that keeps stdin open it would sit in
the call forever and the handshake would time out while stderr still said "server
ready". The 8 MiB limit still applies while reading: bytes past it are consumed
and counted but never stored, so an oversized message is refused without being
held in memory, and the next message on the stream is still read correctly.

`get_network` uses HTTPS HEAD requests to GitHub, Hugging Face, and PyPI, and
reports a reason such as `dns`, `connect`, `timeout`, or `tls` when a target is
unreachable. The four hosts are checked concurrently, so the call costs the
slowest endpoint rather than their sum. It is the only tool that opens a socket,
so a local system probe can never cause an unexpected outbound request.

A host blackholed at the resolver can stall past every per-phase WinHTTP
timeout, which no timeout setting can bound. The call is therefore capped by a
wall-clock budget: `timeout_ms` (200-10000, default 2500) is the deadline for the
whole check, and an endpoint still unanswered at the deadline is reported as
`timed_out` with `reason: "budget"` rather than being waited out. That is a third
answer, distinct from unreachable: the host was asked and did not answer in time.
`budget_ms` and `budget_exhausted` appear on the result so a partial answer is
never mistaken for a complete one. A probe that ran out of budget is returned but
never cached, so a timeout cannot be served as a fact for the next ten minutes.
Pass a larger `timeout_ms` for a slow link; a cached answer is always a complete
one, so a budgeted caller is still served from the cache. Raising the budget does
not, however, turn an unreachable host into a reachable one — each endpoint carries
its own WinHTTP timeouts, so past roughly 4.8 s the answer becomes `timed_out`
instead of `budget_exhausted` without changing whether the host answers at all.

`offline: true` skips every endpoint and reports each one as skipped without
opening a socket; `skip_endpoints` names individual hosts (`github_api`,
`github_raw`, `huggingface`, `pypi`) to leave unprobed. Both bypass the cache
because they change what the result means, and both keep "deliberately not
checked" distinct from "checked and unreachable".
## Why the shell facts come from the registry

Starting Windows PowerShell costs about 1.7 seconds on a low-power machine before
it runs a single statement. The system probe used to pay that twice over: one
start to read the version, edition and host, and the same start asked to parse
`&&` and a here-string to decide whether they are supported. A cold `get_system`
took 2.6 seconds, and essentially all of it was process startup.

The version, edition and host are recorded by the installer at
`HKLM\SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine`, and the execution policy
in the same registry tree. Reading them costs microseconds. The capability fields
follow from those values by rules with no exceptions -- `&&` and `||` arrived in
PowerShell 7.0, a here-string predates every supported version, and only the
Desktop edition pipes through the console code page -- so the answer is the same
one a parse would give, marked `source: derived` rather than `measured`.

Measured on a Celeron N5095A: **2.6s to 46ms**, a 51x reduction, with the returned
values checked field by field against the previous build.

`measure_syntax: true` buys the measurement back for a caller who does not trust
the version rule. It starts the shell once, parses each construct, runs the
non-ASCII round-trip, and reports `source: measured` with the shell's own version
string. That answer is cached under `system_measured` rather than `system`, so a
derived result is never served to a caller who asked for a measurement.

One consequence worth knowing: the engine key records the version at installation
and Windows updates the files without rewriting it, so a derived probe can report
a slightly older build than the shell prints (`5.1.26100.8875` against
`5.1.26100.9711` on the machine this was measured on). Only the major version is
compared, and that is what every rule above depends on.
