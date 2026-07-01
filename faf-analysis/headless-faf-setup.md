# Headless FAF + M28AI environment — how it's wired (and why)

This documents the working headless launch that makes **M28AI actually play** (build,
fight, scale to thousands of units). It was the missing foundation: every earlier
"M28 4v4" run was **8 idle ACUs** because M28 never activated. Verified working
2026-06-30: `FAF_M28DIAG` shows `M28AI=true` on all brains, and units climb
8 → 40 → 89 → 178 → 261 → 376 over the first ~4 game-minutes.

## The root problem

M28AI is a **FAF** AI. The old setup ran the **retail** Steam gamedata (`lua.scd`,
`units.scd`, `env.scd`) with FAF mods layered on. That is fundamentally inconsistent:
FAF's lua expects FAF's gamedata (`table.combine`, `aibrains/index.lua` + `keyToBrain`,
FAF `simInit`, FAF-normalized blueprints). Mounting FAF lua over retail data produced
a cascade (`table.combine` nil → `categories.ALLUNITS` nil → prop `massValue` string →
`UserData nil` …). The fix is the **complete, self-consistent FAF environment**.

## What you must supply (git-ignored — copyrighted / multi-GB)

1. **FAForever client install** → `FAForever/` (we ship it git-ignored; unzip the
   client's game dir there). Provides:
   - `FAForever/gamedata/*.nx2` — the real FAF gamedata (`lua.nx2` = FAF framework,
     `env.nx2` = FAF-normalized props/blueprints, `units.nx2`, etc.).
   - `FAForever/bin/ForgedAlliance.exe` — the FAF engine that **matches** that lua
     (has engine fns like `SetNavigatorPersonalPosMaxDistance` that older exes lack).
2. **Base FA install** → `supcom_steam/...` (the retail game; `supcom_run/gamedata`
   symlinks to it). FAF `.nx2` override its `.scd`; base supplies the rest.
3. **The matching exe in place**: `cp FAForever/bin/ForgedAlliance.exe supcom_run/bin/ForgedAlliance_faf.exe`
   — launch this, NOT the old `ForgedAlliance.exe` (which is an older FAF build).
4. **M28AI mod** → `supcom_run/vault/mods/m28ai` (→ `M28AI/`).

## The wiring (4 pieces)

### 1. init_faf mounts FAF .nx2 at top priority — `patches/faf-fa-init_faf.lua.patch`
`faf-fa/init_faf.lua` (git-ignored; the patch is tracked) mounts
`FAForever/gamedata/*.nx2` **first** (highest priority) so the FAF framework overrides
the base retail `.scd`, then mounts the base engine lua + our `custom-hook` (`/schook`)
+ base `schook.scd`. Earlier-mounted = higher priority in this VFS.

### 2. Launch with the matching exe
`wine supcom_run/bin/ForgedAlliance_faf.exe /init init_faf.lua /map ... /ai m28ai ...`
(see `faf-shim/run_skirmish_*.sh`; swap the exe name). The `/ai` value must be
**lowercase** `m28ai`.

### 3. M28 activation — `supcom_run/custom-hook/lua/singleplayerlaunch.lua` (tracked)
- `ai = string.lower(ai)` — M28 only activates on lowercase `m28` (`IsM28AIPersonality`).
- `sessionInfo.scenarioMods = { <M28 ModInfo built via doscript> }` — activates the mod
  (sets `__active_mods`, loads M28's CustomAIs_v2 templates). Built by hand because
  `mods.lua`'s `AllMods()` → `DiskFindFiles('/mods',...)` hangs in this headless VFS.
- `Options.Ratings = {}` and `Options.Score = 'no'` — M28 writes `Options.Ratings[nick]`;
  nil there crashes M28's brain-rating setup.

  With the FAF framework present, `/lua/aibrains/index.lua` exists and M28's
  `hook/lua/aibrains/index.lua` registers `keyToBrain['m28ai'] = M28Brain.NewAIBrain`,
  so FAF `simInit`'s `OnCreateArmyBrain` swaps each brain to an M28 brain.

### 4. Headless engine-fn stub — `supcom_run/custom-hook/lua/aibrain.lua` (tracked)
FAF `simInit`'s `BeginSession` calls `CollectCurrentScores`, an engine fn this exe build
lacks → `BeginSession() failed` → the AI never starts. The hook defines a no-op stub
(guarded read, since the sim sandbox throws on undefined globals) so `BeginSession`
completes.

## Run & verify

```sh
cd supcom_run/bin
export WINEPREFIX=$HOME/.wine-supcom XAUTHORITY=$(ls -t /run/user/1000/.mutter-Xwaylandauth.* | head -1) DISPLAY=:0
timeout 300 wine ForgedAlliance_faf.exe /init init_faf.lua \
  /map /maps/SCMP_009/SCMP_009_scenario.lua /ai m28ai /log Z:\\tmp\\m28.log \
  /nobugreport /nosound /nomovie /showlog
# verify: FAF_M28DIAG shows M28AI=true; FAF_UNITS total_units climbs past 8.
grep -E 'FAF_M28DIAG|FAF_UNITS' /tmp/m28.log
```

The `custom-hook/lua/aibrain.lua` beat logger emits `FAF_UNITS: ticks=N total_units=M`
(growing = M28 building) and `FAF_M28DIAG` (per-brain `M28AI`/personality) for
verification. Air-stress / profiler toggles in that file are off by default.

## Combat-fidelity fixes (M28/projectile errors that flooded the sim log)

With M28 actually playing, profiling revealed the sim was throwing ~30k+ error
tracebacks per 45-min game. These aren't real sim cost — each error dumps a Lua
stack trace into the engine log, which renders through `riched20.dll` **on the
sim thread**, so it dominated (~18–29% of) perf profiles and (for the projectile
errors) suppressed combat attrition. Three fixes, all applied here:

1. **M28 DodgeShot/AltDodgeShot** (~52% of sim errors). `M28Overseer` reads
   `(Options.M28DodgeMicro or 1)` and skips initialising the dodge-throttle brain
   fields when it's 1; `M28Micro.DodgeShot` reads it as `== 1` **without** the nil
   default, so a nil option enters the throttle branch and compares never-set
   fields → "call expected but got table" per dodged shot. Fix: set
   `Options.M28DodgeMicro = 1` (and `M28HoverMicro = 1`) in `singleplayerlaunch.lua`
   — matches M28's own default, no mod edit.

2. **Overcharge / Cybran tactical-split projectiles** (~23%). These reach
   `Projectile:DoDamage` with `DamageData.DamageType == nil` in our mounted
   gamedata, so the engine `Damage()`/`DamageArea()` throws and the impact deals
   no damage. Fix: `custom-hook/lua/sim/Projectile.lua` (a schook append) wraps
   `Projectile.DoDamage` to default a nil `DamageType` to `'Normal'`.

3. **M28 `ProjectileFiredAtGunship`** (~95% of *endgame* errors — scales with air
   combat, ~30k/game). Sums incoming projectile damage with fallback `'nil'`
   (a string) instead of `0`, so `number + 'nil'` throws. Fix:
   `patches/m28ai-gunship-damageamount.patch` (M28 is gitignored; apply with
   `git apply`). NB the 25-s reload sample hid this — it only explodes in late-game
   air battles, so always census a **full** clean run before trusting "clean".

Left as documented harmless residuals: `score_mini` `LazyVar` circular-dependency
errors (~300, **UI thread** — not in the sim-thread profile, from our score stub)
and adjacency/veterancy buff-not-found warnings (~1.7k, **front-loaded** during
base-building, ~24 in the endgame profile window).

## Note on the old harness

`ForgedAlliance.exe` (the GTA-offload base/worker exe + `faf_profiler.dll`/`faf_worker.dll`)
is the **older** FAF build and does NOT have the engine fns FAF's current lua needs, so
M28 won't run under it. The `FAF_OffloadThreatMap nonexistent` warning under
`ForgedAlliance_faf.exe` is expected and harmless (the offload DLL isn't injected there).
Re-validating the GTA offload on this newer build is a follow-up if that work resumes.
