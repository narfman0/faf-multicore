# Patches to upstream FAForever `fa`

`faf-fa-init_faf.lua.patch` — adds headless SCD mounts to `init_faf.lua` so the game
runs without NX2 files (mounts mohodata/moholua/lua/schook from the Steam gamedata
SCDs, plus our `custom-lua` and `custom-hook` overlays). Apply inside an `fa` checkout:

    git -C /path/to/fa apply /path/to/patches/faf-fa-init_faf.lua.patch

(The `lua/aibrain.lua` change in the same working tree is superseded by
`supcom_run/custom-hook/lua/aibrain.lua` — the schook overlay is the canonical test hook.)
