# Option A Design — Native Shim DLL for Multi-Core AI Offload

## Overview

`faf_worker.dll` is a PE import patch injected into `ForgedAlliance.exe` at launch. It spawns dedicated OS worker threads outside the engine's fixed pool of 8 `CTaskThread` workers, and exposes a Lua API so M28AI can offload pure-function work to run concurrently with the sim thread.

---

## Thread Lifecycle

### Spawn (DLL_PROCESS_ATTACH)
1. Initialize `g_slots[MAX_JOBS]` as free (done = -1).
2. Create a manual-reset event (`g_work_event`) for waking workers.
3. `CreateThread` × N_WORKERS (default 2). Workers call `SetThreadAffinityMask` to pin to non-sim cores (bits 1+ of the process affinity mask; sim pins to bit 0).
4. Install a 6-byte PUSH/RET inline hook at `GetThreatAtPosition` VA `0x00590260` to intercept the first Lua call and capture `lua_State*`.
5. On first GTA call (sim thread): register `FAF_OffloadThreatMap` and `FAF_PollResult` into the Lua global namespace via `lua_pushcfunction` / `lua_setglobal`.

### Task queue
- `g_queue[MAX_JOBS]` is a ring buffer of `Job { slot_index }` values.
- `g_queue_tail` is incremented atomically by the producer (sim thread, inside `FAF_OffloadThreatMap`).
- `g_queue_head` is incremented atomically by the first worker to win a `CAS` on `head`.
- After enqueue, `SetEvent(g_work_event)` wakes a worker.

### Shutdown (DLL_PROCESS_DETACH)
1. Set `g_shutdown = 1`.
2. `SetEvent(g_work_event)` to unblock any sleeping worker.
3. `WaitForMultipleObjects` (2 s timeout) for all worker threads to exit.
4. Close handles and log.

---

## Safety Model

### Safe to read from worker threads
| Data | Why safe |
|------|----------|
| Threat map C structs | Read-only during a beat; sim writes between beats only |
| `ResultSlot.positions[]` | Copied from Lua before enqueue; worker owns it until `done=1` |
| `ResultSlot.army_index` | Plain int, set before enqueue |

### NOT safe from worker threads
| Data | Why unsafe |
|------|-----------|
| `lua_State*` | Lua is not thread-safe; all Lua stack ops must stay on sim thread |
| Unit command queues | Written by IssueThread / sim tick; concurrent writes → UB |
| `AssignThreatAtPosition` | Write path; concurrent with reads is a data race |

### Key invariant
Workers are issued at beat N; `FAF_PollResult` is only called at beat N+1 or later. The sim thread finishes its beat (including any `AssignThreatAtPosition` writes) before the AI Lua code calls `FAF_PollResult`. This one-beat lag guarantees the threat map is stable during worker reads.

---

## Beat Boundary Synchronization

```
Beat N (sim thread):
  AI Lua calls FAF_OffloadThreatMap(army, positions)
    → copies positions to slot, enqueues job, returns handle
  Sim thread continues rest of beat N work

Workers (concurrently):
  Pick up job, iterate positions, call inner GTA C function for each
  Write results to slot.results[], MemoryBarrier(), set done=1

Beat N+1 (sim thread):
  AI Lua calls FAF_PollResult(handle)
    → checks done flag
    → if done=1: push result table, free slot (done=-1), return results
    → if done=0: return nil, AI falls back to synchronous query
```

The `MemoryBarrier()` before `done=1` ensures all result writes are visible to the sim thread before the flag flip. `InterlockedExchange` for the flag provides the acquire/release pair on the consumer side.

---

## Lua API

### `handle = FAF_OffloadThreatMap(army_index, x1, y1, z1 [, x2, y2, z2, ...])`

- `army_index`: integer army index (same as GTA's army param)
- `x, y, z`: position varargs — up to 256 triplets (768 stack slots)
- Returns an integer handle (slot index), or `nil` if all slots are full

### `result = FAF_PollResult(handle)`

- Returns `nil` if the worker hasn't finished.
- Returns a flat array `{threat1, threat2, ...}` (one float per input position) when done.
- Frees the slot on first successful poll — do not call again with the same handle.

### M28AI integration sketch (Lua)

```lua
local function GetThreatsBatch(army, positions)
    -- positions = {{x,y,z}, {x,y,z}, ...}
    local args = {army}
    for _, p in ipairs(positions) do
        args[#args+1] = p[1]; args[#args+1] = p[2]; args[#args+1] = p[3]
    end
    local handle = FAF_OffloadThreatMap(unpack(args))
    if handle == nil then
        -- fallback: synchronous queries
        local results = {}
        for i, p in ipairs(positions) do
            results[i] = GetThreatAtPosition(p, 0, false, 'AntiSurface')
        end
        return results
    end
    return handle  -- poll via FAF_PollResult on next WaitTick
end
```

---

## Known Gaps / Next Steps

### 0. END-TO-END OFFLOAD — WORKING & MULTI-BRAIN VALIDATED (2026-06-29)

The full async offload round-trip works and is correctness-validated:
`FAF_OffloadThreatMap` (Lua, sim thread) → enqueue → worker thread dequeues →
`query_threat_at` computes via `0x715c60`+`0x715ff0` off the sim thread → sets
`done` → `FAF_PollResult` returns the array (1-tick latency). Worker values equal
synchronous `GetThreatAtPosition(pos,0,true,'Overall')` exactly. **4v4 (Seton's
Clutch): 24/24 match for each of three brains across both teams.**

Bugs fixed (in `call_715ff0` / `query_threat_at`):
1. **stdcall double-clean** — `0x715ff0` is `ret 0x18` (cleans its own 6 args);
   the wrapper's extra `addl $24` corrupted esp → worker died in the call (hang).
2. **'Overall' = sum all armies** — the per-cell fn `0x715750` stores threat per
   army (56-byte entries) and branches on the army-arg sign: `army>=0` reads ONE
   army's slice, `army<0` SUMS all (= 'Overall'). Pass `army = -1`. (Reading one
   slice is why the bug only showed in multi-army games; 1v1 hid it.)
3. **Per-brain map** — threat maps are per-brain/team-relative, so the worker
   selects the QUERYING army's map via the global army list:
   `army_mgr=*(aibrain+0xa4)`, `start=*(army_mgr+0x910)`, element[i]=army i's
   threat sub-object; `tmap = element[army-1]->vtable[6]@0x18(element)`.
   (`tmap_for_army` in faf_worker.c.) A team-2 brain offloading now reads its own
   team-relative threat. Full signature: `lua-va-table.md` → "0x715ff0".

Test harness: `supcom_run/custom-hook/lua/aibrain.lua` (/schook hook) — a sim
ForkThread (started at chunk-end; sim is already live at aibrain import) that
offloads ACU + grid positions from multiple brains and compares each to its own
synchronous threat. Run 4v4 via `MAP=SCMP_009 bash faf-shim/run_skirmish_worker.sh`.

Remaining for production use: ring>0 queries (worker only does ring 0); threat
types other than 'Overall' (parameterize); determinism audit (gap #5 below).

### 1. AIBrain pointer / threat map pointer — RESOLVED (2026-06-29, armed second hook)

Worker chain is **5/5 green**, validated through a full M28AI vs M28AI skirmish.

**The original static chain was wrong** and is gone: `*(L+0x44)` (=`bw`) is the LuaPlus
**LuaState wrapper**, not the AIBrain userdata, so `type_tag@bw+0x0c==8` / `gcobj@bw+0x10`
never held (runtime gave `type_tag=215670540`). GTA disasm (`0x590260`→`0x5902e0`) shows
`self` is Lua stack arg 1, unwrapped by `0x5930d0` (RTTI dynamic_cast, returns the AIBrain
in EAX). Three naive extraction attempts all failed (`*(L+8)` stack base, global
`*(0xf5a124)`, 24-candidate heap scan — 0 hits); see `lua-va-table.md`.

**Solution — armed second hook on `0x5930d0`** (`faf_worker.c`):
- Inline-hook `0x5930d0` stealing its 7-byte prologue (`83 ec 18 / 56 / 83 ec 14`).
  It takes its arg in EAX and returns the AIBrain in EAX (plain `ret`); the naked stub
  `hook_x5930d0` runs the original via the trampoline, then captures EAX while armed.
- In `hook_gta`, while `g_tmap` is unset, arm `g_arm_x5930d0` around the real GTA
  trampoline call. The engine's GTA calls `0x5930d0` once for its `self`; the hook
  records that pointer (`g_captured_aibrain`) and one-shot-disarms.
- `cache_tmap_from_aibrain()` then runs the proven step 2:
  `sub_obj = *(aibrain+0x34)`; `tmap = sub_obj->vtable[6]`(offset `0x18`)`(sub_obj)`
  [thiscall, `ecx=sub_obj`]. Cached as `g_tmap`.

Confirmed live: `cache_tmap: OK aibrain=… sub_obj=… tmap=…` fires exactly once, then
arming stops; no crash on the heavily-called `0x5930d0` path. Workers read `g_tmap`
via `call_715c60` / `call_715ff0`.

Repro: `faf-shim/run_skirmish_worker.sh` (M28AI skirmish — a live AI game is needed to
generate GTA calls). Worker log: `/tmp/faf_worker.log`.

### 2. Lua VAs — confirmed
All Lua API VAs in `faf_worker.c` are confirmed via objdump disassembly of `ForgedAlliance_base.exe`. See `lua-va-table.md` for the full table with cross-references. No Ghidra needed.

### 3. `lua_settop` / `lua_pop`
`lua_settop` VA has not been confirmed. The current `faf_worker.c` avoids manual pops by using the varargs position API and `lua_rawseti` (which auto-pops). If needed later, search `0x90c000–0x90d000` for a function doing `add [esi+0x8], neg(n)*8`.

### 4. Profiler baseline
Run `faf_profiler.dll` against a 4v4 replay first to get per-call GTA timing CSV. Use that to:
- Confirm GTA is the dominant cost (expected: >60% of AI sim-tick budget)
- Measure average positions-per-call to size `MAX_POSITIONS` correctly
- Establish the before/after comparison baseline for Option A

### 5. Determinism audit
FAF replays require byte-exact sim determinism. Option A offloads are **observer-only** (read threat map, don't issue commands) — they don't affect the sim state. However, the AI's *decisions* in beat N+1 will differ from a non-offload game if the batch results differ from synchronous calls.

This is acceptable if: (a) the inner threat query function is truly stateless (same inputs → same outputs), and (b) the worker always completes before beat N+1 starts. If (b) fails (worker overloaded), `FAF_PollResult` returns nil and the AI falls back to sync. The sync fallback must produce identical decisions to the non-offload path for replay compatibility.

---

## Future Offload Candidates

| Candidate | Safety | Notes |
|-----------|--------|-------|
| Economy projection | Safe | Pure arithmetic over economy stats snapshot |
| Build order scoring | Safe | Scoring function is read-only over unit DB |
| Threat map batch write (`AssignThreatAtPosition`) | Unsafe | Writes to shared state; needs beat-boundary fence or double-buffer |
| Platoon path scoring | Risky | Reads nav mesh; check if nav mesh is written during beat |
