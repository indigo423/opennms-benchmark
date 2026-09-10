---
title: 'technical research: Collectd pool sizing under 50-100 ms agent latency'
type: 'technical'
topic: 'Collectd pool sizing under 50-100 ms agent latency'
decision: 'How far the Collectd pool can be raised on this deployment under agent latency, and which constraint appears first'
source: 'native run, web search'
status: complete
preset: 'standard'
validation: 'normal'
created: '2026-09-03'
updated: '2026-09-03'
---

# technical research: Collectd pool sizing under 50-100 ms agent latency

**Decision this research serves:** How far the Collectd pool can be raised on this deployment under agent latency, and which constraint appears first

## Executive summary

**Raise the Collectd pool. The strategy you asked me to evaluate is instrumented for a failure this deployment cannot have, and its stop signals would never fire.**

The strategy watches for a CPU-oversubscribed pool: involuntary context switches, run-queue depth, `%sys`. Every source consulted agrees those three are silent for a pool whose threads block on I/O, because a blocked thread is neither runnable nor preemptible [37][40]. Collectd's pool is exactly that: a plain fixed executor whose threads sit in SNMP4J's synchronous `wait()` for the whole round trip [1][43]. Two of the strategy's three thresholds (`%sys > 15 to 20%`, `nvcswch > 5 to 10%`) have no primary source at all [41], and the one that does is stated at 1× cores, not 2× [40]. Worse, reading context switches at process level on a JVM returns only the main thread's counts; that was confirmed on this Core during the run, and it means the strategy's first diagnostic is a measurement artifact unless run per-thread with `pidstat -t`.

What actually bounds a raised pool, in the order the evidence suggests it appears: **nothing on the RPC path** (the Core has no cap and the Minion's bulkhead is observability only, verified on the 36 release line [4][5]); then **kernel limits** that count threads and sockets, systemd `TasksMax` on Core and file descriptors on the Minion, because every SNMP operation opens its own session [31][9]; then **native memory** outside the heap, where a thousand blocked threads commit tens of megabytes of stack but glibc malloc arenas can reach a gigabyte [16][18]; and only then CPU. Throughput should track pool size linearly until one of those binds. Virtual threads are not an option on Horizon 36: it pins SNMP4J 2.8.15, whose synchronous send waits in a `synchronized` block that pins a JDK 21 virtual thread for the whole round trip [42][43][26].

The corrected sweep plan is in this report: start at the current 100, double per rung, watch `Threads` against `TasksMax`, `FDSize` against `NOFILE`, NMT against RSS, and UDP drop counters, and stop at the largest pool where throughput still rises 20% per doubling. **Biggest caveat:** no source gives a measured per-thread committed figure for a blocked thread on Linux x86-64 on JDK 21, so the memory ceiling is a budget to be measured at rung one, not a number this report can supply.

The outage test was cut from this run and is parked for its own session.

---


## 1. The Collectd executor and the Minion RPC path

**What bounds throughput when `threads` is raised: nothing on the Core rejects or queues, one Minion knob throttles softly at 1,000, and below that the bound is sockets.**

Collectd runs collections on a JDK `newFixedThreadPool(threads)` with an unbounded queue; when every thread is busy, ready collections wait rather than being rejected, so saturation shows as interval slippage and a growing pending count, never as an error [1]. The pool size is the only Collectd-side knob, and the whole of the official guidance on it is "increase or decrease this value based on your network and the size of your server", example `threads="50"`; nothing relates it to CPU count, fleet size or agent response time [2][3].

On the Core, the Kafka RPC client tracks in-flight requests in a map with no cap, and reads every RPC response on **a single consumer thread** that hands off to an unbounded handler pool [4]. That single consumer is a structural bottleneck for response throughput, though no measurement of where it saturates was found (confidence: medium, inferred from code structure).

On the Minion, requests are dispatched onto an unbounded cached pool, guarded by a resilience4j bulkhead with defaults `org.opennms.core.ipc.rpc.kafka.max.concurrent.calls = 1000` and `max.wait.time = 100 ms` [5][6]. **The bulkhead is observability only.** Verified verbatim on `release-36.x`: when a permit cannot be acquired, `checkBulkHead()` increments `extraThreadsBeyondThreshold` and the request is dispatched unconditionally; and because `tryAcquirePermission()` is non-blocking, the configured 100 ms `max.wait.time` never applies either [5][6]. Past 1,000 concurrent RPCs per Minion there is **no throttle at all**, only a metric (`activeRpcRequests`, `availableConcurrentCalls`, `maxAllowedConcurrentCalls`) that records the excess [5]. The bulkhead was introduced as NMS-12391 in Horizon 27 [7].

SNMP execution on the Minion is fully asynchronous (`getAsync`, walker callbacks, `CompletableFuture`) with no throttle and no property [8]. Each operation creates its own SNMP4J session and closes it on a reaper pool; the receive buffer is set to `Integer.MAX_VALUE` [9]. The practical Minion-side bound is therefore **sockets, file descriptors and threads, not a configurable pool** (confidence: medium; session-per-socket is inferred). `org.opennms.core.snmp.trackSessions=true` exposes the live session count [9].

Transport knobs that exist: Kafka RPC topic partitions must be at least the number of Minions per location and a multiple of it; `max.buffer.size` 900 KB; `ttl` 20,000 ms; single-topic is the default [10]. Any Kafka client option can be passed through the `org.opennms.core.ipc.rpc.kafka.` prefix [10]. For `SnmpCollector` the RPC TTL is the agent config's `ttl`; a request that expires before the Minion reads it is dropped there, and the Core sees `RequestTimedOutException` [11].

One correction to a metric this campaign has been reading: `taskqueueremainingcapacity` on an unbounded `LinkedBlockingQueue` is a constant `Integer.MAX_VALUE` and carries no information. Pending count and active threads are the signals [1].

**What was looked for and not found:** any documented Core-side concurrency cap; any Minion `rpc.threads` property (the bulkhead pair is undocumented outside source and the 27 release notes); any issue or forum report of the Core starving its RPC response consumer under high Collectd thread counts over Kafka. A targeted search of issues.opennms.org for `max.concurrent.calls` was not run within budget.

## 2. The JVM cost of many blocked threads

**A thousand blocked platform threads cost tens of megabytes of committed stack, not a gigabyte; the real many-thread risks are glibc malloc arenas and G1's own native structures, and neither was measured for this case.**

The default stack is 1 MB reserved per thread on 64-bit Linux [12][13], but since JDK 11 NMT reports stack "committed" by actual page liveness, because the old accounting "overstates memory usage" and could report committed above RSS [14][15]. A thread that mostly blocks touches little of its stack: field NMT output shows ratios of "320 threads × 1 MB = 320 MB reserved, only 10 MB committed" and "reserved=240 MB, committed=25 MB for 238 threads", roughly 30 to 100 KB committed per thread [16]. On JDK 21, ~16,300 parked threads were created regardless of `-Xss`, because the stack is virtual and committed pagewise on use [17] (measured on macOS, not Linux; confidence: medium). Per-thread JVM metadata beyond the stack is on the order of 5 KB [16] (low confidence, from a search excerpt).

Applied arithmetic, not a sourced figure: 1,000 blocked threads reserve about 1 GB of address space and commit on the order of 30 to 100 MB. Lowering `-Xss` shrinks the reservation but barely the commit, and risks `StackOverflowError` on deep decode or logging paths [17][14]. `-XX:VMThreadStackSize` affects only VM-internal threads [13].

The larger documented many-thread cost is **glibc malloc arenas**: a JDK 17 post-mortem budgeted 80 MB for threads and measured "Threads 200 MB, G1GC 1000 MB, glibc arenas 1500 MB"; capping arenas brought the last figure under 200 MB [18]. `MALLOC_ARENA_MAX` is the single largest lever found for many-thread native bloat [18]. Transparent huge pages once inflated thread-stack RSS; that is fixed in JDK 21 b26, so 21.0.12 has the fix, and the remaining THP exposure is heap and malloc, not stacks [19][20].

On GC: G1's root scanning includes thread stacks and is a direct input to pause work [21], and time-to-safepoint can dominate a pause, but that is driven by threads *running* and failing to reach a safepoint, not by threads blocked in I/O [22][23]. **No controlled measurement of G1 pause time against Java thread count was found.** The unverified expectation is that threads blocked in native socket calls are already safepoint-safe and add shallow stacks to root scanning, so 900 more blocked threads should cost little in pause time; per-thread TLAB retention is the likelier cost. That is a hypothesis for `-Xlog:gc*,gc+phases=debug,safepoint` at two pool sizes, not a finding.

On the heap ceiling: the OOM-killer acts on RSS, which is heap plus metaspace, code cache, stacks, direct buffers, GC structures, JIT and glibc; `-Xmx` bounds only the heap [24][16]. The "5 to 15% of Xmx for GC metadata" and "1.5 to 2× Xmx container limit" rules of thumb were found only without measurement behind them and are recorded so they are not mistaken for evidence [25]. The only reliable answer for a given box is `jcmd <pid> VM.native_memory summary scale=MB` against RSS.

**Virtual threads (JDK 21):** a virtual thread is pinned inside `synchronized` or a native call; the scheduler does not compensate; `synchronized` pinning is removed only in JDK 24 [26][27]. JEP 444 states that a blocking operation on a virtual thread, including a socket read, "releases the underlying platform thread"; it does not single out `DatagramSocket`, so the unmount-on-receive reading is the general `java.net` statement applied to UDP [26]. **Virtual threads are not an option on Horizon 36, and the reason is specific.** Horizon 36 pins SNMP4J **2.8.15**, not 3.x [42]. In SNMP4J 2.x the synchronous `Snmp.send()` waits with `synchronized (syncResponse) { while (...) syncResponse.wait(totalTimeout); }` and the listener signals with `notify()` from a `synchronized` method [43]. That is the monitor-based construct JEP 444 names as pinning a virtual thread to its carrier, and the fix for `synchronized` pinning arrives only in JDK 24 [26][27]. A virtual-thread Collectd pool on this stack would pin every thread for the whole round trip and gain nothing. (Confidence: medium; the construct was read from a 2.5.x mirror, and 2.8.15 itself was not fetched, though the CHANGES log corroborates the `wait()` design across 2.x [43].) `MultiThreadedMessageDispatcher`'s `WorkerPool` interface parallelises *inbound* PDU processing, not the collector's wait, so it does not help either [28].

**Looked for and not found:** a measured committed-stack figure for a blocked thread on Linux x86-64 on JDK 17+; any measurement of G1 pause versus thread count; any OpenJDK statement on G1's off-heap footprint for JDK 21; any SNMP4J release note or issue about virtual threads.

## 3. Linux limits and diagnostics for a blocked pool

**The strategy's three stop signals are all silent for an I/O-bound pool by definition, two of its three thresholds have no primary source, and the per-process context-switch reading it relies on is a measurement artifact on a JVM.**

*Limits.* `kernel.threads-max` is system-wide and sized to 1/8 of RAM, typically tens of thousands [29]. The in-kernel `pid_max` default is 32,768, but systemd 243+ ships a sysctl raising it to 4,194,304 on 64-bit, and Ubuntu 24.04 runs systemd 255.4 [29][30] (that Ubuntu keeps the file is unverified). The limit that is both per-unit and small enough to matter is systemd's **`TasksMax`**, which counts threads and defaults to 15% of the smallest of `pid_max`, `threads-max` and the root cgroup's `pids.max`; the manpage's own example is ~4,915 under stock `pid_max` [31]. Read the effective value with `systemctl show -p TasksMax <unit>` rather than assuming it. `DefaultLimitNOFILE` is 1024 soft / 524,288 hard [31]; whether HotSpot raises the soft limit at startup was not verified. `/proc/PID/status` exposes `Threads` and `FDSize` for cheap monitoring [32].

*UDP.* A per-socket overflow drops silently and increments both `RcvbufErrors` and `InErrors` on the `Udp:` line of `/proc/net/snmp`; `truesize` is charged, not payload [33]. Drops from the global `udp_mem` limit were once invisible; a November 2020 patch added `MemErrors`, present in kernel 6.8 [34]. So per-socket overflow reads as `RcvbufErrors`, aggregate-memory overflow as `MemErrors`, both rolled into `InErrors`. `rmem_default`, `rmem_max` and `udp_mem` are the knobs [35][36]; the 6.8 default for `rmem_max` was not verified (212,992 is commonly cited).

*Context switches.* A thread that gives up the processor "to await availability of a resource" makes a **voluntary** switch; an involuntary one is preemption by a higher-priority task or timeslice expiry [37]. A socket `recv` is such a wait; the man page states the general rule, not the socket case, so that reading is this report's gloss. `pidstat -w` reports both per task, and `-t` gives true per-thread rows by reading `/proc/TGID/task/TID/status` [38][39]. The researcher's unverified belief that `/proc/PID/status` for a thread-group leader reports only the leader's own counts, so that `pidstat -w -p PID` without `-t` on a JVM shows a near-idle main thread, **was confirmed empirically on the lab's Core during this run** (recorded in the memlog as a correction, not as sourced evidence): the leader showed 28 voluntary and 2 involuntary switches while the sum over 1,008 tasks was 1.56 billion and 58 million. Any process-level `nvcswch/s` on a JVM without `-t` is meaningless.

*What an I/O-bound pool looks like.* Blocked threads are neither runnable (so `r` stays low) nor preempted (so involuntary switches stay low). The counters that rise with pool size are per-thread `voluntary_ctxt_switches`, one per completed blocking receive and therefore a proxy for I/O completions, `Udp: InDatagrams`, and at overload `RcvbufErrors` or `MemErrors` [37][33][34] (confidence: medium, inferred).

*The heuristics.* Brendan Gregg's USE checklist gives CPU saturation as `vmstat r` greater than the CPU count, **1×, not 2×**, and NIC saturation from `overruns`/`dropped`; it has no row for involuntary switches, `%sys` or `%soft` thresholds [40]. **No kernel document, Gregg page, or Red Hat or Ubuntu tuning guide retrieved this run states `%sys > 15 to 20%` or `nvcswch > 5 to 10% of switches`.** Until sourced, those two are folklore.

**Looked for and not found:** any primary source for the three thresholds; kernel documentation of `/proc/net/softnet_stat` columns; a source stating `RLIMIT_NPROC` counts threads; direct scheduler-code evidence for how a socket block versus a wakeup is classified.

## Cross-dimension insights

Three things only the combination shows.

**The strategy under evaluation is instrumented for the wrong failure.** It watches for a CPU-oversubscribed pool: involuntary switches, run-queue depth, `%sys`. Dimension 3 shows those three signals are silent for an I/O-bound pool *by definition*, since a blocked thread is neither runnable nor preemptible [37][40]; dimension 1 shows the Collectd pool is exactly that, a fixed pool of threads that spend their life in a synchronous SNMP4J wait [1][43]. The strategy's sweep would climb to its "knee" and find none, because the knee it looks for is on a curve this workload does not produce until the pool is large enough that the *Core CPU* becomes busy, which dimension 2 suggests is far beyond the thread counts where other things bind.

**The first real limit is not a thread count at all.** Dimension 1 finds nothing on the path that rejects or queues: the Core has no cap, the Minion's only guard is a metric [4][5], and every SNMP operation opens its own socket [9]. Dimension 3 finds the limits that do exist are systemd `TasksMax` on the Core (threads count as tasks) and file descriptors on the Minion (one per in-flight session) [31][9]. So the sweep's stop signal is a *kernel* counter, `Threads` against `TasksMax` on Core and `FDSize` against `NOFILE` on the Minion, not a JVM or scheduler one.

**Memory is the ceiling that arrives quietly, and it is not the one the strategy names.** Dimension 2 shows a thousand blocked threads commit tens of megabytes of stack, not a gigabyte [14][16], so the strategy's implicit "more threads, more memory" concern is mostly address space. The unbudgeted risks are glibc malloc arenas, which reached 1.5 GB in a JDK 17 case [18], and G1's native structures on a heap already at its ceiling. On a 16 GiB box with `-Xmx10240m`, the process has perhaps 2 to 3 GiB of RSS room before the OOM-killer [24], and no source found puts a number on how much of that a doubled pool takes. That has to be measured with NMT, not derived.

## Recommendations

Each is bound to the decision (how far to raise the pool, and what binds first) and names its confidence basis.

1. **Raise the pool, and expect the throughput to track it linearly for a while.** The Collectd pool is a plain fixed executor with nothing on the RPC path to throttle it [1][4][5]. Under 75 ms mean latency the pool holds each collection about 11 s, so throughput is roughly `threads / 11` collections per second until something else binds. High confidence on the mechanism (verified source); the linear range's extent is what the sweep measures.

2. **Discard the strategy's three stop signals; adopt these instead.** Per-thread `voluntary_ctxt_switches` rate as the I/O-completion proxy, `Udp: InDatagrams` on the Minion, and at the edge `RcvbufErrors` and `MemErrors` [37][33][34]. Keep Gregg's `r > CPU count`, not `2×`, and drop the `%sys` and `nvcswch` percentage thresholds, which have no primary source [40][41]. **Never read context switches at process level on a JVM**; use `pidstat -w -t` and sum, or `/proc/PID/task/*/status`. High confidence: the last point was verified empirically on this Core during the run and the rest is sourced.

3. **Before the first rung, read the kernel limits and raise the ones that will bind.** On Core: `systemctl show -p TasksMax opennms.service`, `ulimit -u` for the `opennms` user, `Threads` in `/proc/PID/status`. On the Minion: `LimitNOFILE` on the unit and `FDSize`, because each in-flight SNMP request is a socket [9][31]. Set `MALLOC_ARENA_MAX` on Core (a common value is 2 to 4) before the sweep rather than after discovering arena bloat [18]. Medium confidence on the arena figure (single JDK 17 case); high on the limits.

4. **Measure native memory at each rung with NMT, and stop when RSS approaches the VM's RAM minus what the OS needs.** `-XX:NativeMemoryTracking=summary` at startup, then `jcmd <pid> VM.native_memory summary scale=MB` per rung against RSS. Watch the `Thread` and `GC` lines and the gap between NMT committed and RSS, which is where arenas live [14][16][24]. Medium confidence on the budgeting; there is no sourced per-thread committed figure for Linux x86-64 on JDK 21, so this replaces one.

5. **Do not pursue virtual threads on Horizon 36.** SNMP4J 2.8.15's synchronous send pins a virtual thread for the whole round trip on JDK 21 [42][43][26]. The route to a non-blocking collector is SNMP4J's async API, which OpenNMS already uses on the Minion side [8]; whether Collectd's collector path can use it is an OpenNMS question, not a JVM one. Medium confidence: the pinning construct was read from a 2.5.x mirror, not 2.8.15 itself.

6. **Instrument the Minion, because it is the second candidate to bind and the one nobody watches.** Enable `org.opennms.core.snmp.trackSessions=true` for a live session count [9], read the bulkhead metrics `activeRpcRequests` and `availableConcurrentCalls` [5], and watch consumer lag on the Core's single RPC response consumer [4], which is the one structural single-thread on the path and has no measurement behind it (medium confidence, inferred from code).

7. **Keep the outage test, but design it from OpenNMS's timeout semantics, not the strategy's generic version.** Parked for a separate session per the plan; the inputs it needs are the RPC TTL precedence [11] and the per-agent `timeout` and `retry` in the SNMP config, because a request that expires before the Minion reads it is dropped there and the Core sees a timeout exception [11].

## The corrected sweep plan

What the strategy's Step 2 becomes for this lab. Fleet held at the failing size under 50 to 100 ms per PDU; the pool is the only variable.

| | Strategy as written | Corrected for this workload |
|---|---|---|
| Start | 10 threads/core (80) | the current 100, which is already the first rung |
| Step | 10 to 15 threads/core | double: 100 → 200 → 400 → 800 → 1,600; halve back on failure |
| Settle per rung | 5 to 10 min | restart, then one full cycle plus 300 s after the queue is seen draining |
| Window | unstated | 900 s, three cycles, integer multiple of the interval |
| Throughput | QPS | `increase(collectd_taskscompleted[900s]) / 900` against `services / 300` |
| Latency | p99 | per-collection wall time from `collectData` instrumentation, not p99 of a socket |
| Stop signal 1 | `nvcswch` spike | `Threads` in `/proc/PID/status` within 10% of `TasksMax`; Minion `FDSize` within 10% of `NOFILE` |
| Stop signal 2 | `r > 2×cores` | RSS within 1 GiB of VM RAM, or NMT `Thread` + `GC` committed growing faster than linear in threads |
| Stop signal 3 | `%sys > 15 to 20%` | `RcvbufErrors` or `MemErrors` rising on the Minion; Core RPC response consumer lag rising |
| Stop signal 4 | none in the strategy | Core CPU busy above 80%, which is where the strategy's CPU concern finally applies |
| Per rung, capture | `pidstat -w`, `vmstat`, `jcmd Thread.print` | `pidstat -w -t` summed, `jcmd VM.native_memory summary`, `jcmd Thread.print` state histogram, Minion `trackSessions` log, Minion bulkhead metrics |
| Optimum | 70 to 80% of the thread count where involuntary switches explode | the largest pool at which throughput still rises at least 20% per doubling and no stop signal fires; then set 80% of it |

The doubling step is chosen because dimension 1 predicts linear scaling up to a limit that is unknown by an order of magnitude; ten-percent steps would take a day to reach it. Halving back on the first failure brackets the limit to within 2×, which a second, finer sweep can narrow.

## Open questions

- **Where does the Core's single RPC response consumer saturate?** Structural bottleneck, no measurement, no issue reports found [4]. Answered by consumer-lag on `OpenNMS.rpc-response` during the sweep.
- **What is the per-thread committed memory of a blocked thread on Linux x86-64, JDK 21?** No sourced figure; only ratios from JDK 11-era field data [16]. Answered by NMT at rung one and two.
- **Does G1 pause time move with blocked-thread count?** No published measurement [21][22]. Answered by `-Xlog:gc*,gc+phases=debug,safepoint` at 100 and 800 threads, comparing "Thread Roots" and "Reaching safepoint".
- **Is SNMP4J 2.8.15's wait construct the same as 2.5.x?** The exact release was not fetched [43]. Answered by the Maven sources jar for 2.8.15.
- **Which per-user or per-unit limit actually binds first on this Core?** `TasksMax` is the candidate [31]; its live value was not read during the run. One command.
- **Outage behaviour of a large blocking pool.** Cut from this run and parked; needs OpenNMS's timeout and retry semantics as inputs [11].

## Source appendix

| n | supports | publisher | pub | accessed | confidence |
|---|---|---|---|---|---|
| [1] | Collectd fixed pool, unbounded queue, slippage not rejection | [OpenNMS source, LegacyScheduler.java (develop)](https://github.com/OpenNMS/opennms/blob/develop/core/daemon/src/main/java/org/opennms/netmgt/scheduler/LegacyScheduler.java) | undated | 2026-09-03 | high |
| [2] | Official `threads` guidance | [docs.opennms.com, Horizon 36 Collectd configuration](https://docs.opennms.com/horizon/36/operation/deep-dive/performance-data-collection/collectd/configuration.html) | undated | 2026-09-03 | high |
| [3] | Collectd daemon reference silent on threads | [docs.opennms.com, Horizon 36 Collectd daemon](https://docs.opennms.com/horizon/36/reference/daemons/daemon-config-files/collectd.html) | undated | 2026-09-03 | high |
| [4] | Core RPC client: one response consumer, no cap | [OpenNMS source, KafkaRpcClientFactory.java (develop)](https://github.com/OpenNMS/opennms/blob/develop/core/ipc/rpc/kafka/src/main/java/org/opennms/core/ipc/rpc/kafka/KafkaRpcClientFactory.java) | undated | 2026-09-03 | high (structure) / medium (bottleneck inference) |
| [5] | Minion bulkhead is observability only | [OpenNMS source, KafkaRpcServerManager.java (release-36.x)](https://raw.githubusercontent.com/OpenNMS/opennms/release-36.x/core/ipc/rpc/kafka/src/main/java/org/opennms/core/ipc/rpc/kafka/KafkaRpcServerManager.java) | undated | 2026-09-03 | high |
| [6] | Bulkhead defaults 1000 / 100 ms | [OpenNMS source, KafkaRpcConstants.java (release-36.x)](https://raw.githubusercontent.com/OpenNMS/opennms/release-36.x/core/ipc/common/kafka/src/main/java/org/opennms/core/ipc/common/kafka/KafkaRpcConstants.java) | undated | 2026-09-03 | high |
| [7] | Bulkhead introduced NMS-12391, Horizon 27 | [OpenNMS vault, 27.2.0 release notes](https://vault.opennms.com/docs/opennms/releases/27.2.0/releasenotes/releasenotes.html) | 2021 | 2026-09-03 | medium (snippet) |
| [8] | Minion SNMP execution is async, no throttle | [OpenNMS source, SnmpProxyRpcModule.java (develop)](https://github.com/OpenNMS/opennms/blob/develop/core/snmp/proxy-rpc-impl/src/main/java/org/opennms/netmgt/snmp/proxy/common/SnmpProxyRpcModule.java) | undated | 2026-09-03 | high |
| [9] | Session per operation, trackSessions | [OpenNMS source, Snmp4JStrategy.java (develop)](https://github.com/OpenNMS/opennms/blob/develop/core/snmp/impl-snmp4j/src/main/java/org/opennms/netmgt/snmp/snmp4j/Snmp4JStrategy.java) | undated | 2026-09-03 | high (props) / medium (socket-per-session inference) |
| [10] | Kafka RPC tuning knobs | [docs.opennms.com, Horizon 36 tuning Kafka](https://docs.opennms.com/horizon/36/reference/configuration/tuning-kafka.html) | undated | 2026-09-03 | high |
| [11] | RPC TTL precedence, expiry behaviour | [docs.opennms.com, Horizon 33 TTL for RPC](https://docs.opennms.com/horizon/33/reference/configuration/ttl-rpc.html) | undated | 2026-09-03 | medium |
| [12] | Default 1 MB stack, NMT accounting (old) | [xmlandmore, JDK 8 thread stack size](https://xmlandmore.blogspot.com/2014/09/jdk-8-thread-stack-size-tuning.html) | 2014-09 | 2026-09-03 | medium |
| [13] | stacksize/guardsize, VMThreadStackSize | [petrbouda/threads-memory README](https://github.com/petrbouda/threads-memory/blob/master/README.md) | undated (JDK 11) | 2026-09-03 | medium |
| [14] | NMT stack committed by page liveness | [OpenJDK JBS, JDK-8191369](https://bugs.openjdk.org/browse/JDK-8191369) | 2018 | 2026-09-03 | high |
| [15] | Liveness mechanism current | [openjdk/jdk PR 19231](https://github.com/openjdk/jdk/pull/19231) | 2024 | 2026-09-03 | high |
| [16] | Committed ratios, per-thread metadata, budget formula | [Brice Dutheil, Off-heap reconnaissance](https://blog.arkey.fr/2020/11/30/off-heap-reconnaissance/) | 2020-11-30 | 2026-09-03 | medium (excerpt) |
| [17] | Stack committed pagewise, -Xss myth | [foojay.io, Rahman](https://foojay.io/today/exploring-the-impact-of-stack-size-on-jvm-thread-creation-a-myth-debunked/) | 2023-09-20 | 2026-09-03 | medium (macOS) |
| [18] | glibc arena bloat, MALLOC_ARENA_MAX | [DZone, JDK memory bloat in containers](https://dzone.com/articles/jdk-memory-bloat-containers) | undated (JDK 17) | 2026-09-03 | medium |
| [19] | THP stack fix JDK 21 b26 | [OpenJDK JBS, JDK-8303215](https://bugs.openjdk.org/browse/JDK-8303215) | 2023 | 2026-09-03 | high |
| [20] | khugepaged race | [OpenJDK JBS, JDK-8312182](https://bugs.openjdk.org/browse/JDK-8312182) | 2023 | 2026-09-03 | high |
| [21] | G1 root scanning includes thread stacks | [Poonam Parhar, Understanding G1 GC logs](https://poonamparhar.github.io/understanding_g1_gclogs/) | undated | 2026-09-03 | medium |
| [22] | Time-to-safepoint driven by running threads | [blanco.io, JVM safepoint pauses](https://blanco.io/blog/jvm-safepoint-pauses/) | undated | 2026-09-03 | medium |
| [23] | Long pauses without GC | [Loonytek](https://loonytek.com/2020/01/20/long-jvm-pauses-without-gc/) | 2020-01-20 | 2026-09-03 | medium |
| [24] | RSS composition, -Xmx bounds heap only | [TheCodeForge, JVM memory model](https://thecodeforge.io/java/jvm-memory-model/) | undated | 2026-09-03 | medium |
| [25] | Rules of thumb without measurement | [HeapHero, off-heap leak](https://blog.heaphero.io/java-off-heap-memory-leak/) | undated | 2026-09-03 | low |
| [26] | JEP 444 pinning, DatagramSocket rework | [OpenJDK, JEP 444](https://openjdk.org/jeps/444) | 2023 | 2026-09-03 | high |
| [27] | synchronized pinning removed in JDK 24 | [OpenJDK, JEP 491](https://openjdk.org/jeps/491) | 2024 | 2026-09-03 | high |
| [28] | SNMP4J MultiThreadedMessageDispatcher / WorkerPool | [AGENTPP SNMP4J 2.8.16 Javadoc](https://agentpp.com/doc/snmp4j-2.8.16/org/snmp4j/util/MultiThreadedMessageDispatcher.html) | undated | 2026-09-03 | medium |
| [29] | threads-max, pid_max | [man7.org, proc_sys_kernel(5)](https://man7.org/linux/man-pages/man5/proc_sys_kernel.5.html) | 2026-02-08 | 2026-09-03 | high |
| [30] | systemd pid_max sysctl | [systemd, 50-pid-max.conf](https://github.com/systemd/systemd/blob/main/sysctl.d/50-pid-max.conf) | undated | 2026-09-03 | medium |
| [31] | DefaultTasksMax, DefaultLimitNOFILE | [Ubuntu manpages, systemd-system.conf(5) noble](https://manpages.ubuntu.com/manpages/noble/en/man5/systemd-system.conf.5.html) | undated (255.4) | 2026-09-03 | high |
| [32] | /proc/PID/status Threads, FDSize | [man7.org, proc_pid_status(5)](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html) | 2026-02-08 | 2026-09-03 | high |
| [33] | RcvbufErrors semantics | [ralphbupt, UDP packet loss](https://ralphbupt.github.io/2024/07/07/Troubleshooting-a-UDP-Packet-Loss-Issue-on-Linux/) | 2024-07-07 | 2026-09-03 | medium |
| [34] | UDP MemErrors counter | [LKML, Menglong Dong, UDP_MIB_MEMERRORS](https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2011.0/07296.html) | 2020-11-05 | 2026-09-03 | high |
| [35] | rmem_default / rmem_max, netdev_max_backlog | [docs.kernel.org, sysctl/net](https://docs.kernel.org/admin-guide/sysctl/net.html) | undated | 2026-09-03 | high |
| [36] | udp_mem, udp_rmem_min | [docs.kernel.org, ip-sysctl](https://docs.kernel.org/networking/ip-sysctl.html) | undated | 2026-09-03 | high |
| [37] | Voluntary vs involuntary switch definitions | [man7.org, getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html) | 2026-02-08 | 2026-09-03 | high |
| [38] | pidstat -w, -t | [man7.org, pidstat(1)](https://man7.org/linux/man-pages/man1/pidstat.1.html) | 2025-01 | 2026-09-03 | high |
| [39] | pidstat reads per-TID status | [sysstat, pidstat.c](https://raw.githubusercontent.com/sysstat/sysstat/master/pidstat.c) | undated | 2026-09-03 | high |
| [40] | USE checklist thresholds | [Brendan Gregg, USE method Linux](https://www.brendangregg.com/USEmethod/use-linux.html) | 2013-09-29 | 2026-09-03 | high |
| [41] | Absence of source for %sys and nvcswch thresholds | searched: kernel docs, Gregg, Red Hat/Ubuntu tuning guides | n/a | 2026-09-03 | high (absence) |
| [42] | Horizon 36 pins SNMP4J 2.8.15 | [OpenNMS source, pom.xml (release-36.x)](https://raw.githubusercontent.com/OpenNMS/opennms/release-36.x/pom.xml) | undated | 2026-09-03 | high |
| [43] | SNMP4J sync send waits with synchronized+wait() | [brettwooldridge/snmp4j mirror, Snmp.java (2.5.6)](https://raw.githubusercontent.com/brettwooldridge/snmp4j/master/src/main/java/org/snmp4j/Snmp.java) | undated | 2026-09-03 | medium |

## Staleness map

Computed from the claims ledger with `recon_kit.py staleness`, using the technical pack's freshness bars: config 1 month, architecture / limit / memory / virtual-threads 12 months, udp / context-switch / heuristic / gc 24 months. Source-code reads carry the access date, since the claim is about the tree as of that day.

| ref | class | published | re-check by | state |
|---|---|---|---|---|
| [2] | config | 2026-09-03 | **2026-10-03** | fresh |
| [6] | config | 2026-09-03 | **2026-10-03** | fresh |
| [42] | config | 2026-09-03 | **2026-10-03** | fresh |
| [1], [4], [5], [9] | architecture | 2026-09-03 | 2027-09-03 | fresh |
| [31] | limit | 2026-09-03 | 2027-09-03 | fresh |
| [37], [39] | context-switch | 2026-02 / 2026-09 | 2028 | fresh |
| [27] | virtual-threads | 2024-01 | 2025-01 | past window; JEP 491 is shipped, mechanism stable |
| [26] | virtual-threads | 2023-01 | 2024-01 | past window; JEP 444 is final, mechanism stable |
| [19] | memory | 2023-01 | 2024-01 | past window; fixed bug, will not un-fix |
| [34] | udp | 2020-11 | 2022-11 | past window; kernel counter, stable since 5.11 |
| [16] | memory | 2020-11 | 2021-11 | **past window and load-bearing**: the only per-thread committed figure, JDK 11 era |
| [14] | memory | 2018-01 | 2019-01 | past window; confirmed current by [15] in 2024 |
| [40] | heuristic | 2013-09 | 2015-09 | past window; counter names still valid, thresholds unchanged |

**Earliest re-check: 2026-10-03**, the three `config` claims, which is the pack's one-month bar for version and configuration facts. Of the claims past their window, only [16] matters: the per-thread committed-stack ratio is the one number the memory budget rests on and it is six years old. The sweep's NMT measurement at rung one replaces it with a figure from this box, which is the right way to refresh it.

## Sweep result (added after the run, 2026-09-03)

The corrected sweep plan was executed the same day against the 3,000-device fleet under 50 to 100 ms per PDU. This section records what it found; it is lab measurement, not sourced research, and is kept apart from the cited findings above.

| threads | collections/s | completion | queue drains | pool mean / peak | Core CPU | RSS MB | NMT Thread MB | involuntary CS/s | share |
|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|
| 100 | 8.79 | 87.8% | no, floor 1,512 | 100 / 100 | 15.8% | 9,266 | n/a | 2,037 | 10.3% |
| 200 | 9.87 | 98.6% | yes, floor 0 in 75% | 120 / 200 | 17.3% | 9,539 | 127 | 34 | 0.6% |
| 250 | 9.90 | 98.8% | yes | 127 / 250 | 18.3% | 9,560 | 132 | 182 | 1.2% |
| 300 | 9.84 | 98.3% | yes | 120 / 300 | 18.4% | 9,336 | 132 | 952 | 3.8% |
| 350 | 9.79 | 97.8% | yes | 124 / 350 | 18.0% | 9,362 | 142 | 2,213 | 7.5% |
| 400 | 9.79 | 97.8% | yes, floor 0 in 93% | 120 / 400 | 17.8% | 9,491 | 152 | 1,449 | 7.0% |

Required rate at 3,004 services: 10.01/s. The doubling sweep stopped at 400 on the throughput-gain signal: 400 delivered 0.8% *less* than 200. A second, linear pass at 250, 300 and 350 then asked a different question: at what pool size does the scheduling burst stop touching the ceiling? The answer is **not below 400**. Every one of the six pool sizes peaks at exactly 100% of its pool at the crest of each cycle's wave, while the mean sits at 120 to 127 throughout.

**What it says.** The pool was the constraint at 100 and stopped being the constraint at 200. Throughput went from 8.79/s to 9.87/s, the queue went from never draining to draining every cycle, and involuntary context switches collapsed from 2,037/s to 34/s: the pinned pool at 100 was thrashing to keep up, and the extra 100 threads gave it slack. Doubling again to 400 bought nothing: same throughput, same mean occupancy (120 either way, the fleet does not need more), and involuntary switches climbed back to 1,449/s. That last number is the first sign of the overhead the original strategy was watching for, and it appeared only once the pool was twice what the fleet uses.

**Why 400 rather than 200 was the first rung to pass** is the criterion, not the system. Both rungs drained the queue every cycle. The 0.99 median completion-ratio bar caught 200 at 0.985 because that gauge is a sawtooth that resets at each cycle boundary and the window sampled slightly more of the reset phase; 400's median was 1.0 with a *lower* minimum of 0.948. The ratio is a per-task measure and a poor discriminator between two rungs that both complete; the queue floor and the counter are what to read.

**The memory question got an answer.** NMT committed for thread stacks was 127 MB at 200 and 152 MB at 400: about 125 KB per thread, at the top of the 30 to 100 KB band the sources gave, and 25 MB for an extra 200 threads. RSS did not move between the rungs (9,539 versus 9,491 MB) with `MALLOC_ARENA_MAX=4` in place. The unsourced per-thread figure from the research is now measured on this box.

**What binds first, at this fleet, turned out to be nothing.** None of the stop signals fired except the gain check. Threads, file descriptors, RSS, UDP drops and CPU all stayed far from their limits at 400. That is the answer to the decision: on this hardware under this latency, the pool can be raised until throughput stops responding, and it stops responding at the point where mean occupancy no longer grows, around 120 for this fleet. A larger fleet would push that point higher; the sweep gives the method, not a universal number.

**Recommendation for this fleet: 200.** It is the smallest pool that completes the cycle, and the involuntary-switch column makes the case better than the throughput column can: 34/s at 200, then 182, 952, 2,213 and 1,449 as the pool grows, while throughput and mean occupancy do not move. Every thread above what the fleet uses is a thread that gets woken and preempted for nothing. The plan's 80%-of-ceiling rule does not apply: it assumes a throughput knee, and this workload has a plateau that starts at 200 and a preemption cost that rises from there.

**What the burst-detach search found instead.** Collectd releases the whole fleet's due collections as a wave, and at 3,000 devices holding a thread about 11 s each, the crest of that wave wants more than 400 concurrent slots even though the cycle's average is 120. A pool that absorbs the crest without queueing would have to be measured above 400, and at 400 the preemption cost is already 7% of switches. Whether such a pool is worth its cost is the outage question, parked for its own session: the crest is where a rescan wave or a burst of timeouts would land.

Data: `experiments/pm-snmp-agent-latency/results/pool-sweep.jsonl`, `pool-sweep.log`, per-rung NMT and thread-state captures as `rung-<n>-{before,after}-{nmt,threads}.txt`.
