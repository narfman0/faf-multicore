# Test fixtures

Shared, version-controlled inputs for the perf harness so tests are reproducible
across machines without re-simulating. Loading requires the **real FAF environment**
(`faf-analysis/headless-faf-setup.md`): FAForever `.nx2` gamedata + matching
`ForgedAlliance_faf.exe`. A retail-gamedata launch cannot load them.

## `seton4v4-45min-clean.SCFAsave` (~204 MB) — current canonical fixture

4v4 M28AI on SCMP_009 Seton's Clutch, tick **27,000 (45 game-min)**, **~2,331 units**,
captured **after** the combat-fidelity fixes (`headless-faf-setup.md` §"Combat-fidelity
fixes"), so the whole game runs **error-free** (gunship/dodge/onimpact/luascript = 0).
This is the fixture used for `faf-analysis/clean-profile.md`. At ~2.3k units it sits
right at the 10 t/s cap (~100 ms/tick); for a CPU-bound (negative-speed) target use
the 75-min fixture below.

Reload + profile:

```sh
SNAPSHOT=fixtures/seton4v4-45min-clean.SCFAsave SHOWLOG=0 bash faf-shim/profile_snapshot.sh 25
```

## Reaching the CPU-bound (negative-speed) regime

There is **no 75-min fixture**: the 4v4 M28 game **resolves by ~53 game-min** (one
team wiped, `GameEnded` at tick ~33,340), and unit count only declines after the
45-min peak. On a fast box 2.3k units also just sits at the 10 t/s cap. To profile
the CPU-bound regime, force it with the **spawn harness** instead of a longer game —
see `faf-analysis/clean-profile.md` §"CPU-bound confirmation": set `SPAWN_AIR=true`,
`SPAWN_MODE="allied"`, `SPAWN_N=6000` in `aibrain.lua` and raise `Options.UnitCap`
in `singleplayerlaunch.lua` (CreateUnitHPR does NOT bypass the cap). 6k sustained
units → ~450–630 ms/tick (-3 to -5 speed).

The `/savecontinue <name> <beats>` UI hook (`UserSync.lua`) still works to extend a
snapshot to any *reachable* tick (e.g. capture at 50-min before the game resolves) —
reload it and it saves once after N more beats under a new name.

## `seton4v4-30min.SCFAsave` (~198 MB) — superseded

Earlier real-M28 capture, but predates the combat-fidelity fixes, so it carries the
~30k/game error tracebacks (broken Overcharge/tactical damage, M28 dodge/gunship
micro erroring). Kept for A/B mechanics only; **prefer the clean 45-min fixture** for
any profiling.

## Recapturing a fresh game-time

Set `SAVE_TICK` + `FAF_SAVE_NAME` in `supcom_run/custom-hook/lua/aibrain.lua`, launch
`run_skirmish_*.sh`. The save is written by the UI hook in `UserSync.lua` to an
absolute `Z:` path that is **this-box-specific** — edit it when recapturing elsewhere
(loading is portable). `*.SCFAsave` is git-LFS tracked (`.gitattributes`).
