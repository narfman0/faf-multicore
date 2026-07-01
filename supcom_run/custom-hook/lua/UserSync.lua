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

-- Reload-continue save: load a snapshot, run it forward, and save ONCE after N
-- more beats under a NEW name. /savecontinue <name> <afterBeats>. The sim code in
-- a reload is frozen (so SAVE_TICK/name are baked into the save), but this UI hook
-- runs fresh on load, so it drives the extra save from here. Used to grow the
-- 45-min snapshot into a denser late-game (reload -> run to 75-min -> save bigger
-- fixture) that actually pushes the sim CPU-bound (negative game speed).
local okCont, fafContArg = pcall(GetCommandLineArg, "/savecontinue", 2)
local fafContName  = (okCont and fafContArg and fafContArg[1]) or nil
local fafContBeats = (okCont and fafContArg and fafContArg[2]) and tonumber(fafContArg[2]) or nil
LOG("FAF_SAVE(UI): savecontinue name=" .. tostring(fafContName) ..
    " afterBeats=" .. tostring(fafContBeats))

local fafBase = OnSync
local fafFired = false
local fafUnitsLogged = false
local fafBeats = 0
local fafProfAcc = {}
local fafProfFrames = 0
local fafProfDumped = false
OnSync = function()
    fafBase()
    fafBeats = fafBeats + 1
    -- Capture FAF call-count profiler data (Sync.ProfilerData, pushed per tick by
    -- lua/sim/Profiler.lua's SyncThread). Accumulate across frames, then dump the
    -- top callers once — this is the air-callback multiplication signal.
    if Sync.ProfilerData and not fafProfDumped then
        for source, scopes in Sync.ProfilerData do
            for scope, names in scopes do
                for name, count in names do
                    local key = tostring(source) .. "|" .. tostring(name)
                    fafProfAcc[key] = (fafProfAcc[key] or 0) + count
                end
            end
        end
        fafProfFrames = fafProfFrames + 1
        if fafProfFrames >= 25 then
            fafProfDumped = true
            local arr = {}
            for k, v in fafProfAcc do table.insert(arr, {k, v}) end
            table.sort(arr, function(a, b) return a[2] > b[2] end)
            LOG("FAF_PROF: top Lua call-counts over " .. fafProfFrames .. " frames:")
            for i = 1, math.min(45, table.getn(arr)) do
                LOG(string.format("FAF_PROF: %9d  %s", arr[i][2], arr[i][1]))
            end
            LOG("FAF_PROF: end")
        end
    end

    local req = rawget(Sync, "FafSaveRequest")
    if math.mod(fafBeats, 100) == 0 then
        LOG("FAF_SAVE(UI): OnSync alive beats=" .. fafBeats .. " req=" .. tostring(req))
    end
    -- Reload-continue: fire one save after the requested number of extra beats,
    -- independent of the frozen sim's save request (which is disabled by fafIsLoad).
    if fafContName and fafContBeats and not fafFired and fafBeats >= fafContBeats then
        fafFired = true
        local path = "Z:\\home\\narfman0\\.openclaw\\workspace\\faf\\fixtures\\" ..
            tostring(fafContName) .. ".SCFAsave"
        LOG("FAF_SAVE(UI): savecontinue firing at beats=" .. fafBeats .. " path=" .. path)
        local okC, errC = pcall(function()
            InternalSaveGame(path, tostring(fafContName), function(worked, errmsg)
                LOG("FAF_SAVE(UI): oncompletion worked=" .. tostring(worked) ..
                    " err=" .. tostring(errmsg))
            end)
        end)
        LOG("FAF_SAVE(UI): savecontinue call ok=" .. tostring(okC) .. " err=" .. tostring(errC))
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
