# Performance results — threat offload

Quantifies HANDOFF.md "Open items" #1. **Phased:** Phase 1 measures the *ceiling*
(how much sim-tick budget GTA costs — what offload could free); Phase 2 measures the
*realized* gain (actual sim throughput once M28AI consumes the offload). Benchmark
workload: **SCMP_009 Seton's Clutch, 4v4 M28AI (8 brains)** — the heaviest AI load,
so GTA volume and any gain show up most clearly.

Methodology and tooling: `faf-shim/run_skirmish_profiler.sh` (Phase 1, prints a
`=== Ceiling metrics ===` block) and `faf-shim/bench_throughput.sh` (Phase 2, A/B
beats/sec). Run each 2–3× (Phase 1) / 5×+ (Phase 2) and report the median/mean to
absorb the known ~1-in-3 flaky load.

---

## Phase 1 — Opportunity ceiling (no AI changes)

`MAP=SCMP_009 bash faf-shim/run_skirmish_profiler.sh 360`

| run | dur      | total GTA calls | total beats | avg µs | late avg µs | max µs | calls/tick | GTA µs/tick | ms/beat | GTA % of tick |
|-----|----------|-----------------|-------------|--------|-------------|--------|------------|-------------|---------|---------------|
| 1   | 5 game-min | 257,232       | 2,900       | 0.57   | —           | 66.8   | 88.7       | 50.8        | 103     | 0.05%         |
| 2   | **30 game-min** | **1,655,040** | **18,300** | 0.574 | **0.590** (last 300k) | — | **90.4** | **53.4** | **~100** | **0.053%** |

(Run 2 = the snapshot-capture run; "late avg µs" = mean over the final 300k calls,
i.e. the 30-min-mark workload, not the cheap early game.)

**Measured GTA % of tick: ~0.05%, flat from 5 to 30 game-min** (≈53 µs of GTA work
per 100 ms tick).

### Interpretation — the answer (no longer inconclusive)

The earlier 5-min run was inconclusive because the box wasn't CPU-bound. The 30-min
run on the heaviest standard load (4v4 Seton's, 8 M28 brains) resolves it:

1. **GTA stays cheap into late game.** Per-call cost barely moved (0.574 → 0.590 µs
   in the last 300k calls) and call volume per tick was flat (88.7 → 90.4). The
   "late-game gets heavy" hypothesis did not hold for GTA('Overall', ring 0).
2. **The sim never became CPU-bound.** It held **exactly 10 ticks/s (ms/beat ≈ 100)
   for all 30 minutes** — every 300 s window advanced +3000 ticks. The sim has ample
   headroom on this hardware; it is *not* the bottleneck, so there is **no throughput
   deficit to reclaim**. A non-lagging sim is capped at 10 t/s regardless of how much
   GTA you offload — freeing 53 µs/tick out of a 100 ms tick changes nothing.

**Gate: ≳5–10% → proceed; <~2% → stop. Decision: STOP for throughput on this
hardware.** At ~0.05% and a never-lagging sim, the GTA offload yields no measurable
sim speedup here. Phase 2 (realized A/B) on this box would read ~0% by construction.

**Where it could still matter (and how to check cheaply now):** the offload only pays
off when the sim is genuinely CPU-bound (ms/beat > 100 — the game dropping below 1×).
We never hit that on this machine even at 30 min. The value case is **weaker hardware
or heavier-than-4v4 states**. The captured snapshot (`fixtures/seton4v4-30min.SCFAsave`,
30 game-min) makes that test cheap: load it on a slower box / bigger scenario and
re-measure ms/beat — if it exceeds 100, the offload has something to reclaim and the
Phase 2 A/B becomes meaningful. Also note this counts only ring 0 'Overall'; ring>0
and other threat types are uncounted, but they'd have to be ~100× heavier to matter.

---

## Phase 2 — Realized end-to-end gain (after M28 wiring)

Two prerequisites: (a) HANDOFF.md "Open items" #2 — M28AI must actually consume the
offload; (b) a CPU-bound baseline (ms/beat > 100) — otherwise the sim is already at
its 10 t/s cap and any speedup is structurally ~0 (see Phase 1 decision). On this
hardware (b) does not hold even at 30 game-min, so Phase 2 here is expected ~0%.

Run from the **captured 30-min snapshot** (no re-sim, identical state under both
exes):

`SNAPSHOT=fixtures/seton4v4-30min.SCFAsave EXE=base   RUNS=5 bash faf-shim/bench_throughput.sh 240`
`SNAPSHOT=fixtures/seton4v4-30min.SCFAsave EXE=worker RUNS=5 bash faf-shim/bench_throughput.sh 240`

(beats/sec = elapsed ticks `last-first`, since a loaded session starts at ~tick 18000.)

| arm                | exe                        | n | beats/sec mean | stdev | rel % |
|--------------------|----------------------------|---|----------------|-------|-------|
| baseline (off)     | ForgedAlliance.exe         | _ | _TBD_          | _TBD_ | _TBD_ |
| treatment (on)     | ForgedAlliance_worker.exe  | _ | _TBD_          | _TBD_ | _TBD_ |

**Speedup:** _TBD_ %  •  **Noise floor (baseline-vs-baseline):** _TBD_ %
**Determinism:** `FAF_WORKER_TEST mismatch=0`? _TBD_  •  checksum mismatches? _TBD_

---

## Snapshot capture (for cheap, repeatable late-game A/B)

`fixtures/seton4v4-30min.SCFAsave` (51.5 MB) — 4v4 Seton's at **30 game-min (tick
18300)**, captured 2026-06-30. Reloads cleanly; **M28AI resumes** (validated: 119k
GTA calls + advancing beats after load, no serialization errors).

Mechanism (all in `supcom_run/custom-hook/lua/`):
- `aibrain.lua` — at `SAVE_TICK` the sim sets `Sync.FafSaveRequest` (sim→UI bridge).
- `UserSync.lua` — UI `OnSync` hook calls `InternalSaveGame` (UI-only API; disabled
  on `/loadsave` runs so repeated A/B loads don't drift the snapshot).
- `singleplayerlaunch.lua` — `/loadsave <winpath>` branch → `LoadSavedGame`.

To recapture at a different game-time, set `SAVE_TICK` in `aibrain.lua` and rerun
`MAP=SCMP_009 bash faf-shim/run_skirmish_profiler.sh <timeout>`.

## Notes / observations

- Sim held a rock-steady 10 ticks/s for the entire 30 min — strong evidence the box
  is not sim-CPU-bound on 4v4 Seton's at any point measured.
- Sim sandbox is strict: reading an undefined global *throws* (killed an early probe).
  Save/load are UI-state only — hence the Sync-bridge design above.
- The profiler build (`ForgedAlliance.exe`) logs one expected warning on reload —
  `FAF_OffloadThreatMap nonexistent` — because the offload API only exists in the
  worker exe. Harmless; the comparison harness falls back to synchronous.
