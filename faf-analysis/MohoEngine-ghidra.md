# MohoEngine.dll — Ghidra Analysis

## A: Image Base
Result: 0x10000000

## B: Ghidra Project State
MohoEngine.dll not yet imported. SupremeCommander.exe only in project.
Script written: ~/DecompileSingle.java

## C: Ghidra Import
Status: **complete** (353 sec, clean)
Log: ~/ghidra-moho-import.log

Note: Ghidra decompiler hung at 99% CPU for 99+ min on THREAD_SetAffinity — killed.
Switched to objdump for disassembly analysis.

---

## D: THREAD_SetAffinity (RVA 0x12100) — objdump disassembly

### Raw disassembly (key section, 0x12100–0x12169)
```
12100: sub $0x8,%esp / push ebx,esi,edi
12106: lea [esp+0x10],%eax → push &processAffinityMask (out param)
1210b: lea [esp+0x10],%ecx → push &systemAffinityMask (out param)
12110: call *[IAT:0x105ce210] → GetProcessAffinityMask(GetCurrentProcess(), ...)
12116: push %eax
12117: call *[IAT:0x105ce208] → GetCurrentThread()
1211d: mov bl, [esp+0x18]   → bl = bool param (the single arg)
12121: mov edi, [esp+0xc]   → edi = processAffinityMask
12125: xor edx,edx           → edx = 0 (low bit counter)
12127: mov esi, 0x1f         → esi = 31 (high bit counter)

; Loop: scan bits in processAffinityMask
12130: test bl,bl            → check bool param
12132: mov eax, 0x1
12137: mov ecx, edx          → if bool=true: scan from bit 0 upward
12139: jne 0x1213d
1213b: mov ecx, esi          → if bool=false: scan from bit 31 downward
1213d: shl eax, cl           → eax = 1 << bit_position
1213f: test eax, edi         → is this bit set in processAffinityMask?
12141: jne 0x12155           → yes: pin thread to this core
12143: add edx, 1 / sub esi, 1
12149: cmp edx, 0x20         → loop 32 times max
1214c: jb 0x12130
1214e: pop edi,esi,ebx / ret → no available core found, return

12155: push eax              → push affinity mask (1 << first_available_bit)
12156: call *[IAT:0x105ce20c] → SetThreadAffinityMask(GetCurrentThread(), mask)
1215c: push eax              → push prev affinity (return value)
1215d: call *[IAT:0x105ce204] → SetThreadPriority or CloseHandle
12163: pop edi,esi,ebx / ret
```

### Analysis
- `THREAD_SetAffinity(true)` → pins current thread to the **lowest available core** (bit 0 first)
- `THREAD_SetAffinity(false)` → pins current thread to the **highest available core** (bit 31 first)
- **Does NOT hardcode core count** — reads `GetProcessAffinityMask` dynamically
- **Key finding**: if we expand the process affinity mask (via `SetProcessAffinityMask`), threads pinned with `false` will spread to higher cores automatically
- The sim thread likely calls `THREAD_SetAffinity(true)` (pin to core 0); render/audio call `THREAD_SetAffinity(false)` (pin to highest core). Each CTaskThread worker probably calls one or the other to spread across the available mask.

---

## E: THREAD_InvokeAsync (RVA 0x11ac0) — objdump disassembly

### Raw disassembly (0x11ac0–0x11b8c)
```
11adf: eax = [esp+0x38]           → 2nd arg: target threadId (uint)
11ae3: if eax==0, eax = *0x109ba744 → default to main thread ID global
11aec-11af4: push eax, 0, 0x1f03ff
            call *[IAT] → OpenThread(THREAD_ALL_ACCESS, FALSE, threadId) → edi=handle
11afe: if edi==NULL: jump to exit (11b57)

11b00: push 0x20 (32 bytes)
11b02: call 0x4d8348            → operator new(32) → esi = heap closure copy
11b19: [esi] = 0
11b1f: eax = [esp+0x18]         → 1st arg: boost::function&
11b27: [esi] = eax              → copy function ptr into heap block
11b33: eax = [edx]              → vtable of boost::function
11b3a: call *[vtable+0]         → boost::function::clone into esi+8

11b43-11b4a: push esi, edi, 0x10011a30
             call *[IAT] → QueueUserAPC(APCProc=0x10011a30, thread=edi, param=esi)
11b50: push edi / call *[IAT]   → CloseHandle(edi)
```

### Analysis
- Opens target thread by ID, allocates 32-byte heap block, clones the boost::function closure into it
- Posts via `QueueUserAPC` — the APC proc at `0x10011a30` fires in the target thread's context during any alertable wait (`SleepEx`, `WaitForSingleObjectEx`, `MsgWaitForMultipleObjectsEx`)
- **No mutex or lock** — pure APC-based dispatch, zero contention
- `threadId=0` → defaults to main thread (a global at `0x109ba744`)
- The target thread must call alertable waits for APCs to drain

**Key finding for multi-core AI**: `THREAD_InvokeAsync` is the dispatch primitive. It accepts **any thread ID** — not restricted to specific thread types. If we can identify a CTaskThread's OS thread ID, we can post work to it from Lua (via a native shim) and have it execute asynchronously.

---

## F: CTask Constructor (RVA 0x86e0) — objdump disassembly

### Raw disassembly (0x86e0–0x8726)
```
86e0: push esi / mov esi, ecx    → esi = this
86e3: call 0x6670                → base class ctor (CTaskEvent or similar)
86e8: mov ecx, 0x1
86ed: add eax, 0x24              → eax = &(something->refcount at +0x24)
86f0: lock xadd [eax], ecx      → interlocked increment of refcount
86f8: eax = [esp+0x8]           → 1st arg: CTaskThread* thread
86fc: movl [esi], 0x1071dfb0    → set vtable pointer
8702: zero [esi+8], [esi+0xc], [esi+0x10]
870b: zero [esi+0x14]           → zero bool field
870e: je 0x8723                 → if thread==NULL: skip linking
8710: dl = [esp+0xc]            → 2nd arg: bool (active?)
8714: [esi+0x14] = dl
8717: [esi+0xc] = eax           → this->thread = thread
871a: ecx = [eax+0x10]          → thread->taskList.tail
871d: [esi+0x10] = ecx          → this->next = tail
8720: [eax+0x10] = esi          → thread->taskList.tail = this (intrusive list insert)
8723: return this
```

### Analysis
- `CTask::CTask(CTaskThread* thread, bool active)` — links this task into thread's intrusive task list
- If `thread == NULL`, task is created unbound (floats until assigned)
- The `lock xadd` increments a ref count on the CTaskThread at offset +0x24 — thread is ref-counted
- Object layout: `[vtable][padding][?][thread*][next*][active_bool]` at offsets 0,4,8,0xc,0x10,0x14
- This constructor doesn't reveal pool size — need to find CTaskThread pool init (Sim::Create or engine startup)

---

## G: APC Proc at 0x10011a30 — objdump disassembly

The APC proc executes in the target thread's context when that thread calls an alertable wait.

```
11a30: push esi
11a31: esi = [esp+8]         → APC param = closure ptr (heap block from InvokeAsync)
11a35: ecx = esi / call 0x11db0  → some function on the closure (maybe AddRef or init)
11a3c: test esi,esi
11a3e: je 0x11a67            → if null: free and return

11a40: eax = [esi]           → function ptr in closure
11a42: test eax,eax
11a44: je 0x11a5e            → if no function: free and return
11a46: eax = [eax]           → vtable of boost::function
11a48: test eax,eax
11a4d: lea ecx,[esi+8]       → closure data at +8 (the boost::function storage)
11a4f: push 1
11a51-11a53: push ecx,ecx
11a53: call *[eax]           → invoke boost::function(esi+8) — the actual closure call

; after call:
11a58: [esi] = 0             → clear function ptr
11a5e: push esi
11a5f: call 0x4d8352         → operator delete(esi) — free the 32-byte heap block
11a67: pop esi / ret 4
```

### Analysis
- APC proc: receives heap closure ptr, calls the boost::function stored in it, then frees the memory
- Clean lifecycle: alloc in `InvokeAsync` → execute in `APCProc` → free in `APCProc`
- No error handling beyond null checks — if the function throws, it propagates to the target thread's exception handler
- The `call *[eax]` at 11a53 is the actual work dispatch — any callable can be injected here

---

## H: CTaskThread Pool — Spawn Site Inventory

### All 8 `_beginthreadex` callsites

`_beginthreadex` is called at exactly **one place** (0x4db150 = CTaskThread spawn wrapper). That wrapper is called from 8 sites:

| Caller offset | Identified thread | Evidence |
|---------------|-------------------|----------|
| `0x10fb5` | Background task base (CTaskThread infrastructure) | "Starting background task", "Pausing background task" strings |
| `0x832d4` | Unknown — likely PathQueue or IssueThread | No nearby name string; interlocked ops suggest critical subsystem |
| `0xa2cda` | **Prefetcher thread** | "Prefetcher thread." string directly before spawn |
| `0x30be97` | Unknown — likely Sim_Sync | Near sim beat strings |
| `0x30db7f` | **Sim_Dispatch thread** | "Sim_Dispatch", "Sim - Dispatch" strings |
| `0x3800d2` | Network thread 1 (GPG.net) | "Already connected.", "Gpg.net not connected" |
| `0x38022c` | Network thread 2 (GPG.net) | "Gpg.net not connected" x3 |
| `0x4db614` | Pool/wrapper helper | Called inside a 12-byte object constructor (wrapper around spawn) |

### Key finding: hardcoded pool of 8 threads

The engine spawns exactly **8 CTaskThread workers** total — no dynamic pool expansion. Breakdown (confirmed + estimated):
1. Sim_Dispatch — beat processing
2. Sim_Sync (probable) — beat gating
3. Prefetcher — asset streaming
4. PathQueue (probable) — async pathfinding
5. IssueThread (probable) — AI/Lua command queuing
6. Network thread 1 — GPG.net lobby
7. Network thread 2 — GPG.net lobby
8. Generic background task pool (may cover multiple)

The sim thread itself is the **main thread** (or a thread launched by SupremeCommander.exe), not one of these 8.

### SetThreadAffinityMask callers

| Callsite | Where | What |
|----------|-------|------|
| `0x1215d` | `THREAD_SetAffinity` exported fn | Exported API — pins caller's thread to lowest/highest available core |
| `0x30d986` | Sim thread startup | Pins the Sim thread to a core, then calls SetThreadName("Sim") |

The Sim thread pins itself at startup using the same bit-scan logic as `THREAD_SetAffinity`. The 8 CTaskThread workers likely call `THREAD_SetAffinity(false)` to pin themselves to the highest available cores, leaving core 0 for the sim.

---

## Synthesis: Multi-Core AI Path

### What we now know

| Finding | Implication |
|---------|-------------|
| `THREAD_InvokeAsync` accepts **any thread ID** | We can post work to any existing CTaskThread |
| APC proc frees memory after call | Zero-leak dispatch — safe to use from a shim |
| Pool is 8 threads, hardcoded | Can't expand the pool without patching spawn count |
| Sim thread pins to core 0; THREAD_SetAffinity(false) → highest core | Existing threads spread across cores already |
| All Lua (AI) runs as coroutines on sim thread | Cannot parallelize Lua logic itself |
| `GetProcessAffinityMask` drives affinity dynamically | More cores in the affinity mask = more spread |

### Viable approaches for multi-core AI

**Option A — Native shim DLL (most practical)**
- Inject a patch DLL that creates 1–4 dedicated worker threads (outside CTaskThread pool)
- Expose a Lua C function `OffloadToWorker(fn_name, args)` that marshals work to a worker thread
- Worker thread posts result back to Sim thread via `THREAD_InvokeWait` or a semaphore
- Work that's safe: threat map recalculation, economy projection, build order scoring (read-only queries, results fed back before next beat)
- Risk: determinism — offloaded work must produce same result regardless of scheduling (pure functions only)

**Option B — Reuse CTaskThread idle time**
- The Prefetcher thread and network threads likely spend significant time in alertable sleeps
- `THREAD_InvokeAsync(closure, threadId)` can post work to them via QueueUserAPC
- Challenge: need to discover their thread IDs at runtime; may conflict with their own work

**Option C — Widen process affinity mask**
- Simply call `SetProcessAffinityMask` to allow more cores (in case the process was launched with a restricted mask)
- `THREAD_SetAffinity` already uses `GetProcessAffinityMask` — adding cores would automatically spread existing threads
- Low risk, can be done from Lua via a native function or Windows registry tweak
- Won't add new parallelism, but ensures existing threads use all available cores

### Recommended next step

**Option A** with pure-function offloading. The threat map (`AssignThreatAtPosition`, `GetThreatAtPosition`) is the main CPU consumer in M28AI and is read-only during computation — it can be computed on a worker thread and written back to the Lua state between beats.

---

## Next Steps

- [ ] Identify the 3 unknown thread spawns (0x832d4, 0x30be97, 0x4db614) — need their thread names to confirm IssueThread/PathQueue
- [ ] Find where the CTaskThread stores its OS thread ID — needed to call `THREAD_InvokeAsync` targeting specific workers
- [ ] Profile a live 4v4 game — confirm sim thread CPU% vs others, and measure alertable sleep time on Prefetcher/network threads
- [ ] Design native shim: a FAF patch DLL that spawns N worker threads and exposes `OffloadCompute(fn, args)` to Lua
- [ ] Test Option C first (widen affinity mask) as a zero-risk quick win

---

## I: Unknown Thread Spawn Sites — Resolved

| Spawn offset | Identity | Evidence |
|---|---|---|
| `0x30be97` | **IssueThread** | Same function (starts 0x30bb90) contains "IssueThread -- running", "IssueThread -- waiting", "ISSUE: thread awaking…" strings |
| `0x832d4` | **CNetUDPConnector thread** (3rd network thread) | Surrounded by CNetUDPConnector, packet log, and UDP recv strings |
| `0x4db614` | **Pool utility wrapper** | Generic helper called via vtable; no distinguishing strings; wraps a single CTaskThread spawn in a 12-byte manager object |

### Final thread inventory (all 8 CTaskThread workers)

| # | Thread | Spawn offset |
|---|--------|---|
| 1 | IssueThread | 0x30be97 |
| 2 | Sim_Dispatch | 0x30db7f |
| 3 | Prefetcher | 0xa2cda |
| 4 | CNetUDPConnector 1 | 0x832d4 |
| 5 | CNetUDPConnector 2 | 0x3800d2 |
| 6 | CNetUDPConnector 3 | 0x38022c |
| 7 | Background task infra | 0x10fb5 |
| 8 | Pool wrapper (generic) | 0x4db614 |

Note: PathQueue background thread is NOT in this list — it may use CreateThread directly (at 0x53b4a2, the one CreateThread callsite) or run on an existing CTaskThread via the stage scheduler.
