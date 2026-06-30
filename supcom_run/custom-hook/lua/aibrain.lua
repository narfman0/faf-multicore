-- Hook: exercise the faf_worker offload (FAF_OffloadThreatMap / FAF_PollResult)
-- and compare worker results against synchronous GetThreatAtPosition.
-- Loaded AFTER /lua/aibrain.lua (schook), so the AIBrain class already exists.
-- NOTE: the FA sim sandbox does NOT expose _G — use direct global access only.

LOG("FAF_WORKER_TEST: aibrain hook chunk executing")
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

function FafBeatLogger()
    local ticks = 0
    while true do
        WaitTicks(100)
        ticks = ticks + 100
        local okT, gt = pcall(GetGameTimeSeconds)
        LOG(string.format("FAF_BEAT: ticks=%d gt=%s", ticks, tostring(okT and gt or "n/a")))
        if ticks >= SAVE_TICK then
            Sync.FafSaveRequest = FAF_SAVE_NAME
            if ticks == SAVE_TICK then
                LOG("FAF_SAVE(sim): requested save at tick " .. ticks .. " name=" .. FAF_SAVE_NAME)
            end
        end
    end
end

-- Trigger C (primary): at import the sim is already live and ArmyBrains is
-- populated, so the session-start triggers have already fired. Kick the test
-- thread directly. FafWorkerOffloadTest polls ArmyBrains and waits for warmup.
ForkThread(function() FafWorkerMaybeStart("chunk-end") end)
ForkThread(FafBeatLogger)
