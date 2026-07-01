# Parallelizing the sim: which chunks split off deterministically, and how

The profile says the cost is broad per-unit work with no hotspot (`clean-profile.md`).
That does *not* mean it can't be parallelized — it means the unit of parallelism is
the **per-unit update itself**, split across cores, not any single function. This doc
works out which data paths split cleanly, the determinism technique for each, and
what is actually reachable given we cannot recompile the closed engine.

## The load splits into two categories with very different rules

| | **A. Deterministic sim core** | **B. AI-advisory layer** |
|---|---|---|
| Examples | unit motion, collision, damage, projectiles, health, `SimSync` checksum | threat/influence maps, target scoring, pathfinding, M28 decisions |
| In the checksum? | **Yes** — must be bit-identical on every client (lockstep) | **No** — advisory; wrong-but-deterministic only changes a *decision* |
| Where it runs | engine C++ (no source) | engine C++ + Lua (M28 mod is ours) |
| Share of cost | **dominant** (measured) | smaller |
| Parallelizable from a DLL? | **no** (can't restructure `SimBeat`) | **yes** (proven by the GTA offload) |

The decisive measurement: `0x52941c` is the #1 hot address in **both** the real
2.3k-unit M28 game **and** the 6k idle-interceptor stress (units M28 never touched).
So the dominant cost is category-A native per-unit update, present with or without the
AI. Category B (what `faf_worker` offloads) is the smaller slice — which is exactly
why the `GetThreatAtPosition` offload measured a ~nil throughput ceiling.

## The determinism toolkit (how a chunk is "made deterministic")

Parallelism desyncs a lockstep sim in three ways; each has a standard fix:

1. **Read-write races** → **double-buffer / phase split.** Read frame N (immutable),
   write frame N+1 into a separate buffer, swap at the barrier. Within a phase every
   task reads a frozen snapshot and writes only its own slot → order-independent →
   identical regardless of thread scheduling. This is how the GTA offload is already
   safe: workers read the threat map the sim froze *between* ticks.
2. **Float non-associativity** (`a+b+c ≠ c+b+a` in IEEE) → **deterministic reduction.**
   When N tasks accumulate onto one target (damage to a unit, threat into a cell),
   don't add in thread-completion order — collect contributions and apply in a fixed
   key order (source entity id), or accumulate in fixed-point. Same bits every run.
3. **Order-dependent mutation** (spawning units, issuing orders, list appends) →
   **deferred command queue.** Parallel tasks emit commands into per-thread buffers;
   after the barrier, merge and apply serially in a deterministic key order.

Plus **spatial partitioning** for interactions: bucket entities into map cells, one
task per cell for the broad phase; resolve cross-cell pairs in a serial boundary pass
ordered by pair id.

## Per-subsystem data-path analysis (category A)

Ordered easiest → hardest to split deterministically:

1. **Motion / physics integration** (`pos += vel·dt`, turn toward heading).
   Embarrassingly parallel: each unit reads only its own state, writes only its own
   next transform. No cross-unit dependency (collision is a separate phase).
   Determinism: trivial (independent). *Ceiling: high — this is pure per-unit work.*
2. **Sensor / intel grids** (each unit stamps vision/radar into shared grids).
   Parallel read of unit transforms; grid write is a reduction. Vision/radar booleans
   compose order-independently (OR / max); analog threat needs deterministic-reduction.
   The read side is literally what the threat-map offload already does.
3. **Target acquisition** (each weapon scans for a target). Parallel spatial read of
   enemy transforms; each weapon picks independently. Determinism: deterministic
   tiebreak (closest, ties broken by entity id). No mutation until fire.
4. **Weapon firing / projectile creation.** Parallel decision, but creating a
   projectile appends to a shared list → deferred-command queue, applied in firing-
   unit-id order after the barrier.
5. **Collision + damage.** Broad phase parallel via spatial buckets; narrow phase per
   candidate pair. Damage is a reduction: collect (target, source, amount) events,
   sort by (target id, source id, sub-tick order), apply serially → bit-exact. The
   hardest phase because it mixes spatial parallelism with ordered reduction.
6. **Unit Lua scripts** (state machines, effects) mutate unit state → double-buffer or
   deferred; **M28 AI** is category B (advisory) and can go fully async.

Every one of these has a known deterministic-parallel form — the pattern is standard
in engines *designed* for it. The blocker is not the math; it's the engine.

## The wall: no engine source

FAF is a **binary patch** of the retail `ForgedAlliance.exe` plus gamedata — the C++
sim engine source is not available. From a DLL we can *hook individual functions*
(push/ret trampoline, as `faf_worker` does to `GetThreatAtPosition`), but we cannot
restructure the serial `SimBeat` loop into read/write phases. So category-A
parallelization — the dominant cost — is **not reachable from a mod**, however clean
the data paths are. It would require either engine source or a from-scratch
deterministic-parallel reimplementation of the sim (out of scope for this project).

Caveat worth verifying: the engine already runs an **8-thread `CTaskThread` pool**
(referenced in `faf_worker.c`). What it currently offloads (rendering? async
pathfinding?) is unknown; if pathfinding already uses it, that lever is spent.

## What *is* reachable now (category B), and the next concrete step

The `faf_worker` pattern works for any computation that (a) reads sim state read-only,
(b) is consumed next tick, (c) isn't in the checksum. Ranked candidates:

1. **Pathfinding requests** — likely the single largest hookable AI-advisory chunk.
   Per-request, pure over a read-only nav grid, deterministic given identical inputs,
   naturally next-tick-consumable (units already tolerate a tick of path latency).
   **Next step: identify the engine pathfind entry (like GTA's `0x590260`), measure
   its share, and if it's not already on the `CTaskThread` pool, offload a batch of
   requests per tick.**
2. **Full threat/influence maps** — extend the existing offload beyond `'Overall'`
   ring-0 to all threat types / rings (already scoped in `HANDOFF.md`).
3. **Target pre-scoring & M28 per-tick analysis** — M28 is our Lua; its threat/build/
   platoon scoring can move to workers via the offload API with deterministic results.

**Honest ceiling:** category B is the smaller slice, so even a perfect AI offload
yields a bounded win — meaningful specifically in CPU-bound endgames (where shaving
the AI's share buys back tick budget), negligible otherwise (matching the GTA result).
The dominant per-unit engine cost stays serial until/unless engine source exists.

## TL;DR

- Yes, the per-unit work *can* be split into deterministic chunks — motion, sensors,
  targeting, collision/damage each have a standard deterministic-parallel form
  (double-buffer, deterministic reduction, deferred commands).
- But those chunks live in the **closed engine core**; a DLL can hook functions, not
  re-phase the loop. So the dominant cost is a wall without engine source.
- The reachable win is **category-B AI offload** (pathfinding next), bounded but real
  for CPU-bound endgames. That is where to spend effort on the retail engine.
