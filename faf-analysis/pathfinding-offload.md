# Pathfinding: the offload target, measured

Pathfinding is the largest category-B (AI-advisory, offloadable) chunk
(`parallelization-strategy.md`). This measures its share and lays out how to offload
it deterministically.

## Measurement (fresh M28 4v4, `PROFILE_PATH` sethook timer in `aibrain.lua`)

Pathfinding cost as the game develops — it **scales with unit count**:

| units | GetLabel | PathTo (A*) | DetailedPathTo | CanPathTo | TOTAL* |
|------:|---------:|------------:|---------------:|----------:|-------:|
| 129   | 2.3% | 0.5% | 0.8% | 0.07% | 3.6% |
| 357   | 3.8% | 0.6% | 0.4% | 0.10% | 4.9% |
| 658   | 6.0% | 1.8% | 0.4% | 0.32% | 8.5% |
| 1087  | 7.8% | **13.1%** | 0.4% | 0.63% | 22% |

\* **sethook-inflated upper bound** — the `debug.sethook("cr")` bracket adds overhead to
every nested call, so absolute % is ~3–5× high. Call *counts* are exact. Real
pathfinding is ~2–5% at ~700 units and climbing; at endgame (2–3k units) expect
~5–15% real. Either way it clears the "even 1% is huge" bar with room to spare.

Two components, very different offload stories:

- **`GetLabel` / `GetTerrainLabel`** — navmesh region lookups (`FindLeaf` tree
  descent → `leaf.Label`). By far the **most-called** (558 calls/tick at 1087 units).
  Pure Lua, reads the **static** terrain navmesh. Used **synchronously** (M28 needs
  the connectivity answer *now* to branch), so it's a poor next-tick-offload target —
  but it's a pure function of position over static data, so it **memoizes** cleanly.
- **`PathTo` / `DetailedPathTo`** — full heap **A\*** over `NavSections`. Expensive per
  call (~150–200 µs real) and **grows fastest** with unit count (85→479→901 calls/tick).
  Units already tolerate a tick of path latency, so it **is** next-tick-deferrable —
  the classic offload target, like GTA.
- **`CanPathTo`** — engine C builtin; cheap and infrequent. Hookable but small.

## Engine VAs (FAForever build) — found via the Lua binding table

Lua-C bindings register through a descriptor struct built in code: near the
name-string push, `movl $<cfunc>, <slot+0x14>` stores the C implementation. Script:
`faf-shim/find_lua_binding.py` (pefile). Verified by recovering the **known** GTA address:

| binding | C function VA | note |
|---|---|---|
| `GetThreatAtPosition` | **0x590260** | **matches the old build / `faf_worker` GTA_VA — method validated** |
| `CanBuildStructureAt` | 0x58b3a0 | |
| `CanPathTo` | **0x6cb8e0** | hookable pathfinding entry (same shape as GTA) |

So `CanPathTo` is directly hookable, but it's the *small* part. The big cost
(`GetLabel`, `PathTo`) is **Lua**, so the C-only `faf_worker` hook doesn't reach it.

## Offload plan for `PathTo` (the deterministic, growing target)

The A* reads only (a) the **static navmesh** (`NavGenerator` grids/sections, generated
once at game start, immutable after) and, for threat-aware variants, (b) a threat-map
snapshot (already frozen between ticks — the exact invariant the GTA offload relies on).
So a path result is a pure function of frozen inputs → **deterministic regardless of
which worker computes it**.

Steps:
1. **Export the navmesh to C++ once** after `NavGenerator.Generate()` — grids, sections,
   neighbors, costs, labels. Static, so no per-tick sync. (This is the real work; the
   navmesh currently lives in Lua tables.)
2. **Reimplement A\* in the worker** (`faf_worker.dll`) against the C++ navmesh — a
   fixed-order heap so results are bit-identical run to run.
3. **Batch + defer**: M28's `PathTo` calls enqueue (layer, origin, dest[, threat]) via
   the existing `FAF_OffloadThreatMap`-style API; workers compute; `FAF_PollResult`
   next tick. Synchronous Lua `PathTo` stays as the fallback when the poll isn't ready.
4. **Determinism**: static navmesh + frozen threat snapshot + fixed-order heap →
   identical paths. Not in the sim checksum anyway (advisory), so worst case is a
   one-tick-stale path, which M28 already tolerates.

Ceiling: `PathTo`'s share (~2% now, 5–15% projected at endgame) moved off the sim core
onto idle workers — most valuable exactly when CPU-bound (-5 speed endgames).

## DONE: `GetLabel` memoization — measured result

Implemented in `supcom_run/custom-hook/lua/sim/NavUtils.lua` (schook append wrapping
`GetLabel`, cache keyed on integer ogrids; only permanent results cached, transient
`NotGenerated`/`SystemError` skipped). Measured on a fresh 4v4 M28 game:

- **Per-call cost: ~14 µs → ~4–5 µs** (~3× measured; the ~4 µs residual is mostly
  sethook floor, so the true tree-descent elimination is larger).
- **Gameplay cache hit rate ~94%** (incremental; cumulative 87%+ and climbing —
  cumulative is dragged down by M28's one-time startup map scan, which queries ~40k
  distinct cells once and is inherently 0% cacheable).
- No correctness issues: pathing healthy, units build/move normally, 0 errors.

Cost: the cache grows to ~10^5 cells over a game (bounded by queried map area × 5
layers), a few MB — fine. Note M28's **startup** map scan is all-misses by nature; the
memo helps the **per-tick gameplay** queries (the ones that recur), which is the goal.

## How it works (the memoization)

`GetLabel(layer, pos)` is a pure function over the static terrain navmesh. Cache
`leaf.Label` per navmesh leaf (or per unit, since a unit's region changes rarely) to
collapse the 558 calls/tick of tree descents. This is single-core (reduces total work,
doesn't use extra cores) but is low-effort and attacks the other dominant component.
Terrain labels are static; only `PathTo` must account for dynamic obstacles, so caching
`GetLabel` is safe.

## Recommended order

1. **Memoize `GetLabel`** in `NavUtils`/M28 — smallest effort, immediate single-core win.
2. **Offload `PathTo` A\*** to workers — the multicore win; requires the one-time C++
   navmesh export (the bulk of the effort) then reuses the `faf_worker` queue/poll infra.
3. Skip a `CanPathTo` (0x6cb8e0) hook unless profiling later shows it grew — it's small.

## Tooling added
- `supcom_run/custom-hook/lua/aibrain.lua` — `FafTimePathfinding` (`PROFILE_PATH`), the
  per-function pathfinding sethook timer used above.
- `faf-shim/find_lua_binding.py` — Lua-C binding VA finder (name string → descriptor → cfunc).
