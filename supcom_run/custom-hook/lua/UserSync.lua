# Hook (schook append): add a mid-game save trigger to the UI OnSync chain.
# OnSync is the per-beat UI callback; the engine binds it at UserSync load, so the
# wrap MUST happen here (a later gamemain wrap is too late — the engine keeps the
# reference it captured). When the sim sets Sync.FafSaveRequest (see aibrain.lua),
# call InternalSaveGame once to serialize the live session for reload-based A/B.
#
# NOTE: this replaces schook.scd's UserSync.lua at the same VFS path (only one can
# win the search). Headless benchmarking does not need schook's camera/objectives
# UI handling, so chaining only to the stock OnSync is fine. The "loaded" marker
# below confirms our file won the path.

LOG("FAF_SAVE(UI): UserSync hook loaded (custom-hook)")

-- Only honor a save request when this is a FRESH capture, not a reload. Otherwise
-- every /loadsave A/B run would re-hit SAVE_TICK and overwrite (and slowly drift)
-- the snapshot. /loadsave present => loaded session => never save.
local okLoad, fafLoadArg = pcall(GetCommandLineArg, "/loadsave", 1)
local fafIsLoad = (okLoad and fafLoadArg and fafLoadArg[1]) and true or false
LOG("FAF_SAVE(UI): isLoad=" .. tostring(fafIsLoad) .. " (save " ..
    (fafIsLoad and "DISABLED" or "armed") .. ")")

local fafBase = OnSync
local fafFired = false
local fafBeats = 0
OnSync = function()
    fafBase()
    fafBeats = fafBeats + 1
    local req = rawget(Sync, "FafSaveRequest")
    if math.mod(fafBeats, 100) == 0 then
        LOG("FAF_SAVE(UI): OnSync alive beats=" .. fafBeats .. " req=" .. tostring(req))
    end
    if req and not fafFired and not fafIsLoad then
        fafFired = true
        -- Recapture target: the tracked fixtures dir. NB this absolute Z: path is
        -- this-box-specific; loading is portable (bench_throughput.sh derives the
        -- path), but recapturing on another machine needs this edited.
        local path = "Z:\\home\\narfman0\\.openclaw\\workspace\\faf\\fixtures\\" ..
            tostring(req) .. ".SCFAsave"
        LOG("FAF_SAVE(UI): request seen path=" .. path ..
            " InternalSaveGame=" .. tostring(InternalSaveGame))
        local ok, err = pcall(function()
            InternalSaveGame(path, tostring(req), function(worked, errmsg)
                LOG("FAF_SAVE(UI): oncompletion worked=" .. tostring(worked) ..
                    " err=" .. tostring(errmsg))
            end)
        end)
        LOG("FAF_SAVE(UI): call ok=" .. tostring(ok) .. " err=" .. tostring(err))
    end
end
