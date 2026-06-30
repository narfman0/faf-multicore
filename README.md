# faf-multicore — Supreme Commander: Forged Alliance multi-core AI offload

A native shim DLL (`faf_worker.dll`) injected into `ForgedAlliance.exe` that offloads
AI threat-map queries (`GetThreatAtPosition`) onto dedicated OS worker threads, so
they run concurrently with the single-threaded sim. Plus the reverse-engineering
notes and headless test harness used to build and validate it.

Status (2026-06-29): **the threat offload works and is correctness-validated** —
worker results match the engine's synchronous `GetThreatAtPosition` exactly, in 1v1
**and** 4v4 (24/24 positions across both teams). Not yet wired into M28AI's decision
loop for a real perf measurement.

## What this does (and what it doesn't)

`GetThreatAtPosition` (GTA) is an **AI-brain** function — M28AI and other AI
personalities call it constantly to assess threat. Human players never call it.

- ✅ **Helps AI games** (skirmish / co-op / AI-heavy sessions): GTA can be a large
  share of the AI sim-tick budget, and moving it off the sim thread frees the sim.
- ❌ **Does NOT help human PvP** (e.g. intense air battles). PvP lag is the **sim
  thread itself** — unit movement, weapons, collision, pathfinding — which runs in
  deterministic lockstep for replays/multiplayer and is not touched here. GTA isn't
  in that path.

The `faf_worker.dll` worker-thread infrastructure is reusable for offloading *other*
pure-function AI work (economy projection, build-order scoring, etc. — see
`faf-analysis/faf-worker-design.md`), but the deterministic sim core is a separate,
much harder problem.

## Layout

| Path | What |
|------|------|
| `faf-shim/faf_worker.c` | The offload DLL: worker threads, Lua API (`FAF_OffloadThreatMap`/`FAF_PollResult`), GTA hook, per-army threat-map extraction |
| `faf-shim/faf_profiler.c` | Lighter DLL that just times GTA calls (baseline) |
| `faf-shim/Makefile` | Builds the DLLs with `i686-w64-mingw32-gcc` |
| `faf-shim/inject_import.py` | Adds the DLL to a PE import table |
| `faf-shim/run_skirmish_worker.sh` | Headless M28AI skirmish runner (the test driver) |
| `faf-analysis/faf-worker-design.md` | Design + the full RE story / current status |
| `faf-analysis/lua-va-table.md` | Confirmed engine/LuaPlus function VAs + threat structs |
| `faf-analysis/*.py`, `*.md` | Ghidra/objdump disassembly scripts and notes |
| `supcom_run/custom-hook/lua/aibrain.lua` | Sim-side test harness (offload vs synchronous comparison) |
| `supcom_run/custom-hook/lua/singleplayerlaunch.lua` | Headless all-AI session setup (1v1 / 4v4) |
| `supcom_run/custom-lua/lua/singleplayerlaunch.lua` | math.mod-compatible SinglePlayerLaunch for headless |
| `patches/` | Local patch to FAF's `init_faf.lua` (headless SCD mounts) |

## Requires (not in this repo)

You must supply your **own legally-obtained** game install. None of these are
committed (see `.gitignore`):
- `ForgedAlliance.exe` / `SupremeCommander.exe`, `MohoEngine.dll`, the Steam game
  data (`supcom_steam/`), and the runnable `supcom_run/bin/` + `game/` trees.
- Built artifacts: `faf_worker.dll` / `faf_profiler.dll` (reproduce with `make`).

## Build & run

```sh
# Build the DLL
cd faf-shim && make faf_worker.dll

# Deploy + run a headless M28AI skirmish (see HANDOFF.md for the full environment)
cp faf_worker.dll ../supcom_run/bin/
MAP=SCMP_009 bash run_skirmish_worker.sh        # 4v4 Seton's Clutch; omit MAP for 1v1
# Worker log: /tmp/faf_worker.log ; result: grep FAF_WORKER_TEST in the moho log
```

See **HANDOFF.md** for the exact environment (Wine/Xwayland), the test workflow,
known gotchas, and the open items.
