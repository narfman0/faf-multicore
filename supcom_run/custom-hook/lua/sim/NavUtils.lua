-- schook append to /lua/sim/NavUtils.lua (mounted via /schook; runs at the end of the
-- module chunk, so the wrapped GetLabel is what the import system exports).
--
-- Memoize GetLabel. The FAF navmesh is generated ONCE (NavUtils.Generate is
-- IsGenerated-guarded) from STATIC terrain only (surface height + water depth; no units
-- or buildings — those are handled by the fine pathfinder / PathTo). So
-- (layer, position) -> label is constant for the whole session. GetLabel re-descends the
-- quad-tree (FindLeaf) on every call — ~558 calls/tick at ~1k units in a 4v4 M28 game,
-- growing with unit count (faf-analysis/pathfinding-offload.md). Cache it.
--
-- Key: integer ogrids. The quad-tree bottoms out at compressionThreshold (>= 1) on an
-- integer-aligned grid, so a floor(x),floor(z) cell sits inside exactly one leaf -> one
-- label -> safe. Only PERMANENT results are cached: a nil from 'NotGenerated'/'SystemError'
-- is transient and must not stick. Assumes no mid-game regeneration (true in play; the
-- only regen path is the dev disk-reload hook) — clear FafNavLabelCache if that changes.
do
    local baseGetLabel = GetLabel
    local floor = math.floor
    FafNavLabelCache = {}            -- [layer][kx][kz] = label | false(=permanent nil)
    FafGetLabelHits = 0
    FafGetLabelMisses = 0
    local cache = FafNavLabelCache
    GetLabel = function(layer, position)
        -- Some callers pass a malformed/partial position (e.g. position[1] nil) that the
        -- base short-circuits before touching; don't eager-floor those — defer to base.
        local px, pz = position[1], position[3]
        if px == nil or pz == nil then return baseGetLabel(layer, position) end
        local lc = cache[layer]
        if not lc then lc = {}; cache[layer] = lc end
        local kx = floor(px)
        local row = lc[kx]
        if not row then row = {}; lc[kx] = row end
        local kz = floor(pz)
        local e = row[kz]
        if e ~= nil then
            FafGetLabelHits = FafGetLabelHits + 1
            if e == false then return nil, 'CachedNil' end
            return e
        end
        FafGetLabelMisses = FafGetLabelMisses + 1
        -- Periodic hit-rate log (module-local; sandboxed globals aren't visible cross-module).
        if math.mod(FafGetLabelMisses, 5000) == 0 then
            local tot = FafGetLabelHits + FafGetLabelMisses
            LOG(string.format("FAF_LABELMEMO: hits=%d misses=%d hitrate=%.1f%% cells~%d",
                FafGetLabelHits, FafGetLabelMisses,
                tot > 0 and (FafGetLabelHits / tot * 100) or 0, FafGetLabelMisses))
        end
        local label, msg = baseGetLabel(layer, position)
        if label ~= nil then
            row[kz] = label
        elseif msg == 'OutsideMap' or msg == 'Unpathable' or msg == 'InvalidLayer' then
            row[kz] = false
        end   -- NotGenerated / SystemError: transient, do not cache
        return label, msg
    end
end

-- ── TEMP faf_path offload wiring + self-test (gated; remove after validation) ──
-- After the mesh generates, export the NavSection graph to faf_path.dll, then compare
-- FAF_OffloadPath results against synchronous PathTo (target: mismatch=0). Runs in
-- NavUtils scope for FindGrid/FindSection/PathTo/NavSections. Section centers pass as
-- lua_Number (double) -> the DLL reads them at full precision.
local FAF_PATHTEST = true
if FAF_PATHTEST then
ForkThread(function()
    for i = 1, 3000 do if NavGenerator.IsGenerated() then break end WaitTicks(1) end
    WaitTicks(10)
    -- wait for the DLL to register its Lua functions (happens on the first GTA call)
    local have = false
    for i = 1, 900 do
        local ok = pcall(function() return FAF_PathReset end)
        if ok and FAF_PathReset then have = true break end
        WaitTicks(1)
    end
    if not have then LOG("FAF_PATHTEST: faf_path.dll functions NOT registered — abort"); return end
    LOG("FAF_PATHTEST: DLL present; exporting mesh")
    local NS = NavGenerator.NavSections
    local maxId = 0
    for id, s in NS do if s.Identifier > maxId then maxId = s.Identifier end end
    FAF_PathReset(maxId)
    local nSec = 0
    for id, s in NS do
        FAF_PathSection(s.Identifier, s.Center[1], s.Center[3], s.Label, unpack(s.Neighbors))
        nSec = nSec + 1
    end
    FAF_PathReady()
    LOG("FAF_PATHTEST: exported " .. nSec .. " sections (maxId=" .. maxId .. ")")

    -- build land-center query pairs
    local grid = FindGrid('Land')
    local pts, np = {}, 0
    for id, s in NS do
        local c = s.Center
        local lbl = GetLabel('Land', { c[1], 0, c[3] })
        if lbl and lbl > 0 then np = np + 1; pts[np] = { c[1], c[3] } end
    end
    local seed = 987654321
    local function rnd() seed = math.mod(seed * 16807, 2147483647); return seed end
    local NQ = 40   -- <= MAX_SLOTS(64): one batch
    local Q = {}
    for q = 1, NQ do
        local pa = pts[math.mod(rnd(), np) + 1]
        local pb = pts[math.mod(rnd(), np) + 1]
        local origin, dest = { pa[1], 0, pa[2] }, { pb[1], 0, pb[2] }
        local oSec = FindSection(grid, origin)
        local dSec = FindSection(grid, dest)
        if oSec and dSec then
            local positions = PathTo('Land', origin, dest)
            local sync, ns = {}, 0
            if positions then
                local cur, guard = dSec, 0
                while cur and guard < 100000 do
                    ns = ns + 1; sync[ns] = cur.Identifier
                    local hf = cur.HeapFrom; if hf == nil then break end
                    cur = NS[hf]; guard = guard + 1
                end
            end
            local handle = FAF_OffloadPath(oSec.Identifier, dSec.Identifier)
            Q[q] = { o = oSec.Identifier, d = dSec.Identifier, h = handle, sync = sync, found = (positions ~= nil) }
        end
    end
    WaitTicks(4)   -- let workers finish
    local match, mismatch, nilhandle = 0, 0, 0
    for q = 1, NQ do
        local e = Q[q]
        if e then
            local off = (e.h ~= nil) and FAF_PollPath(e.h) or nil
            if e.h == nil then nilhandle = nilhandle + 1 end
            if not e.found then
                if off == nil then match = match + 1 else mismatch = mismatch + 1 end
            elseif off == nil then
                mismatch = mismatch + 1
            else
                local same = (table.getn(off) == table.getn(e.sync))
                if same then for k = 1, table.getn(off) do if off[k] ~= e.sync[k] then same = false break end end end
                if same then match = match + 1 else
                    mismatch = mismatch + 1
                    if mismatch <= 3 then
                        local ss, os = {}, {}
                        for k = 1, table.getn(e.sync) do ss[k] = tostring(e.sync[k]) end
                        for k = 1, table.getn(off) do os[k] = tostring(off[k]) end
                        LOG("FAF_PATHTEST: MISMATCH o=" .. e.o .. " d=" .. e.d ..
                            " sync=" .. table.concat(ss, ",") .. " off=" .. table.concat(os, ","))
                    end
                end
            end
        end
    end
    LOG(string.format("FAF_PATHTEST: RESULT match=%d mismatch=%d nilhandle=%d of %d", match, mismatch, nilhandle, NQ))
end)
end
