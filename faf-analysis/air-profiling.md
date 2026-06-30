> **CAVEAT (2026-06-30):** results below predate the discovery that **M28 never
> actually played** in the old setup (8 idle ACUs) — see `headless-faf-setup.md`.
> Methods/tooling are sound; M28-behaviour conclusions need redoing on the now-working
> FAF env. Spawn-harness (real spawned units) results still hold.

# Air-battle profiling — what's slow at high unit counts

Goal: find what makes the sim slow in large endgame battles (2k–5k units), especially
air. The GTA offload work (`perf-results.md`) showed the offload is the wrong lever;
the real cost is in the deterministic sim thread, which air spam stresses.

## Workload — scalable air-spawn harness (reproduces the lag on demand)

`supcom_run/custom-hook/lua/aibrain.lua` (gated by `SPAWN_AIR`, count `SPAWN_N`)
spawns N T1 interceptors (`uea0102`) split between two opposing armies, overlapping
near map center so their AA weapons engage immediately. `CreateUnitHPR` bypasses the
unit cap; the spawn is batched to avoid a one-tick hitch.

**Result:** **2,000 interceptors froze the sim** — tick rate **10/s → ~0**, one core
pegged at **94%**. So the 2k–5k regime is deeply CPU-bound on this hardware/map, and
we can study it deterministically at any N. (This also confirms the 30-min M28
snapshot, which held 10 t/s, had far fewer effective combat units than 2k.)

## Method 1 — `perf` flamegraph (native, the TIME picture)

`ForgedAlliance(_base).exe` is ASLR-off at fixed base `0x400000`, and perf reports
DSO-relative offsets, so **VA = perf_offset + 0x400000**, mapping 1:1 to
`faf-fa-patches/Info.txt`. Tool: `faf-shim/perf_symbolize.py`.

Workflow: launch the air-stress run, find the busy sim thread
(`ps -eLo tid,pcpu,comm --sort=-pcpu | grep ForgedAlliance`), then
`perf record -F 999 --call-graph fp -t <tid> -o perf.data -- sleep 20`, then
`perf report ... --dsos=ForgedAlliance_base.exe --sort=symbol | perf_symbolize.py`.

**Result (20s at peak, 2k units):** engine exe = **64% self-time**. Trustworthy hot
symbols (small offset from a named entry): `CreateHashStr` (3.6% — **category/string
hashing**, e.g. collision category checks), `free` (2.9% — allocation churn),
`luaF_newCclosure` / `luaH_getstr` / `luaM_realloc` (**Lua VM**). ~6% `d3d9` is
rendering noise (the "headless" run still draws frames — suppressing it would clean
the profile). **Limitation:** `Info.txt` names only ~150 functions, so ~60% of engine
samples land in unnamed code — a denser symbol export (Ghidra) would close that gap.

## Method 2 — `debug.sethook` call-count profiler (Lua call-frequency)

FAF's `lua/sim/Profiler.lua` isn't in our retail+m28ai VFS, so `FafEnableProfiler`
in `aibrain.lua` installs `debug.sethook(_, "c")` itself over a tick window and logs
the top callers. sethook turned out to be **effectively global** here (it caught all
of M28's calls, not just our thread).

**Result (600 units + 8 M28 brains, 40 ticks) — dominated by M28 AI, not combat:**
`next` 47k, `table.insert` 9.7k, `VDist2` 5.4k, `GetThreatAtPosition` 5.2k,
`CanBuildStructureAt` 4.3k, `brainconditionsmonitor:CheckCondition` 1.5k,
`builder`/`buildermanager`/`platoonformmanager` logic. The collision/impact/death
callbacks (`OnCollisionCheck`/`OnImpact`/`OnKilled`) **barely register**.

## Synthesis

Two distinct cost centers — the "Lua collision-callback multiplication" theory is
**not** supported here:
1. **C++ engine = the TIME sink** (perf): collision + category string-hashing +
   Lua-VM/allocation churn. Per-projectile combat work; native.
2. **M28 AI Lua = the call-VOLUME sink** (sethook): per-tick threat/build/condition/
   platoon/economy management that scales with unit count.

## Method 3 — combat-isolation control (the decisive experiment)

Using `GetSystemTimeSecondsOnlyForProfileUse()` in the beat logger gives real
ms/tick directly. Two runs at **1000 units (500 per M28 brain)**, same map/spawn:
- **opposing** (group2 = enemy team → they fight)
- **allied** (group2 = friendly team-1 brain → no combat), identical M28 management.

ms/tick from the `rt` timeline:

| ticks | opposing (combat) | allied (no combat) |
|-------|-------------------|--------------------|
| 20→40 | ~100 (baseline) | ~100 |
| 40→60 | **389** | **380** |
| 60→80 | 419 | 378 |
| 80→100 | 334 | 331 |

At the matched-unit-count window (40→60, both ~1000 units alive): **389 vs 380 ms/tick
— combat adds ~2%.** **Air combat is not the bottleneck.** The 4× slowdown
(100→~400 ms/tick) comes from **unit count itself**: per-unit engine updates +
M28 AI managing them, whether or not they fight.

### Reconciling with perf

This explains perf's hot `CreateHashStr` (category/string hashing): it's **M28's
category operations** (`CanBuildStructureAt`, `ParseEntityCategory`, threat/build
queries — all high in the sethook counts), **not** combat collision. Unified
picture: the cost is **M28 AI per-tick work that scales with unit count**, plus
baseline per-unit engine update — combat/collision is minor.

## Open / next

- **Combat ruled out** (Method 3). The remaining split is **M28 AI vs engine
  per-unit update**. Attempted via a neutral-army spawn, but **this skirmish has no
  civilian/non-M28 army** (all 8 are M28; `FAF_ARMY` probe → `civilian=false` for
  every index), so that route aborts. Baseline confirmed at **96 ms/tick** (8 ACUs,
  normal M28 eco). To finish the split, give one army a **non-AI / blank brain** in
  `singleplayerlaunch.lua` and spawn the 1000 units there → ms/tick = engine
  per-unit only; the gap to the M28-managed run = M28's AI cost. Pending.
- **Strong indirect evidence M28 dominates the per-unit cost** even without the clean
  split: perf's #1 hot symbol `CreateHashStr` is M28's category hashing
  (`CanBuildStructureAt`/`ParseEntityCategory`), and the sethook call-counts are
  almost entirely M28 AI. So the optimization target is **M28's per-tick work**.
- **M28's own wall-time profiler** (`M28RunProfiling`) records data but its output
  thread (`ProfilerActualTimePerTick`) doesn't run in our headless/schook context
  (a path-normalized import failure + M28's cyclic, not per-tick, recording). Parked
  in favor of the control experiment above.
- **Densify symbols** (Ghidra export) to attribute perf's unnamed ~60%, and/or add
  **QPC hooks** (extend `faf_profiler.dll`) on `SimBeat 0x749F40` +
  `Projectile::CheckCollision 0x69D1D0` for ground-truth C++ timing.
- **Suppress rendering** for a cleaner sim-only profile.

## Tooling added

- `faf-shim/perf_symbolize.py` — perf-offset → Info.txt function mapper.
- `supcom_run/custom-hook/lua/aibrain.lua` — `SPAWN_AIR`/`SPAWN_N` air-spawn harness
  + `FafEnableProfiler` (self-hook call-count) + `FafTotalUnits` counter.
