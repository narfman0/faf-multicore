# Clean sim profile — what's slow in a real M28 late-game (2.3k units)

**This supersedes the caveated `perf-results.md` / `air-profiling.md`.** Those
predate (a) M28 actually playing and (b) the discovery that ~30k error tracebacks
per game were rendering through `riched20.dll` **on the sim thread** and dominating
the profile. With M28 playing *and* the combat errors fixed
(`headless-faf-setup.md` §"Combat-fidelity fixes"), this is the first trustworthy
picture.

## Method

- **Fixture:** `fixtures/seton4v4-45min-clean.SCFAsave` — 4v4 M28 on Seton's Clutch,
  tick 27,000 (45 game-min), **2,331 units**, captured with all combat-error fixes
  so the sim runs clean (gunship/dodge/onimpact/luascript = 0 over the whole game).
- **Profile:** `faf-shim/profile_snapshot.sh SHOWLOG=0` — reloads the snapshot into
  the dense state (no re-sim), drops `/showlog`, `perf record -F 499` on the hottest
  (sim) thread for 25 s. Verified error-free during the window (333 log lines total,
  0 combat errors) — so `riched20` is no longer an artifact.

## DSO breakdown (sim thread)

| module | clean | (contaminated, for contrast) |
|---|---|---|
| **ForgedAlliance_faf.exe** (engine sim + Lua VM + M28) | **73.8%** | 59% |
| `[JIT]` | 8.1% | 5.5% |
| `d3d9.dll` (frame rendering — reload still draws) | 7.0% | 4.7% |
| `[unknown]` | 4.0% | 3.5% |
| `riched20.dll` (**log rendering — was the artifact**) | **0.9%** | 17.6% (29% w/ `/showlog`) |
| ntdll / gdi / libc / … | ~5% | ~5% |

Fixing the error spew moved ~17 points from `riched20` into visibility: the engine's
real share is **~74%**. `d3d9`+`JIT` (~15%) is frame rendering that a true dedicated
server wouldn't do — the sim-relevant cost is the 74% engine.

## Key finding — the cost is DISTRIBUTED, there is no hotspot

Engine self-time, top symbols (by DSO-relative offset; names pending symbol map):

- hottest single function = **2.1%** of total
- **top-30 functions = ~19% of total (~26% of engine self-time)**
- the remaining ~74% of engine time is a long tail, each function **< 0.33%**

This is a broad **per-unit / per-entity update** profile, not one hot loop. The sim
steps every unit/projectile/weapon each tick and the cost is spread across hundreds
of small functions.

## Implication for the multicore goal

- There is **no single function to offload** (this is why the narrow `GetThreatAtPosition`
  offload measured a ~nil ceiling — it's one twig in a very broad tree).
- The real lever is **data-parallelism over the per-tick unit-update loop** itself —
  hard, because the sim is single-threaded *deterministic* (lockstep checksum). Any
  parallelization must preserve bit-exact ordering.
- Earlier finding still holds: **combat density** (not raw unit count) drives the
  ms/tick spikes — so the parallelizable work concentrates in the per-projectile /
  per-weapon / collision updates during dense fighting.

## ms/tick at this fixture

~97–105 ms/tick at 2,331 units on reload — i.e. right at the 10 t/s cap (100 ms).
(The original *live* run hit 126–160 ms at 2.9k units in active large battles;
reload at 2.3k sits at the cap. Consistent with combat-density-driven cost.)

## Hot engine functions (names)

Pending the FAForever-exe symbol map (Ghidra headless export → `perf_symbolize.py`).
The old `faf-fa-patches/Info.txt` is for a different build and does not match this exe.
_TODO: fill in once `faf_faf_funcs.txt` is produced._

## Artifacts

- `perf.data`: `/tmp/supcom-logs/perf-1782880240.data` (re-symbolizable anytime)
- profile moho log: `/tmp/supcom-logs/profile-1782880240.log`
