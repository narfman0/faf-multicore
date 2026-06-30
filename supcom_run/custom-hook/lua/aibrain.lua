-- Hook: exercise the faf_worker offload (FAF_OffloadThreatMap / FAF_PollResult)
-- and compare worker results against synchronous GetThreatAtPosition.
-- Loaded AFTER /lua/aibrain.lua (schook), so the AIBrain class already exists.
-- NOTE: the FA sim sandbox does NOT expose _G — use direct global access only.

LOG("FAF_WORKER_TEST: aibrain hook chunk executing")
-- Stub CollectCurrentScores: FAF simInit's BeginSession calls this engine fn, which
-- our exe build lacks ("nonexistent global"), failing BeginSession. Define a no-op
-- (guarded read for the strict sandbox) so BeginSession completes and the AI starts.
do
    local okCCS = pcall(function() return CollectCurrentScores end)
    if not okCCS then CollectCurrentScores = function() return {} end end
end
LOG("FAF_WORKER_TEST: probe ForkThread=" .. tostring(ForkThread) ..
    " BeginSession=" .. tostring(BeginSession) ..
    " ArmyBrains=" .. tostring(ArmyBrains))

local __FafStarted = false

function FafWorkerMaybeStart(tag)
    if __FafStarted then return end
    __FafStarted = true
    LOG("FAF_WORKER_TEST: trigger=" .. tostring(tag) .. " — starting test thread")
    ForkThread(FafWorkerOffloadTest)
end

-- Build the test position list once: every ACU (non-zero threat for someone)
-- plus a map-spanning grid.
function FafWorkerBuildPositions()
    local pts = {}
    for bi = 1, table.getn(ArmyBrains) do
        local eb = ArmyBrains[bi]
        local okU, acus = pcall(function()
            return eb:GetListOfUnits(categories.COMMAND, false)
        end)
        if okU and acus and table.getn(acus) > 0 then
            local p = acus[1]:GetPosition()
            table.insert(pts, {p[1], p[2], p[3]})
        end
    end
    for gx = 128, 896, 256 do
        for gz = 128, 896, 256 do
            table.insert(pts, {gx, GetTerrainHeight(gx, gz), gz})
        end
    end
    return pts
end

-- Offload from a specific brain and compare to that brain's synchronous
-- GetThreatAtPosition('Overall'). Returns "match/total".
function FafWorkerCompareBrain(brain, pts)
    local army = brain:GetArmyIndex()

    local sync = {}
    for i, p in ipairs(pts) do
        sync[i] = brain:GetThreatAtPosition(p, 0, true, 'Overall')
    end

    local args = {army}
    for _, p in ipairs(pts) do
        table.insert(args, p[1]); table.insert(args, p[2]); table.insert(args, p[3])
    end
    local handle = FAF_OffloadThreatMap(unpack(args))
    if handle == nil then LOG("FAF_WORKER_TEST: army " .. army .. " offload nil"); return end

    local result
    for attempt = 1, 60 do
        WaitTicks(1)
        result = FAF_PollResult(handle)
        if result then break end
    end
    if not result then LOG("FAF_WORKER_TEST: army " .. army .. " poll NEVER completed"); return end

    local nMatch, nMismatch, nNonZero = 0, 0, 0
    for i, p in ipairs(pts) do
        local w = result[i] or -1
        local s = sync[i] or -1
        if math.abs(w - s) < 0.01 then nMatch = nMatch + 1 else
            nMismatch = nMismatch + 1
            LOG(string.format("FAF_WORKER_TEST:   MISMATCH army%d pos%d (%d,%d) worker=%.1f sync=%.1f",
                army, i, p[1], p[3], w, s))
        end
        if s > 0.01 then nNonZero = nNonZero + 1 end
    end
    LOG(string.format("FAF_WORKER_TEST: army %d (team-relative) RESULT match=%d mismatch=%d (of %d; %d non-zero)",
        army, nMatch, nMismatch, table.getn(pts), nNonZero))
end

function FafWorkerOffloadTest()
    -- Wait for the brain list to populate.
    for i = 1, 600 do
        if ArmyBrains and table.getn(ArmyBrains) > 0 then break end
        WaitTicks(1)
    end
    if not (ArmyBrains and table.getn(ArmyBrains) > 0) then
        LOG("FAF_WORKER_TEST: no ArmyBrains after wait"); return
    end
    local nb = table.getn(ArmyBrains)
    LOG("FAF_WORKER_TEST: ArmyBrains n=" .. tostring(nb))

    -- Warm up so the DLL registers the offload API + the threat maps cycle to
    -- include known (no-fog) units across the map.
    WaitSeconds(45)
    if not FAF_OffloadThreatMap or not FAF_PollResult then
        LOG("FAF_WORKER_TEST: offload API NOT present"); return
    end

    local pts = FafWorkerBuildPositions()
    LOG("FAF_WORKER_TEST: testing " .. tostring(table.getn(pts)) .. " positions from multiple brains")

    -- Per-brain validation: offload from a team-1 brain AND a team-2 brain.
    -- Each must match ITS OWN brain's synchronous threat (maps are team-relative).
    FafWorkerCompareBrain(ArmyBrains[1], pts)        -- team 1 (army 1)
    FafWorkerCompareBrain(ArmyBrains[nb], pts)       -- team 2 (highest army)
    if nb >= 5 then FafWorkerCompareBrain(ArmyBrains[5], pts) end  -- another team-2 brain

    LOG("FAF_WORKER_TEST: done")
end

-- Trigger A: wrap the global BeginSession (canonical sim-start entry; nullary
-- in FA). NOTE: FA's Lua 5.0 dialect does NOT accept the bare `...` expression
-- (use the `arg` table instead) — so we avoid varargs entirely.
if BeginSession then
    local _oldBeginSession = BeginSession
    function BeginSession()
        _oldBeginSession()
        FafWorkerMaybeStart("BeginSession")
    end
    LOG("FAF_WORKER_TEST: wrapped BeginSession")
end

-- Trigger B: OnBeginSession override (subclass; FAF Class objects are sealed).
-- (Likely too late — brains predate this hook — but harmless as a fallback.)
local _oldAIBrain = AIBrain
AIBrain = Class(_oldAIBrain) {
    OnBeginSession = function(self)
        _oldAIBrain.OnBeginSession(self)
        FafWorkerMaybeStart("OnBeginSession")
    end,
}

-- Beat/tick logger: counts sim ticks elapsed so the profiler / throughput runners
-- can compute GTA's share of the sim-tick budget (calls/tick, % of tick) and
-- beats/sec. Independent of the offload API, so it also works under the profiler
-- build (no FAF_OffloadThreatMap there). The engine logs no beat markers by
-- default; this is the tick source the runners grep ("FAF_BEAT: ticks=N").
-- Mid-game save: the save API (InternalSaveGame) is UI-side only, so the sim can
-- only REQUEST a save via the Sync table (the sanctioned sim->UI channel). At
-- SAVE_TICK we set Sync.FafSaveRequest = <path> every beat (idempotent; the UI
-- gamemain hook acts once). SAVE_TICK = 18000 ticks = 30 game-min (10 ticks/s);
-- use a small value (e.g. 200 ≈ 20 game-sec) to re-validate the mechanism.
local SAVE_TICK = 18000
local FAF_SAVE_NAME = "seton4v4-30min"

-- Count live units across all brains (total sim unit load). C call per brain; run
-- it every few beats, not every tick.
function FafTotalUnits()
    local total = 0
    for bi = 1, table.getn(ArmyBrains) do
        local ok, u = pcall(function()
            return ArmyBrains[bi]:GetListOfUnits(categories.ALLUNITS, false)
        end)
        if ok and u then total = total + table.getn(u) end
    end
    return total
end

function FafBeatLogger()
    local ticks = 0
    local unitsLogged = false
    while true do
        WaitTicks(20)            -- finer cadence so short windows are measurable
        ticks = ticks + 20
        local okT, gt = pcall(GetGameTimeSeconds)
        -- rt = real wall-seconds (profiling-only engine clock); Δrt/Δticks = ms/tick.
        local okR, rt = pcall(GetSystemTimeSecondsOnlyForProfileUse)
        LOG(string.format("FAF_BEAT: ticks=%d gt=%s rt=%s units=%d", ticks,
            tostring(okT and gt or "n/a"), tostring(okR and rt or "n/a"), FafTotalUnits()))
        -- Log total unit count on the first iteration (so a reloaded snapshot
        -- reports immediately) and every 500 ticks thereafter.
        if not unitsLogged or math.mod(ticks, 500) == 0 then
            unitsLogged = true
            LOG("FAF_UNITS: ticks=" .. ticks .. " total_units=" .. FafTotalUnits())
        end
        if ticks >= SAVE_TICK then
            Sync.FafSaveRequest = FAF_SAVE_NAME
            if ticks == SAVE_TICK then
                LOG("FAF_SAVE(sim): requested save at tick " .. ticks .. " name=" .. FAF_SAVE_NAME)
            end
        end
    end
end

-- Air-stress harness: spawn a controllable air battle to profile the sim at high
-- unit counts (the 2k-5k endgame regime). OFF by default. Spawns SPAWN_N T1
-- interceptors split between two opposing armies, overlapping near map center so
-- their AA weapons engage immediately (exercises collision/projectile/aim/motion).
-- CreateUnitHPR bypasses the unit cap. Spawn is batched to avoid a one-tick hitch.
local SPAWN_AIR = false      -- flip true for air-stress profiling runs
local SPAWN_N = 1000          -- total; SPAWN_N/2 per brain
local SPAWN_BP = "uea0102"    -- UEF T1 interceptor (cheap, numerous)
-- "opposing": group2 = enemy team (they fight). "allied": group2 = a friendly
-- team-1 brain (no combat). Both put SPAWN_N/2 units on each of two M28 brains, so
-- M28's management cost matches and ms/tick(opposing)-ms/tick(allied) = combat cost.
local SPAWN_MODE = "opposing"  -- opposing|allied|neutral
FafAirSpawned = false         -- global (pre-declared so reads don't hit strict-global)

function FafSpawnAirBattle()
    for i = 1, 600 do
        if ArmyBrains and table.getn(ArmyBrains) >= 2 then break end
        WaitTicks(1)
    end
    local nb = table.getn(ArmyBrains)
    if nb < 2 then LOG("FAF_AIRSPAWN: <2 brains, abort"); return end
    local a1, a2
    if SPAWN_MODE == "neutral" then
        -- find a non-M28 (civilian) army so the units exist but M28 doesn't manage
        -- them — isolates raw engine per-unit cost from M28 AI cost.
        local aN
        for bi = 1, nb do
            local ai = ArmyBrains[bi]:GetArmyIndex()
            local okc, civ = pcall(ArmyIsCivilian, ai)
            LOG("FAF_ARMY: idx=" .. ai .. " civilian=" .. tostring(okc and civ) ..
                " m28=" .. tostring(ArmyBrains[bi].M28AI))
            if okc and civ then aN = ai end
        end
        if not aN then LOG("FAF_AIRSPAWN: no civilian army found, abort neutral"); return end
        a1 = aN; a2 = aN
    elseif SPAWN_MODE == "allied" then
        a1 = ArmyBrains[1]:GetArmyIndex(); a2 = ArmyBrains[2]:GetArmyIndex()
    else  -- opposing
        a1 = ArmyBrains[1]:GetArmyIndex(); a2 = ArmyBrains[nb]:GetArmyIndex()
    end
    WaitTicks(40)                      -- let the session settle
    local half = math.floor(SPAWN_N / 2)
    local cols, sp, cx, cz = 45, 3, 512, 512
    local made = 0
    for k = 0, half - 1 do
        local ox = math.mod(k, cols) * sp
        local oz = math.floor(k / cols) * sp
        local x, z = cx - 67 + ox, cz - 67 + oz
        pcall(function() CreateUnitHPR(SPAWN_BP, a1, x,     GetTerrainHeight(x, z),     z,     0, 0, 0) end)
        pcall(function() CreateUnitHPR(SPAWN_BP, a2, x + 1, GetTerrainHeight(x + 1, z), z + 1, 0, 0, 0) end)
        made = made + 2
        if math.mod(k, 100) == 99 then WaitTicks(1) end   -- spread the spawn cost
    end
    LOG("FAF_AIRSPAWN: mode=" .. SPAWN_MODE .. " spawned " .. made .. " units (" ..
        SPAWN_BP .. ") armies " .. a1 .. " + " .. a2)
    FafAirSpawned = true
end

-- Self-contained call-count profiler. FAF's lua/sim/Profiler.lua is a community
-- patch not present in our retail+m28ai VFS, so we install debug.sethook ("c" =
-- on every Lua function call) ourselves over a fixed tick window, then log the top
-- callers directly. The aim: see which engine->Lua callbacks (OnCollisionCheck/
-- OnImpact/OnKilled) multiply during air spam. NOTE: Lua 5.0 sethook may be
-- per-coroutine; the dump's contents tell us if it catches engine callbacks or
-- only this thread (if the latter, we wrap the methods instead).
function FafEnableProfiler()
    for i = 1, 1200 do
        if FafAirSpawned then break end
        WaitTicks(1)
    end
    WaitTicks(20)   -- let the battle reach steady combat
    local okd, dbg = pcall(function() return debug end)   -- strict-global safe
    if not (okd and dbg and dbg.sethook and dbg.getinfo) then
        LOG("FAF_PROF: debug.sethook unavailable in sim sandbox (okd=" .. tostring(okd) .. ")")
        return
    end
    local getinfo = dbg.getinfo
    local counts = {}
    local hook = function()
        local info = getinfo(2, "Sn")
        if info then
            local k = (info.short_src or "?") .. "|" .. (info.name or info.what or "?")
            counts[k] = (counts[k] or 0) + 1
        end
    end
    LOG("FAF_PROF: installing sethook for 40 ticks")
    dbg.sethook(hook, "c")
    WaitTicks(40)
    dbg.sethook()
    local arr = {}
    for k, v in counts do table.insert(arr, {k, v}) end
    table.sort(arr, function(a, b) return a[2] > b[2] end)
    LOG("FAF_PROF: top Lua call-counts over 40 ticks (" .. table.getn(arr) .. " distinct):")
    for i = 1, math.min(45, table.getn(arr)) do
        LOG(string.format("FAF_PROF: %10d  %s", arr[i][2], arr[i][1]))
    end
    LOG("FAF_PROF: end")
end

-- Trigger C (primary): at import the sim is already live and ArmyBrains is
-- populated, so the session-start triggers have already fired. Kick the test
-- thread directly. FafWorkerOffloadTest polls ArmyBrains and waits for warmup.
ForkThread(function() FafWorkerMaybeStart("chunk-end") end)
ForkThread(FafBeatLogger)
-- Force-start M28's wall-time profiler output thread (its own OnCreateBrain fork
-- doesn't fire in this headless setup). Confirms the config flag, then forks
-- ProfilerActualTimePerTick (idempotent via M28's bActiveProfiler guard).
function FafStartM28Profiler()
    for i = 1, 1200 do
        if FafAirSpawned then break end
        WaitTicks(1)
    end
    WaitTicks(20)
    local okC, cfg = pcall(import, '/mods/M28AI/lua/M28Config.lua')
    local okP, prof = pcall(import, '/mods/M28AI/lua/AI/M28Profiler.lua')
    LOG("FAF_M28PROF: cfg_ok=" .. tostring(okC) .. " RunProfiling=" ..
        tostring(okC and cfg and cfg.M28RunProfiling) .. " prof_ok=" .. tostring(okP) ..
        " prof_err=" .. tostring(not okP and prof or "-"))
    if okC and cfg and cfg.M28RunProfiling and okP and prof and prof.ProfilerActualTimePerTick then
        ForkThread(prof.ProfilerActualTimePerTick)
        LOG("FAF_M28PROF: forked ProfilerActualTimePerTick")
    else
        LOG("FAF_M28PROF: not started")
    end
end

-- Time CanBuildStructureAt (M28's hot engine leaf / offload candidate) via a
-- debug.sethook call/return bracket, sampled in short windows as the game develops.
-- Reports per-call us, calls/tick, % of a 100ms tick, plus a realism trajectory
-- (unit count + delta = building vs losing units to combat).
function FafTimeCBSA()
    local okd, dbg = pcall(function() return debug end)
    if not (okd and dbg and dbg.sethook and dbg.getinfo) then
        LOG("FAF_CBSA: debug.sethook unavailable"); return
    end
    local getinfo = dbg.getinfo
    local prevUnits = 0
    while true do
        WaitTicks(1800)                      -- every ~3 game-min
        local startT, total, count = nil, 0, 0
        local hook = function(event)
            local info = getinfo(2, "n")
            if info and info.name == "CanBuildStructureAt" then
                if event == "call" then
                    startT = GetSystemTimeSecondsOnlyForProfileUse()
                elseif event == "return" and startT then
                    total = total + (GetSystemTimeSecondsOnlyForProfileUse() - startT)
                    count = count + 1; startT = nil
                end
            end
        end
        dbg.sethook(hook, "cr")
        WaitTicks(40)                         -- measurement window (game-ticks)
        dbg.sethook()
        local okg, gt = pcall(GetGameTimeSeconds)
        local units = FafTotalUnits()
        local avg_us = (count > 0) and (total / count * 1e6) or 0
        local cpt = count / 40
        LOG(string.format("FAF_CBSA: gt=%s units=%d d_units=%d calls=%d calls/tick=%.1f avg_us=%.2f pct_of_tick=%.3f",
            tostring(okg and gt or "?"), units, units - prevUnits, count, cpt, avg_us,
            (cpt * avg_us) / 100000 * 100))
        prevUnits = units
    end
end

local PROFILE_SELFHOOK = false   -- our debug.sethook profiler
local PROFILE_M28 = false        -- M28's wall-time profiler (output thread won't run headless)
local PROFILE_CBSA = false       -- time CanBuildStructureAt as the game develops
-- Diagnose why M28 doesn't activate: per brain, log the name, the personality
-- ScenarioInfo.ArmySetup reports, the M28AI flag, and IsM28AIPersonality's verdict.
function FafM28Diag()
    for i = 1, 600 do
        if ArmyBrains and table.getn(ArmyBrains) > 0 then break end
        WaitTicks(1)
    end
    WaitTicks(30)
    local okMC, MC = pcall(function() return import('/mods/M28AI/lua/AI/M28Conditions.lua') end)
    local okK, k = pcall(function() return import('/lua/aibrains/index.lua').keyToBrain['m28ai'] end)
    LOG("FAF_M28DIAG: M28Conditions import ok=" .. tostring(okMC) ..
        " ScenarioInfo=" .. tostring(ScenarioInfo ~= nil) ..
        " keyToBrain['m28ai']=" .. tostring(okK and k))
    for bi = 1, table.getn(ArmyBrains) do
        local b = ArmyBrains[bi]
        local nm = b.Name
        local okP, per = pcall(function() return ScenarioInfo.ArmySetup[nm].AIPersonality end)
        local okIs, isM28 = pcall(function() return okMC and MC.IsM28AIPersonality(b) end)
        LOG(string.format("FAF_M28DIAG: idx=%s name=%s nickname=%s personality=%s M28AI=%s IsM28=%s",
            tostring(b:GetArmyIndex()), tostring(nm), tostring(b.Nickname),
            tostring(okP and per or "<"..tostring(per)..">"),
            tostring(b.M28AI), tostring(okIs and isM28 or "err:"..tostring(isM28))))
    end
end
ForkThread(FafM28Diag)

if PROFILE_CBSA then ForkThread(FafTimeCBSA) end
if SPAWN_AIR then
    ForkThread(FafSpawnAirBattle)
    if PROFILE_SELFHOOK then ForkThread(FafEnableProfiler) end
    if PROFILE_M28 then ForkThread(FafStartM28Profiler) end
end
