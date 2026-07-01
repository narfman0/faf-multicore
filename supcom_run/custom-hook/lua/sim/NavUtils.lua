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
