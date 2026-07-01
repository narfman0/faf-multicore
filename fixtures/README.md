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

## `seton4v4-75min.SCFAsave` — CPU-bound stress fixture

Produced by reloading the 45-min fixture and running it forward 18,000 more beats
(to tick 45,000 / 75 game-min) via the `/savecontinue` UI hook (`UserSync.lua`), so
it captures a much denser late-game that pushes the sim CPU-bound (the -5/-6 game
speed a real endgame hits). Recapture command:

```sh
wine ForgedAlliance_faf.exe /init init_faf.lua /map /maps/SCMP_009/SCMP_009_scenario.lua \
  /loadsave Z:<...>/fixtures/seton4v4-45min-clean.SCFAsave \
  /savecontinue seton4v4-75min 18000 /ai m28ai /log Z:<...> /nobugreport /nosound /nomovie
```

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
