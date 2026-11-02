# Cache, concurrency and latency

[Back to the README](../README.md)

The tool inventory is cached for an hour: an inventory that outlives the install
it was taken before is the failure mode of a long TTL, and locating tools without
running them costs well under a second, so the shorter window is affordable.
System facts are cached for 10 minutes. Cache files live under the current
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
4430 ms at 521 threads to 1690 ms at 136. (That tool was removed in 0.6.0, but the
mechanism it measured is the one every probe still uses.) The patience a joiner
gives a probe is its own budget, never the holder's speed, and a joiner that runs
out of patience falls back to an older entry before it falls back to probing.

The default call shape joins too, and there it is a saving in work rather than in
time: 100 concurrent probes of one kind used to be 100 real probes
(`attempts=100 inflight_peak=100`) and are now one. Wall clock barely moves —
2510 ms before, 2514 ms after — because that path is bounded by the probe's own
budget, not by how many probes run. Anyone citing a latency number for joining
should say which of the two they mean.

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
lookup from that snapshot (registry opens for one probe: 113 before, 3 now). The
snapshot lasts exactly one probe: nothing is cached across requests, so `refresh`
still sees a PATH edited a moment ago.

Requests are read in 64 KB blocks instead of one byte at a time, which is what
makes receiving a large message cheap (rejecting a 9 MB message went from ~330ms
to ~2ms). The block read asks for whatever is already on the pipe and returns as
soon as one byte arrives: `istream::read` returns only when the buffer is full or
the input has ended, so against a client that keeps stdin open it would sit in
the call forever and the handshake would time out while stderr still said "server
ready". The 8 MiB limit still applies while reading: bytes past it are consumed
and counted but never stored, so an oversized message is refused without being
held in memory, and the next message on the stream is still read correctly.


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
