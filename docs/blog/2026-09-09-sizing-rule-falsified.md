# Our sizing rule specified a machine. We built it, and it collapsed.

Over six days in September we ran six knee searches, a latency sweep and a cleanroom edge search against a single OpenNMS Core to find where SNMP collection stops.
Out of them fell a capacity rule with two measured constants.
It was a satisfying result, and we did not trust it.
A rule fitted to the runs that produced it will always look good.

So we used it to specify two machines we had never built, built them, and measured what happened.

One was right to within seven per cent on every term.
The other collapsed at a hundred per cent CPU where the rule predicted sixty-seven.
Then we went looking for the boundary in the other direction, at the protocol rather than the processor, and found that our pessimism there was just as misplaced.

This is what the measurements corrected, in both directions.

## The rule

A collection of one device is a sequence of SNMP round trips, and a collection thread spends its life waiting on them.
That gives the first constant.

```
thread time per collection   T = P × R + 0.75 s
```

`P` is the number of sequential GETBULK requests a collection takes, `R` is the agent's response time, and 0.75 s is the Core's own work: decoding, persisting, scheduling.
For our test device, a simulated Cisco CRS-X with 144 interfaces, `P` is 61 at `max-repetitions=5` and 149 at the shipped default of 2.
That single attribute is the largest lever in the whole rule, and it is configuration rather than hardware.

The second constant is what a collection costs the processor, and it does not depend on latency at all.
The Core decodes the same samples whether the Minion took half a second or twelve to gather them.
Measured across four captures with heap headroom, it is 66 µs of Core CPU per sample, or about **15,000 samples a second per core**.
On a pressed heap it falls to somewhere between 10,900 and 13,100 and stops being predictable, because garbage collection time is charged to the processor.
The scatter is the finding: there is no second constant there, only a penalty.

From those two constants, three limits:

```
threads   N = 1.2 × C × T          C = collections per second
cores     K = S / 15,000 / U       S = metrics per second, U = 0.85 to size
```

There is a third for the heap, and the knee is whichever of the three binds first.
Across the six knee searches the rule reproduced every measured knee to within one rung of 500 devices, and named the binding term correctly each time: the pool four times, the processor once, the heap once.
The latency sweep and the edge search are the same rule read at other agent response times, and it holds there too.

That is where most capacity work stops.

## Case B: the rule was right

The first machine the rule specified: 40,000 metrics a second at a five second collection, which is 6,904 devices, on 4 vCPU with 20 GiB of memory, a 12 GiB heap and a 150-thread pool.
We reduced the fleet to that device count, set the VM to that size, and set agent latency to the value the rule predicts for a five second collection.
Then we measured.
Both machines below are the same Core VM, resized between the two runs.

| Term | Rule | Measured | Error |
|---|---:|---:|---:|
| Devices | 6,904 | 6,904 | exact |
| Metrics per second | 40,000 | 40,443 | +1.1 % |
| Collection duration | 5.00 s | 4.77 s | −4.6 % |
| Busy threads | 115 | 111 | −3.5 % |
| Cores busy | 2.67 | 2.51 | −6 % |
| Samples/s per core | 15,000 | 16,087 | +7 % |
| Live heap | 7.0 GiB | 7.69 used, no old-gen GC | fits |
| Queue | drains | min 0, max 84 | pass |

No term off by more than seven per cent, and the queue returned to zero inside the interval, which is our pass criterion.
The per-core figure came in *above* 15,000 because the 12 GiB heap has genuine headroom and no old-generation collection ran in the window.
That is the difference between our two CPU constants, observed directly rather than inferred.

## Case A: the rule was wrong

The second machine: 20,000 metrics a second at a ten second collection, which is 3,452 devices, on 2 vCPU with 12 GiB, an 8 GiB heap and the same 150-thread pool.
By the rule this is a machine running at 67 % of its processor.

It did not work.

| Term | Rule | Measured |
|---|---:|---:|
| Devices | 3,452 | 3,452 exact |
| Metrics per second | 20,000 | 15,676, 78 % of target |
| Cores busy | 1.33 of 2, 67 % | **2.00 of 2, 99.9 %** |
| Busy threads | 115 | 150, pool pinned |
| Collection duration | 10.0 s | 16.63 s |
| Queue | drains | **min 1,100, max 3,302** |
| Live heap | 4.7 GiB | 3.91 used, no old-gen GC |

The queue never returned to zero.
Collection times stretched from ten seconds to sixteen because collections take longer under a starved processor, which fills the pool further, which starves it more.
OpenNMS terminated itself three times, each with the processor at or beyond the practical ceiling of its two cores; the judged window reads 99.9 %.

Memory was never the problem: the heap term, which we had flagged as the weakest part of the rule, was comfortable in both cases.
The processor term is what failed.

## A saturated machine cannot report its own demand

The obvious next question is by how much the rule under-sized it, and that question has no answer from this run.

At 100 % CPU the measurement is censored.
Two cores is all there was, not what the work needed.
You can measure demand up to the point where supply constrains it and no further, and once a system is in collapse the numbers it produces describe the collapse rather than the workload.
The stretched collection times are the same artefact: they are a consequence of the shortage, not a property of the work.

This is worth stating plainly because it is easy to read "2.00 cores" off a dashboard and treat it as a requirement.
It is a ceiling.

## Two cores sustain the load. They cannot start it.

To get an uncensored number we rebuilt the same fleet on eight cores, let it reach steady state, and then took six cores offline from inside the guest with `echo 0 > /sys/devices/system/cpu/cpuN/online`.
The guest scheduler then dispatches to two CPUs and computes its run queue over two.
No restart, and critically, no startup burst.

| | 8 cores | 2 cores, hot-offlined | 2 cores, from a restart |
|---|---:|---:|---:|
| Metrics per second | 19,758 (98.8 %) | **19,952 (99.8 %)** | 15,676 (78 %) |
| Cores busy | 1.61 of 8 | **1.53 of 2, 76 %** | 2.00 of 2, 100 % |
| Collection duration | 9.87 s | 11.59 s | 16.63 s |
| Queue | min 0, max 94 | **min 0, max 509, drains** | 1,100 to 3,302 |
| Outcome | pass | **pass** | collapse |

Two cores sustain this workload comfortably, at 76 % utilisation, delivering 99.8 % of the target rate with the queue draining every interval.

What two cores cannot do is *start* it.
Every restart makes the whole fleet fall due at once, and we had measured that recovery burst elsewhere in the campaign at 1.46 times steady-state CPU.
Against the 1.61 cores this workload actually demands, that is 2.35 cores against the two it has, so the queue never drains, and the collapse feeds itself.
The machine never reaches the steady state the rule sized it for.

**Our rule sized a steady state without asking whether the machine could get there.**
On four cores that gap is invisible because the burst fits in the spare capacity. On two it is fatal.

One caveat on that method: the JVM had already sized its garbage collector and thread pools for eight CPUs when it started, and those do not shrink when the cores go away.
So this is not byte-identical to a natively booted two-core machine.
The bias runs conservative, since more collector threads contending over two cores is harder rather than easier, so the pass stands.

And one methodological note, because it nearly cost us the result.
That 76 % figure comes from `100 - avg(rate(node_cpu_seconds_total{mode="idle"}))`, and `avg` is taken over whatever CPUs are reporting.
Had Node Exporter kept publishing the six offline cores with frozen counters, their idle rate would have been zero, reading as fully busy, and the same query would have returned 94 %.
We checked: it drops them, `[0,1]` during the window against `[0..7]` before.
The conclusion survived, but only because we looked.

## The rule has no constant term

Running case A on eight cores gave something the collapsed run could not: an uncensored reading of what the work actually costs.

It is 1.61 cores against the rule's 1.33, nineteen per cent low.
Case B, at four times the rate, went the other way: 2.51 measured against 2.67 predicted, six per cent high.

| Case | Collections/s | Cores busy | Core-seconds per collection |
|---|---:|---:|---:|
| A | 11.37 | 1.61 | 0.142 |
| B | 23.27 | 2.51 | 0.108 |

A collection does not get cheaper as you do more of them.
A fixed cost is being spread over more work.
Fitting those two points gives roughly 0.75 of a core of fixed overhead plus 0.076 core-seconds per collection.
The JVM, Karaf, Jetty, eventd, alarmd and the exporters do not shrink with the fleet.
On eight cores that 0.75 is a tenth of the machine and hides inside our constant. On two it is more than a third.

Over-predicting at high rates and under-predicting at low ones is the signature of a model missing an intercept, and ours is linear through the origin.

Two limits on that fit.
It rests on two points, and it does not extrapolate: applied to our 20,250-device rung it predicts 5.9 cores where 7.7 were measured.
So it is evidence that a constant term exists and matters at the small end, not a replacement for the rule.

## The other boundary: you cannot break it from the configuration

Having found the processor model too optimistic, we went looking at the protocol, where we expected the opposite.

Raising `max-repetitions` is the cheapest capacity you can buy: 149 requests per collection become 61, thread time halves, and a 200-thread pool goes from 5,000 devices to 11,750.
But each unit of the setting adds roughly 227 bytes to the response, and responses have a hard ceiling at the path MTU.
We captured 83,009 live responses at `max-repetitions=5`: the largest was 1,221 bytes, 81 % of a 1,500 byte MTU, with 279 bytes to spare and not one fragment.
Extrapolating, 6 is the last value that fits and 7 would overflow.
Every datagram in that capture also had the don't-fragment bit set, so an oversized response is never reassembled: it fails at the sender, or is dropped by the first hop too small to forward it.

So we set `max-repetitions=20` on one /24, four times past the ceiling, and watched.

The agent clamped its responses at the MTU and never exceeded it: median 1,487 bytes, maximum 1,500.
Nothing fragmented, and every request was answered one for one.
A conformant agent returns as many rows as fit and truncates the rest, and truncation is graceful: the walk simply takes another round trip.

The gain saturated accordingly.
Four times the setting bought 23 % fewer requests, not four times fewer, because the responses were already full.
That independently confirms the ceiling of about 6 from the opposite direction.

So a badly chosen `max-repetitions` is not the risk. The agent protects you.

## A path that is too small breaks it completely, and invisibly

The risk is a path smaller than the responses: a tunnel that eats header space, a VLAN with a reduced MTU, and the blocked ICMP that stops anyone finding out.

We simulated one by dropping responses over 1,000 bytes for a single /24, with the neighbouring /24 untouched as a control.
That is a firewall rule rather than a reduced interface MTU, which reproduces the case where ICMP is blocked and nothing reports the problem back.
Here is a failing collection, with request-ids:

```
+0.000 s  GetBulk   request-id=142022295  N=10 M=1   162 B   answered
+0.091 s  GetBulk   request-id=142022297  N=10 M=1   195 B   answered
+0.173 s  GetBulk   request-id=142022299  N=0  M=5   190 B   response dropped
+1.972 s  GetBulk   request-id=142022299  N=0  M=5   190 B   response dropped
          walk abandoned
```

The first two requests fetch scalars, so their responses are small and survive.
The third is the first request for *table rows*, and its response is the first one big enough to vanish.

Three things follow, all measured.

**The retry is one request, not the collection.**
Same request-id, in 75 of 75 failing collections, byte-identical, on the same socket.
Nothing already collected is re-fetched.

**The walk is abandoned.**
Across 328 attempts, 325 made exactly four requests and none completed.
The retry gap was 1.800 s, the configured timeout to the millisecond.

**Nothing is persisted.**
Zero records reached the metrics topic for that block, against 25,752 for the control.
Not even the two scalar responses that arrived successfully.

And the failure is invisible to reachability monitoring.
The device answers ICMP.
It answers SNMP.
It answers the first two requests of every collection, so an SNMP reachability check passes.
A node that is up, pingable and green, producing no data at all, forever.

A late failure is also the expensive one.
Failing at request 3 costs 3.75 s of thread time.
Failing at request 61 costs sixty successful round trips plus the 3.6 s timeout, about 8.2 s, and still yields nothing.

## The same retry that saves you, and cannot

We then asked whether ordinary packet loss does the same thing, and predicted it would be brutal: a 61-request collection at 5 % loss should survive only 4 % of the time.

Measured: 85 %.

We had forgotten the retry.
A request only fails if *both* attempts are lost, which at 5 % loss is 0.25 %, so `0.9975⁶¹` is 85.8 % of collections intact.
Measured 84.7 %.
Our prediction was wrong by a factor of twenty, in the reassuring direction.

Pushing loss to 20 % separates the two possible models cleanly, because at that rate only 8 % of collections survive intact:

| | All-or-nothing predicts | Partial persistence predicts | Measured |
|---|---:|---:|---:|
| Data volume vs control | 8 % | 54 % | **10.2 %** |

All-or-nothing, decisively.
A collection that fails anywhere is discarded entirely, including everything already gathered.

The retransmission being byte-identical is what decides both outcomes.
Against random loss it is a fresh roll of the dice, and it rescues almost everything.
Against a response that is simply too big it is the same packet meeting the same limit, and it fails every time, forever.

## What we changed

The cores term gained a floor of four vCPU, so the rule now reads:

```
threads   N = 1.2 × C × T
cores     K = S / 15,000 / U, never fewer than 4
```

That floor is measured rather than derived. It comes from a single collapse, and four is where this lab stopped failing rather than a proven minimum.
Under it, case A asks for four cores instead of two.

The missing constant term is recorded but not yet in the arithmetic.
Two points is not a model, and the fit does not extrapolate.
What we can say is that the rule under-sizes small collectors and that the reason is a fixed overhead it does not count.

The heap term, which we distrusted most, was the one that behaved.
It over-predicted the live set in both tests, 7.0 GiB against 7.69 used and 4.7 against 3.91.
Over-predicting memory is the safe direction.

## What we still would not trust

The four vCPU floor rests on one failing case, and the restart-burst mechanism behind it was never isolated in a controlled experiment.

Every constant is a property of one simulated device with 144 interfaces and one collection package.
Another device moves the samples per collection, the thread time and the 66 µs together.
The form of the rule does not change. The constants must be read again the same way.

On the collection-loss result, we watched the abort anatomy at request 3 and established all-or-nothing persistence statistically, across failures at randomly chosen positions.
We never watched a failure at exactly the last request of a walk.
The generalisation is well supported and the direct observation is missing.

The rule sizes steady-state collection and models provisioning not at all.
The same test showed two vCPU could not complete a provisioning import of 3,452 nodes either, and we had to run the import on eight cores before downsizing.

And the whole campaign used agents that fail cleanly by timing out.
An agent that answers late, or answers some tables and not others, holds a collection thread far longer than one that is simply gone.
That is the outage that loads a collector, and we have not run it.

---

*All figures come from a lab of simulated SNMP agents driven by nl6, one OpenNMS Core and one Minion, measured between 1 and 9 September 2026 on OpenNMS 36 running JDK 21 with G1.*
*The underlying reports, the capture scripts and the raw records are in [opennms-benchmark](https://github.com/indigo423/opennms-benchmark) under `experiments/`.*
