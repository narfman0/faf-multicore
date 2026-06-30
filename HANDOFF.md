# HANDOFF — faf-multicore threat offload

Snapshot for picking this up (2026-06-29). Read `faf-analysis/faf-worker-design.md`
and `faf-analysis/lua-va-table.md` for the deep technical detail; this file is the
operational handoff.

## TL;DR state

- `faf_worker.dll` offloads `GetThreatAtPosition('Overall')` to worker threads.
- **Correctness: DONE.** Worker output == engine synchronous `GetThreatAtPosition`
  exactly. Validated 1v1 (100%) and 4v4 Seton's Clutch (24/24 positions, for
  brains on **both teams** — full per-brain correctness).
- **Not yet done:** wiring M28AI to actually consume offloaded results; measuring
  the real perf gain; ring>0 queries; threat types other than 'Overall';
  determinism audit for replay/multiplayer safety.

## The win, in one paragraph

The Lua sim thread calls `FAF_OffloadThreatMap(army, x,y,z, ...)` → the DLL enqueues
the positions → a worker thread (pinned off the sim core) computes each threat by
calling the engine's own inner functions (`0x715c60` cell lookup, `0x715ff0` threat
sum) on that army's threat map → next tick the sim calls `FAF_PollResult(handle)` to
get the array. 1-tick latency, results identical to synchronous.

## How to build / deploy / test

Environment is a Fedora box running the game under **Wine 11 (staging)** with
**Xwayland**. M28AI is loaded as a mod for an all-AI headless skirmish.

```sh
# 1. Build (needs mingw: i686-w64-mingw32-gcc)
cd faf-shim && make faf_worker.dll
cp faf_worker.dll ../supcom_run/bin/faf_worker.dll

# 2. Run a skirmish (Xwayland auth is REQUIRED, see gotchas)
export XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.*   # the live cookie
export DISPLAY=:0
MAP=SCMP_009 bash faf-shim/run_skirmish_worker.sh 360      # 4v4; omit MAP=>1v1 (SCMP_007)

# 3. Read results
cat /tmp/faf_worker.log                                    # DLL: attach, hooks, cache_tmap
grep FAF_WORKER_TEST /tmp/supcom-logs/supcom-worker-skirmish-*.log   # test harness output
```

The test harness (`supcom_run/custom-hook/lua/aibrain.lua`) runs ~45s after session
start, offloads ACU + grid positions **from multiple brains**, and logs
`FAF_WORKER_TEST: army N RESULT match=X mismatch=Y`. Expect `mismatch=0` for all.

## Key technical facts (so you don't re-derive them)

- **GTA hook**: inline hook at `0x590260`. On first call it registers the Lua API and
  captures the AIBrain via a second "armed" hook on `0x5930d0` (the engine's RTTI
  downcast that extracts GTA's `self`). See `hook_x5930d0` / `cache_tmap_from_aibrain`.
- **Threat map per brain**: `aibrain+0x34` = threat sub-object; `sub_obj->vtable[6]`
  (offset `0x18`, thiscall) returns the current threat map.
- **`0x715ff0` is STDCALL** (`ret 0x18`) — do NOT clean the stack after calling it.
- **'Overall' = sum all armies**: the per-cell fn `0x715750` stores threat per-army
  (56-byte entries); pass `army = -1` to sum all (what the engine default does).
  `army >= 0` reads one army's slice (was the multi-brain bug).
- **Per-brain map keying**: engine global army list at `*(aibrain+0xa4)`, bounds at
  `+0x910`/`+0x914`, element[i] = army i's threat sub-object. `tmap_for_army(army)`
  selects the caller's map. (faf_worker.c: `army_object`, `tmap_for_army`.)
- **Threat-type enum** matches FA's `BrainThreatType` alias order: 0=Overall,
  11=AntiSurface, 13=Economy (confirmed by a live index sweep).

## Gotchas (will waste your time otherwise)

- **Xwayland auth**: without `XAUTHORITY` pointing at the live mutter cookie, the
  game dies with `xcb_connection_has_error`. The cookie name rotates per session.
- **Flaky load**: ~1 in 3 launches hangs early at ~56 moho-log lines (loading
  `cheatbuffs.lua`). Not a code bug — kill the wine procs and relaunch.
- **FA sim Lua (5.0/LuaPlus)**: NO `_G` in the sandbox; NO bare `...` varargs (a
  `...` is a compile error that silently kills the whole session); `Class` objects
  are sealed (subclass, don't assign fields); threads `ForkThread`'d at module
  import are discarded — start test threads at chunk end (sim is already live then).
- **Get non-zero threat for validation**: own units don't register as threat to
  self and `AssignThreatAtPosition` doesn't stick into 'Overall'; query the **enemy
  ACU** positions (fog is off via the headless session options).

## Open items / suggested next steps

1. **Measure the perf gain.** Use `faf_profiler.dll` (times GTA calls) to get the
   synchronous baseline (per-call µs × calls/tick), then compare with offload on.
   Quantify the sim-tick budget freed. This is the "is it worth shipping?" number.
2. **Wire M28AI to consume offloaded results** (the determinism-sensitive step).
   Replace hot synchronous GTA loops in M28 with `FAF_OffloadThreatMap` + a
   next-tick `FAF_PollResult`, with synchronous fallback when poll returns nil.
3. **Determinism audit** (gap #5 in the design doc) — required before any
   replay/multiplayer use. The offload must produce bit-identical decisions or be
   strictly observer-only.
4. **Generalize**: ring>0 queries (worker only does ring 0); threat types beyond
   'Overall' (parameterize `query_threat_at`/`FAF_OffloadThreatMap`).
5. **Scope reminder**: this is an AI-game optimization (GTA is AI-only). It does not
   help human PvP. See README "What this does".

## Source of truth / repo notes

- Live working copy doubles as the repo (this directory). Game binaries, the Steam
  install, `supcom_run/bin/`, `game/`, and built DLLs are **git-ignored** — supply
  your own and `make` the DLL.
- `faf-fa/` and `M28AI/` are upstream FAForever repos (their own git); not included.
  The one needed FAF change (headless SCD mounts) is in `patches/`.
