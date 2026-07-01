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

## CPU-bound confirmation (spawn stress, 6k units)

The 45-min fixture sits at the 10 t/s cap (0 speed) on this 24-core box — 2.3k units
isn't enough to go CPU-bound here (fast per-core). The natural game can't push
further: the 4v4 M28 game **resolves by ~53 game-min** (one team wiped, `GameEnded`
at tick ~33,340), and unit count only *declines* after the 45-min peak. So to reach
the negative-speed regime we force it with the spawn harness (`SPAWN_AIR`, `aibrain.lua`).

Gotchas found: `CreateUnitHPR` does **not** bypass `Options.UnitCap` in this build
(over-cap units are culled — 2 armies × 500 ≈ 1k regardless of how many you spawn),
and opposing units spawned 1 apart annihilate instantly. Use **allied** mode (same
team, no mutual combat → sustained count) with `UnitCap` raised.

Result — **6,016 sustained units (allied idle interceptors): 453 → 626 ms/tick**
(~2.2 → 1.6 t/s, i.e. -3 to -5 game speed), error-free. DSO: 68% engine, ~19%
render (`d3d9`+`JIT`+unknown), `riched20` = 0.

**The distributed shape holds under CPU-bound load.** Hottest single function =
**1.80%** (`0x52941c` — the *same* top address as the 45-min mixed-army profile),
top-30 = 17.2% of samples. No hotspot emerges at -5 speed. The cost is per-unit
update work smeared across hundreds of functions, whether the units are a real
mixed army (45-min) or 6k idle interceptors.

## Hot engine functions (from disassembly)

Ghidra headless never completed on this 8.5 MB-code exe (decompiler wouldn't honor
the analysis timeout). Disassembling the top hot addresses directly (VA = 0x400000 +
perf offset) shows they are **generic low-level primitives**, not a subsystem:

- `0x527461` (#2, ~1.3%): bounds-checked **array element accessor** —
  `cmp size@[esi+0x20]; mov base@[esi+0x10]; lea base+idx*8` (8-byte elements).
- `0x52941c` (#1, ~1.8%): a small **collection-iteration** loop invoking a
  per-element callback (`call 0x929bf0`) under a condition check.
- `0x6a84d8`: a **float-math helper** (NaN/inf classify via `and 0x7ff0`, `fldcw`).

That the hot functions are container indexing / iteration / float math — called by
every per-unit update path — is *why* the profile is flat. There is no high-level
subsystem to offload; the cost is in the primitives underlying all per-unit work.
A denser symbol map (were Ghidra to finish) would name the mid-tail callers, but the
conclusion doesn't depend on it.

## Artifacts

- `perf.data`: `/tmp/supcom-logs/perf-1782880240.data` (re-symbolizable anytime)
- profile moho log: `/tmp/supcom-logs/profile-1782880240.log`
