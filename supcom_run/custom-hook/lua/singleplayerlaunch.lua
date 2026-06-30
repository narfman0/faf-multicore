-- Hook: override StartCommandLineSession for headless M28AI 1v1 profiling.
-- This file is loaded AFTER SinglePlayerLaunch.lua (schook mechanism), so it
-- just needs to redefine the functions it wants to patch.

function StartCommandLineSession(mapName, _isPerfTest)
    -- Reload branch: /loadsave <winpath> resumes a saved session (state captured
    -- mid-game by the UserSync hook) instead of starting a fresh skirmish. The
    -- /map arg is still required to make the engine call this function; it is
    -- ignored here. LoadSavedGame is a front-end engine global (see saveload.lua).
    local loadArg = GetCommandLineArg("/loadsave", 1)
    if loadArg and loadArg[1] then
        local path = loadArg[1]
        LOG("FAF_LOAD: StartCommandLineSession -> LoadSavedGame path=" .. path)
        local ok, worked, err, detail = pcall(LoadSavedGame, path)
        LOG("FAF_LOAD: ok=" .. tostring(ok) .. " worked=" .. tostring(worked) ..
            " err=" .. tostring(err) .. " detail=" .. tostring(detail))
        return
    end

    mapName = FixupMapName(mapName)

    local scenario = import("/lua/ui/maputil.lua").LoadScenario(mapName)
    if not scenario then
        _G.error("Unable to load map " .. mapName)
    end

    local ai = 'm28ai'
    local aiopt = GetCommandLineArg("/ai", 1)
    if aiopt and aiopt[1] then ai = aiopt[1] end
    -- M28 only activates when the personality starts with lowercase 'm28'
    -- (M28Conditions.IsM28AIPersonality). Passing 'M28AI' left M28 dormant — 8
    -- idle ACUs, no economy/army. Lowercase so M28 actually plays.
    ai = string.lower(ai)

    local GetDefaultPlayerOptions = import("/lua/ui/lobby/lobbycomm.lua").GetDefaultPlayerOptions
    local armies = scenario.Configurations.standard.teams[1].armies
    local numColors = table.getn(import("/lua/gamecolors.lua").GameColors.PlayerColors)

    local sessionInfo = {}
    sessionInfo.playerName = 'Profiler'
    sessionInfo.createReplay = false
    sessionInfo.scenarioInfo = scenario
    -- Activate locally-available sim mods (the vault holds M28AI). Mounting a mod
    -- makes it importable but does NOT apply its /hook dirs or set __active_mods;
    -- that is driven by sessionInfo.scenarioMods. Without this, M28's
    -- hook/lua/aibrains/index.lua never merges, keyToBrain['m28ai'] stays nil, and
    -- every brain falls back to the base AIBrain (the 'rushbalanced' plan) — M28
    -- never runs. GetCampaignMods returns the (empty) prefs active_mods headless.
    -- Activate M28AI as a session mod so its /hook dirs merge, __active_mods is set
    -- (M28's BeginSessionAI loads its CustomAIs_v2 templates), and its lua is
    -- active. mods.lua discovery (AllMods->DiskFindFiles('/mods',...)) HANGS in this
    -- headless VFS, so build the ModInfo directly (mirrors LoadModInfo: doscript the
    -- mod_info.lua into an env with the right defaults). NOTE: this activation
    -- applies M28's hooks slightly too late for keyToBrain to be registered before
    -- brain creation — /schook/lua/aibrains/index.lua registers it early instead.
    local modfile = '/mods/m28ai/mod_info.lua'
    local modenv = {
        location = '/mods/m28ai', name = modfile, description = '', author = '',
        copyright = '', exclusive = false, icon = '', selectable = true,
        hookdir = '/hook', shadowdir = '/shadow', uid = modfile,
    }
    local okMod = pcall(doscript, modfile, modenv)
    modenv.location = '/mods/m28ai'
    LOG("FAF_MODS: m28 modinfo ok=" .. tostring(okMod) .. " uid=" .. tostring(modenv.uid))
    sessionInfo.scenarioMods = okMod and { modenv } or {}
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
        Ratings = {},   -- M28 writes Options.Ratings[nickname]; nil here -> m28chat error
        Score = 'no',
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

    LOG("FAF_MODS: teamInfo[1].AIPersonality=" .. tostring(sessionInfo.teamInfo[1].AIPersonality) ..
        " teamInfo[1].ArmyName=" .. tostring(sessionInfo.teamInfo[1].ArmyName))
    LaunchSinglePlayerSession(sessionInfo)
end
