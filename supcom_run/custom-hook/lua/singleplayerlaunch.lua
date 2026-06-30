-- Hook: override StartCommandLineSession for headless M28AI 1v1 profiling.
-- This file is loaded AFTER SinglePlayerLaunch.lua (schook mechanism), so it
-- just needs to redefine the functions it wants to patch.

function StartCommandLineSession(mapName, _isPerfTest)
    mapName = FixupMapName(mapName)

    local scenario = import("/lua/ui/maputil.lua").LoadScenario(mapName)
    if not scenario then
        _G.error("Unable to load map " .. mapName)
    end

    local ai = 'M28AI'
    local aiopt = GetCommandLineArg("/ai", 1)
    if aiopt and aiopt[1] then ai = aiopt[1] end

    local GetDefaultPlayerOptions = import("/lua/ui/lobby/lobbycomm.lua").GetDefaultPlayerOptions
    local armies = scenario.Configurations.standard.teams[1].armies
    local numColors = table.getn(import("/lua/gamecolors.lua").GameColors.PlayerColors)

    local sessionInfo = {}
    sessionInfo.playerName = 'Profiler'
    sessionInfo.createReplay = false
    sessionInfo.scenarioInfo = scenario
    sessionInfo.scenarioMods = import("/lua/mods.lua").GetCampaignMods(scenario)
    sessionInfo.teamInfo = {}
    sessionInfo.scenarioInfo.Options = {
        FogOfWar = 'none',
        NoRushOption = 'Off',
        PrebuiltUnits = 'Off',
        Difficulty = 3,
        DoNotShareUnitCap = false,
        Timeouts = -1,
        GameSpeed = 'fast',
        UnitCap = '500',
        Victory = 'demoralization',
        CheatsEnabled = 'false',
        CivilianAlliance = 'enemy',
        TeamShareOverflow = 'enabled',
    }

    -- One AI bot per map army, split into two teams (4v4 on an 8-slot map,
    -- 1v1 on a 2-slot map). First half = team 1, second half = team 2.
    local numBots = table.getn(armies)
    local half = math.floor(numBots / 2)
    for index = 1, numBots do
        local opts = GetDefaultPlayerOptions('Bot' .. index)
        opts.PlayerName = 'Bot_' .. index
        opts.ArmyName = armies[index]
        opts.Faction = math.mod(index - 1, 4) + 1
        opts.Human = false
        opts.AIPersonality = ai
        opts.Team = (index <= half) and 1 or 2
        opts.PlayerColor = math.mod(index, numColors)
        opts.ArmyColor = math.mod(index, numColors)
        sessionInfo.teamInfo[index] = opts
    end

    LaunchSinglePlayerSession(sessionInfo)
end
