-- ── TEMP determinism spike: export the section graph + PathTo A* ground truth ──
-- Runs in NavUtils scope so it can reach the local FindGrid/FindSection. Dumps the
-- NavSection graph (centers at %.17g for bit-exact round-trip) and a batch of
-- section->section PathTo queries with the raw HeapFrom chain FAF's A* produced, so a
-- standalone C++ A* can be validated bit-for-bit. REMOVE after the spike.
local SPIKE_EXPORT = true
if SPIKE_EXPORT then
ForkThread(function()
    for i = 1, 3000 do
        if NavGenerator.IsGenerated() then break end
        WaitTicks(1)
    end
    WaitTicks(10)
    local NS = NavGenerator.NavSections
    -- 1) graph
    local ids, nIds = {}, 0
    for id, s in NS do
        nIds = nIds + 1; ids[nIds] = id
        local nb = s.Neighbors
        local parts = {}
        for k = 1, TableGetn(nb) do parts[k] = tostring(nb[k]) end
        LOG(string.format("SPIKE_SECTION %d %.17g %.17g %d N %s",
            s.Identifier, s.Center[1], s.Center[3], s.Label, table.concat(parts, ",")))
    end
    LOG("SPIKE_GRAPH_DONE nSections=" .. nIds)
    -- 2) queries: pairs of real Land-pathable positions, capture FAF's HeapFrom chain
    local grid = FindGrid('Land')
    local seed = 987654321
    local function rnd() seed = math.mod(seed * 16807, 2147483647); return seed end
    -- collect Land positions directly from section centers that are land-pathable
    local pts, np = {}, 0
    for id, s in NS do
        local c = s.Center
        local lbl = GetLabel('Land', { c[1], 0, c[3] })
        if lbl and lbl > 0 then np = np + 1; pts[np] = { c[1], c[3] } end
    end
    LOG("SPIKE_PTS landcenters=" .. np)
    local NQ = 800
    for q = 1, NQ do
        local pa = pts[math.mod(rnd(), np) + 1]
        local pb = pts[math.mod(rnd(), np) + 1]
        local origin = { pa[1], 0, pa[2] }
        local dest   = { pb[1], 0, pb[2] }
        local positions = PathTo('Land', origin, dest)
        local oSec = FindSection(grid, origin)
        local dSec = FindSection(grid, dest)
        local seq, ns = {}, 0
        if positions and dSec then
            local cur, guard = dSec, 0
            while cur and guard < 100000 do
                ns = ns + 1; seq[ns] = tostring(cur.Identifier)
                local hf = cur.HeapFrom
                if hf == nil then break end
                cur = NS[hf]; guard = guard + 1
            end
        end
        LOG(string.format("SPIKE_QUERY %d o=%s d=%s found=%s seq=%s",
            q, tostring(oSec and oSec.Identifier or -1), tostring(dSec and dSec.Identifier or -1),
            tostring(positions ~= nil), table.concat(seq, ",")))
    end
    LOG("SPIKE_DONE")
end)
end
