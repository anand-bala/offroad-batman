=====================================================================
Improving Mobility Robustness in a Morse Micro HaLow + IBSS + BATMAN-adv MANET
=====================================================================

System
======

Current stack:

1. Physical: Morse Micro Wi-Fi HaLow
2. Network/link: IBSS on HaLow + BATMAN-adv for meshing

Observed issue:

    Latency and throughput drop significantly between two nodes when one
    node is in motion.

Only two nodes have been tested so far; more nodes will be added.

----

Executive summary
==================

The first place to investigate is **the radio/link layer, not BATMAN-adv**.

The likely chain is:

1. Motion changes the RF channel, antenna geometry, and multipath/fading
   conditions.
2. The HaLow PHY lowers its MCS and/or incurs more retransmissions.
3. MAC-layer retries and contention increase latency.
4. Effective throughput falls.
5. BATMAN-adv eventually sees the neighbor as degraded or unreachable.
6. With only two nodes, there is no alternate path, so the mesh cannot
   compensate.

The two-node test is therefore useful for isolating the PHY problem, but
it cannot demonstrate whether BATMAN-adv can compensate for mobility.
Once three or more nodes exist, path diversity becomes much more
valuable.

----

1. First isolate the radio from BATMAN-adv
===========================================

Run a direct test conceptually like::

    Node A <---- HaLow/IBSS ----> Node B

Collect measurements at high frequency while one node moves:

- RSSI
- SNR, if exposed
- MCS
- PHY bitrate
- packet retry count
- packet loss
- retransmission rate
- channel busy time
- latency
- UDP throughput
- TCP throughput

The most useful plots will correlate these values over time.

For example::

    time ->
    ────────────────────────────────────────────────────────

    RSSI       ─────╲──────╱╲──────────╲────
    MCS        8 8 7  5 3 1  4 6 7 8  5 2
    retries       ▁▂▅████▆▃▁      ▁▃█████
    latency    ────╱╱╱╲───────────╱╱╱╱
    throughput ────╲╲╲╱───────────╲╲╲╲

If you see::

    MCS collapse
    +
    retries increase
    +
    latency increase
    +
    throughput decrease

then the problem is primarily below BATMAN-adv.

If the radio remains healthy but BATMAN-adv latency/throughput
collapses, then the mesh layer deserves more attention.

----

2. Experiment with a more conservative PHY configuration
==========================================================

Don't optimize exclusively for maximum stationary throughput.

Optimize for **stable throughput under channel variation**.

Morse Micro HaLow devices support a range of MCS levels, giving the PHY
substantial room to trade peak throughput for robustness.

A useful experiment is to constrain the maximum MCS and compare
mobility performance.

For example, if the stationary system normally operates around a high
MCS, test several lower ceilings::

    max MCS 9
    max MCS 7
    max MCS 5
    max MCS 3

Measure:

- median throughput
- 5th/1st percentile throughput
- packet loss
- latency
- retry rate
- frequency of MCS changes

The goal is not necessarily to maximize peak throughput. A lower MCS
that remains stable while moving may produce much better *real-world*
throughput and latency.

----

3. Experiment with channel width
=================================

Don't assume the widest channel is optimal.

Test::

    8 MHz
    4 MHz
    2 MHz
    1 MHz

A narrower channel may provide better robustness in a
difficult/multipath environment even though its nominal PHY rate is
lower.

For each width, compare the same mobility test.

The useful metric is not just peak Mbps; compare::

    throughput x stability x latency

----

4. Investigate the antenna very carefully
==========================================

This can be a major factor for a moving node.

At roughly 900 MHz, the wavelength is about 33 cm. Relatively small
changes in antenna position, orientation, polarization, nearby
conductive material, or reflections can substantially affect the
received signal.

This is especially important if the node is:

- vehicle-mounted
- robot-mounted
- drone-mounted
- handheld
- worn by a person

Test the antenna in the **actual mechanical installation**, not just on
a bench.

Useful experiments include:

A. Fixed polarization
----------------------

Keep both antennas consistently oriented.

B. Spatial diversity
---------------------

If the hardware supports it, test two spatially separated antennas.

C. Antenna placement
---------------------

Try to maximize clearance from:

- chassis/body
- batteries
- electronics
- large conductive surfaces

A bench test can have excellent link margin while the installed system
performs poorly.

----

5. Don't use RSSI alone as your mobility metric
================================================

A moving multipath channel can have reasonable RSSI while still
producing severe packet errors.

For example::

    RSSI:      -62 -63 -64 -62 -65 -64
    MCS:         8   8   7   5   2   1
    retries:     2   3   4  18  42  71

RSSI alone would suggest the link is still fairly good.

The MCS and retry trajectory says otherwise.

Build a link-quality estimate from multiple signals, for example::

    LQ = f(
        packet loss,
        retry rate,
        MCS,
        RSSI/SNR,
        PHY bitrate,
        latency
    )

The retry rate and MCS trajectory are particularly interesting for
detecting a rapidly deteriorating link.

----

6. BATMAN-adv and mobility
===========================

Once you have three or more nodes, BATMAN-adv becomes much more
interesting.

With two nodes::

    A <────────> B

if the A-B link becomes poor, there is no alternative path.

With three nodes::

           B
          / \
         /   \
        A─────C

you can potentially transition from::

    A -> B

to::

    A -> C -> B

before the direct A-B link becomes unusable.

That is the key advantage of having a real mesh.

----

7. Aim for make-before-break behavior
======================================

For a mobile MANET, ideally topology management should look like::

    Excellent
        |
        v
    Degrading
        |
        v
    Start preferring alternate path
        |
        v
    Alternate path becomes preferred
        |
        v
    Original link becomes unusable

rather than::

    Good
     |
     v
    BAD/DEAD
     |
     v
    Find new route

The latter can create large latency spikes and packet loss.

The desired behavior is essentially **make-before-break**.

----

8. Be careful about aggressively tuning BATMAN-adv
====================================================

Do not immediately respond to the problem by simply increasing BATMAN
routing update frequency or aggressively shortening topology timeouts.

If the underlying RF link is already experiencing::

    20% -> 40% -> 70% -> 90% retransmissions

then making the routing protocol react faster can sometimes make the
overall system worse.

The better order is:

1. Make the PHY/link behavior stable.
2. Obtain meaningful link-quality telemetry.
3. Understand how quickly the link degrades during motion.
4. Then tune routing/path selection around those dynamics.

----

9. The two-node test is fundamentally limited
==============================================

A two-node test can answer:

    How robust is the direct HaLow link under motion?

It cannot answer:

    Can the MANET route around a degrading link?

For the latter, you need at least three nodes.

A useful topology is::

            B
           / \
          /   \
         A─────C

Then move one or more nodes so that the preferred path changes.

Measure whether traffic can transition::

    A -> B

to::

    A -> C -> B

without a major application-level interruption.

----

10. Consider multiple radios if the requirements become demanding
=====================================================================

If the eventual system requires all of:

- long range
- high throughput
- low latency
- rapid mobility
- multipath resilience

then a single RF link may be asked to do too much.

A more robust architecture can use multiple radios or multiple RF
paths.

Conceptually::

                  ┌───────────────┐
                  │     Node A    │
                  │               │
                  │ HaLow radio 1 │──────────► primary mesh
                  │               │
                  │ HaLow radio 2 │──────────► alternate path
                  └───────────────┘

Another possibility is to use one link primarily for robust
control/topology traffic and another for bulk traffic.

This is more complex, but it can provide substantially more
resilience.

----

11. HaLow-specific consideration
=================================

802.11ah/HaLow was designed around long-range, low-power, relatively
low-data-rate machine communications. That does not mean it cannot
support mobility, but its RF behavior should not be assumed to match
conventional high-speed 5 GHz Wi-Fi roaming behavior.

At sub-GHz frequencies, Doppler is actually less severe than at 5 GHz
for the same physical velocity.

In many practical deployments, the bigger issue during motion is likely
to be:

- time-varying multipath
- antenna geometry
- polarization changes
- body/chassis interaction
- fading

rather than Doppler alone.

----

12. Recommended experimental plan
==================================

Test 1 -- stationary baseline
------------------------------

::

    A ───────── B

Measure for several minutes:

- RSSI/SNR
- MCS
- retries
- packet loss
- latency
- UDP throughput
- TCP throughput

Test 2 -- slowly moving
------------------------

Move B at walking speed.

Record the same metrics.

Test 3 -- faster movement
--------------------------

If the deployment is vehicular, test multiple speeds.

Test 4 -- maximum MCS
-----------------------

Compare several MCS ceilings, for example::

    MCS 9
    MCS 7
    MCS 5
    MCS 3

Test 5 -- channel width
-------------------------

Compare::

    8 MHz
    4 MHz
    2 MHz
    1 MHz

Test 6 -- antenna configuration
---------------------------------

Test the actual installed antenna arrangement.

If supported, evaluate antenna diversity/spatial separation.

Test 7 -- three-node mesh
---------------------------

Create::

            B
           / \
          /   \
         A─────C

Then deliberately move nodes so that direct and indirect paths change
in quality.

Measure:

- route changes
- packet loss during transitions
- latency spikes
- throughput during transitions
- time required to converge on a new path

----

13. Suggested target architecture
==================================

A reasonable eventual architecture is::

                      ┌───────────────┐
                      │   Application │
                      └───────┬───────┘
                              │
                        IP / transport
                              │
                      ┌───────▼───────┐
                      │  batman-adv   │
                      │               │
                      │ topology/path │
                      │   selection   │
                      └───────┬───────┘
                              │
                      ┌───────▼───────┐
                      │    IBSS       │
                      └───────┬───────┘
                              │
                      ┌───────▼───────┐
                      │   HaLow PHY   │
                      │               │
                      │ adaptive MCS  │
                      │ robust config │
                      │ good antenna  │
                      └───────────────┘

Ideally, link-quality telemetry should feed into routing decisions, and
the mesh should have enough path redundancy that a degrading link can
be avoided before it becomes completely unusable.

----

14. Most useful next information
=================================

For a more concrete, configuration-level analysis, gather:

- Exact Morse Micro chip/model

  - e.g. MM6108, MM8108, etc.

- Linux/OpenWrt version
- Morse Micro driver version
- HaLow channel width
- Current MCS configuration
- Antenna type and gain
- Approximate node speed
- Approximate node separation
- Whether nodes are vehicle-mounted, handheld, aerial, etc.
- Output of::

      iw dev
      iw dev <halow-interface> link

- BATMAN-adv configuration/output

With those details, the next step can be much more specific: identify
the relevant driver/``iw`` parameters, determine which PHY metrics are
available, and suggest concrete BATMAN-adv parameters and experiments.

----

Bottom line
===========

The most promising approach is:

1. **Instrument the HaLow link first.**
2. **Determine whether motion causes MCS/retry/PHY collapse.**
3. **Experiment with lower MCS ceilings and narrower channel widths.**
4. **Validate the real antenna installation.**
5. **Use three or more nodes to test whether BATMAN-adv can route
   around degrading links.**
6. **Aim for make-before-break path selection rather than waiting for
   links to die.**
7. **Only after understanding the PHY behavior, tune BATMAN-adv.**
8. If requirements are extreme, consider **multiple radios/RF paths**.

The single most valuable next experiment is to correlate **MCS + retry
rate + latency + throughput + RSSI/SNR over time while one node
moves**. That will tell you very quickly whether the root cause is
primarily RF/PHY or the mesh layer.
