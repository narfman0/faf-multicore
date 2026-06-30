# Test fixtures

Shared, version-controlled inputs for the perf harness so tests are reproducible
across machines without re-simulating.

## `seton4v4-30min.SCFAsave` (~50 MB)

A headless Supreme Commander: Forged Alliance save of a **4v4 M28AI skirmish on
SCMP_009 Seton's Clutch**, captured at **sim tick 18300 (~30 game-minutes)** on
2026-06-30. This is the heavy late-game state used for the realized-gain A/B
(`faf-analysis/perf-results.md`, Phase 2) — load it instead of paying ~30 min of
re-simulation per run.

**Validated:** reloads cleanly and M28AI resumes (119k GTA calls + advancing beats
after load, no serialization errors).

### How to use

```sh
# A/B the offload from this snapshot (no re-sim; identical state under both exes)
SNAPSHOT=fixtures/seton4v4-30min.SCFAsave EXE=base   RUNS=5 bash faf-shim/bench_throughput.sh 240
SNAPSHOT=fixtures/seton4v4-30min.SCFAsave EXE=worker RUNS=5 bash faf-shim/bench_throughput.sh 240
```

`bench_throughput.sh` derives the in-game `Z:` path from this file with `readlink -f`,
so loading is **portable** — it works regardless of where the repo is checked out.

### Compatibility — must match to load

A save embeds references to the exact game build and mounted mods. To reload:

- **Game version 3836** (`faf`) — the build this was captured on.
- **M28AI mod** mounted (the repo's `init_faf.lua` mounts it for the headless run).
- Same game data (`supcom_steam/.../gamedata`) mounted as in the capture.

If the game or M28AI version differs, the save may fail to load or behave oddly —
recapture instead (below).

### Recapturing (e.g. a different game-time or scenario)

Set `SAVE_TICK` (and `FAF_SAVE_NAME`) in `supcom_run/custom-hook/lua/aibrain.lua`,
then run `MAP=<map> bash faf-shim/run_skirmish_profiler.sh <timeout>`. The save is
written by the UI hook in `supcom_run/custom-hook/lua/UserSync.lua` — note its
target path is an absolute `Z:` path that is **this-box-specific**; edit it when
recapturing on another machine (loading does not need this).

### Note on size

This is a ~50 MB binary committed to git. If the fixtures set grows, consider moving
`*.SCFAsave` to **git-LFS** to keep the main history lean.
