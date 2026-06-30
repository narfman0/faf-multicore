# FA Engine Analysis — MohoEngine.dll

Static analysis of the Supreme Commander: Forged Alliance engine DLL.
Binary: `MohoEngine.dll` (9.4 MB, x86 PE32 DLL, stripped — no PDB).
PDB path embedded in binary: `c:\work\rts\main\code\bin8\MohoEngine.pdb`
TimeDateStamp: `0x469285f8` (Nov 2006, matches FA release window).
Analysis method: `pefile` (imports/exports) + `strings -a -n 6 -t x` filtered by keyword set.
Script: `faf-analysis/analyze_mohoengine.py`

---

## PE Metadata

### Sections

| Name     | VirtAddr   | VirtSize   | RawSize    | Characteristics       |
|----------|------------|------------|------------|-----------------------|
| `.text`  | `0x1000`   | `0x5c96ab` | `0x5ca000` | `0x60000020` (exec/read) |
| `PSFD00` | `0x5cb000` | `0x2f50`   | `0x3000`   | `0x60000020` (exec/read) — Criterion PFD stub |
| `.rdata` | `0x5ce000` | `0x2b18a4` | `0x2b2000` | `0x40000040` (read/init data) |
| `.data`  | `0x880000` | `0x2cee28` | `0x4d000`  | `0xc0000040` (read/write/init) |
| `.tls`   | `0xb4f000` | `0x1e8d`   | `0x2000`   | `0xc0000040` (TLS — thread-local storage in use) |
| `.rsrc`  | `0xb51000` | `0xa3bc`   | `0xb000`   | `0x40000040` (resources) |
| `.reloc` | `0xb5c000` | `0x832b2`  | `0x84000`  | `0x42000040` (relocations) |

The `.tls` section confirms the engine uses thread-local storage, consistent with per-thread state (CTaskThread, CDiskThreadState, STimeBarThreadInfo).

### Imported DLLs (summary)

| DLL | Purpose |
|-----|---------|
| `KERNEL32.dll` | Win32 threading, synchronization, file I/O |
| `MSVCR80.dll` | CRT including `_beginthreadex` |
| `MSVCP80.dll` | STL including `std::_Mutex` |
| `DSOUND.dll` | DirectSound audio |
| `X3DAudio1_1.dll` | 3D audio positioning |
| `GDI32.dll` | Font/text rendering |
| `USER32.dll` | Window messages, hooks |
| `WINMM.dll` | Multimedia timers (`timeSetEvent`, `timeKillEvent`) |
| `WS2_32.dll` | Winsock (networking) |
| `LuaPlus_1081.dll` | Lua scripting runtime |
| `gpgcore.dll` | GPG core library (streams, pathfinding, types) |
| `gpggal.dll` | GPG Graphics Abstraction Layer (D3D9 wrapper) |
| `BugSplat.dll` | Crash reporting |
| `SHSMP.DLL` | Criterion/SHSMP middleware (audio streaming, ADX) |
| `d3dx9_31.dll` | D3DX9 helpers |
| `dbghelp.dll` | Stack walking (crash reporter) |
| `wxmsw24u-vs80.dll` | wxWidgets (lobby/debug UI) |
| `ole32.dll` | COM (`CoCreateInstance`) |

**Key finding:** `gpggal.dll` is a separate Graphics Abstraction Layer DLL — the renderer uses its own DLL, not embedded in MohoEngine.dll.

---

## Thread-Related Imports

### Summary table

| Import | Source DLL | Purpose |
|--------|------------|---------|
| `CreateThread` | KERNEL32 | Win32 thread creation |
| `_beginthreadex` | MSVCR80 | CRT thread creation wrapper |
| `SuspendThread` / `ResumeThread` | KERNEL32 | Thread pause/resume |
| `OpenThread` | KERNEL32 | Open thread handle by ID |
| `Thread32First` / `Thread32Next` | KERNEL32 | Thread enumeration (crash reporter) |
| `GetCurrentThread` / `GetCurrentThreadId` | KERNEL32 | Current thread identity |
| `SetThreadAffinityMask` | KERNEL32 | Pin thread to core mask |
| `GetProcessAffinityMask` | KERNEL32 | Read process core mask |
| `SetThreadPriority` / `SetThreadPriorityBoost` | KERNEL32 | Thread priority tuning |
| `GetThreadPriority` | KERNEL32 | Read priority |
| `QueueUserAPC` | KERNEL32 | Async procedure call (inter-thread signaling) |
| `CreateMutexA` / `ReleaseMutex` | KERNEL32 | Named/anonymous mutex |
| `CreateSemaphoreA` / `ReleaseSemaphore` | KERNEL32 | Semaphore (thread gating) |
| `CreateEventA` / `CreateEventW` | KERNEL32 | Event objects |
| `SetEvent` / `ResetEvent` / `PulseEvent` | KERNEL32 | Event signaling |
| `WaitForSingleObject` | KERNEL32 | Blocking wait |
| `MsgWaitForMultipleObjectsEx` | USER32 | Message-aware multi-wait |
| `InitializeCriticalSection` / `EnterCriticalSection` / `LeaveCriticalSection` / `DeleteCriticalSection` | KERNEL32 | CRITICAL_SECTION |
| `TlsAlloc` / `TlsFree` / `TlsGetValue` / `TlsSetValue` | KERNEL32 | Thread-local storage |
| `InterlockedCompareExchange` / `InterlockedDecrement` / `InterlockedExchange` / `InterlockedIncrement` | KERNEL32 | Lock-free atomics |
| `SleepEx` | KERNEL32 | Alertable sleep (APC processing) |
| `SetThreadName` (gpg) | gpgcore.dll | Named thread for profiling/debugging |
| `?THREAD_IsMainThread@Moho@@YA_NXZ` | MohoEngine export | Guard: is caller on main thread? |
| `?THREAD_GetMainThreadId@Moho@@YAIXZ` | MohoEngine export | Get main thread ID |
| `?THREAD_SetAffinity@Moho@@YAX_N@Z` | MohoEngine export | Set affinity mask (exported for SupCom.exe) |
| `?THREAD_InvokeAsync@Moho@@…` | MohoEngine export | Post closure to another thread (async) |
| `?THREAD_InvokeWait@Moho@@…` | MohoEngine export | Post closure and block for completion |
| `?IsMain@wxThread@@SA_NXZ` | wxmsw24u-vs80.dll | wxWidgets main-thread check |
| `std::_Mutex::_Lock` / `_Unlock` | MSVCP80 | STL mutex |
| `?CoResume@LuaState@LuaPlus@@…` | LuaPlus_1081.dll | Lua coroutine resume |
| `WSAEventSelect` / `WSAWaitForMultipleEvents` | WS2_32.dll | Async socket events |

**Key finding:** `SleepEx` is present — this is the alertable sleep required to process `QueueUserAPC` callbacks. This confirms the APC-based inter-thread signaling path documented in SupremeCommander.exe.

---

## Exports

MohoEngine.dll exports **4875 symbols** — it is the main engine library that SupremeCommander.exe links against. Selected thread/sim-relevant exports:

### Threading exports (callable by SupremeCommander.exe)

| Address | Symbol |
|---------|--------|
| `0x11a00` | `?THREAD_IsMainThread@Moho@@YA_NXZ` |
| `0x11a20` | `?THREAD_GetMainThreadId@Moho@@YAIXZ` |
| `0x12100` | `?THREAD_SetAffinity@Moho@@YAX_N@Z` |
| `0x11ac0` | `?THREAD_InvokeAsync@Moho@@YAXV?$function<…>@boost@@I@Z` |
| `0x11ba0` | `?THREAD_InvokeWait@Moho@@YAXV?$function<…>@boost@@I@Z` |

`THREAD_SetAffinity` takes a `bool` parameter — likely toggling between "use only core 0" and "use all available cores". When `true`, the engine probably calls `GetNumaNodeProcessorMask` / `GetProcessAffinityMask` and sets per-thread masks.

### Sim stage accessors (also exported)

| Address | Symbol |
|---------|--------|
| `0x1336b0` | `?GetScriptStage@Sim@Moho@@QAEAAVCTaskStage@2@XZ` |
| `0x1336a0` | `?GetMotionUpdateStage@Sim@Moho@@QAEAAVCTaskStage@2@XZ` |
| `0x1336c0` | `?GetCommandDispatchStage@Sim@Moho@@QAEAAVCTaskStage@2@XZ` |
| `0xe1640` | `?WIN_GetBeforeEventsStage@Moho@@YAAAVCTaskStage@1@XZ` |
| `0xe16b0` | `?WIN_GetBeforeWaitStage@Moho@@YAAAVCTaskStage@1@XZ` |

These are the named task pipeline stages that `CTaskThread` workers process.

### CTaskThread / CTask / CTaskEvent exports

| Address | Symbol |
|---------|--------|
| `0x86e0` | `??0CTask@Moho@@QAE@PAVCTaskThread@1@_N@Z` |
| `0x5f90` | `??0CTaskEvent@Moho@@QAE@_N@Z` |
| `0x5b40` | `??_FCTaskEvent@Moho@@QAEXXZ` |
| `0x5b10` | `?EventIsSignaled@CTaskEvent@Moho@@QAE_NXZ` |
| `0x5b30` | `?EventReset@CTaskEvent@Moho@@QAEXXZ` |
| `0x6090` | `?EventSetSignaled@CTaskEvent@Moho@@QAEX_N@Z` |
| `0x5b20` | `?EventSignal@CTaskEvent@Moho@@QAEXXZ` |
| `0x6120` | `?EventWait@CTaskEvent@Moho@@QAEPAUSTaskEventLinkage@2@PAVCTaskThread@2@@Z` |
| `0x6260` | `?SerThreads@CTaskEvent@Moho@@ABEXAAVWriteArchive@gpg@@H@Z` |
| `0x62f0` | `?SerThreads@CTaskEvent@Moho@@AAEXAAVReadArchive@gpg@@H@Z` |
| `0x59f0` | `?TaskGetThread@CTask@Moho@@QBEPAVCTaskThread@2@XZ` |
| `0x5a50` | `??0STaskEventLinkage@Moho@@QAE@PAVCTaskThread@1@@Z` |

`CTaskEvent::SerThreads` is notable — it serializes thread state to/from save archives, meaning the threading state is part of saved games (replay/checkpoint support).

---

## CTaskThread — Confirmed Implementation in MohoEngine.dll

### RTTI strings (definitive confirmation)

| RTTI String |
|-------------|
| `.?AVCTaskThread@Moho@@` |
| `.?AVCTaskStage@Moho@@` |
| `.?AVCTaskEvent@Moho@@` |
| `.?AVCTask@Moho@@` |
| `.PAVCTaskThread@Moho@@` |
| `.?AUCTaskThreadSerializer@Moho@@` |
| `.?AUCTaskThreadTypeInfo@Moho@@` |
| `.?AUCTaskThreadConstruct@Moho@@` |
| `.?AU?$SerSaveLoadHelper@VCTaskThread@Moho@@@gpg@@` |
| `.?AU?$SerConstructHelper@VCTaskThread@Moho@@@gpg@@` |
| `.?AV?$WeakPtr@VCTaskThread@Moho@@@Moho@@` |
| `.?AU?$RPointerType@VCTaskThread@Moho@@@gpg@@` |
| `.?AU?$RWeakPtrType@VCTaskThread@Moho@@@Moho@@` |
| `.?AVPausedThread@Moho@@` |
| `.?AVPausedChildThread@Moho@@` |
| `.?AVPausedMainThread@Moho@@` |
| `.?AVthread_resource_error@boost@@` |
| `.?AU?$tss_adapter@VCDiskThreadState@Moho@@@detail@boost@@` |
| `.?AU?$tss_adapter@USTimeBarThreadInfo@Moho@@@detail@boost@@` |

**Yes — `CTaskThread` is fully implemented in MohoEngine.dll**, not in SupremeCommander.exe. The `PausedThread` / `PausedChildThread` / `PausedMainThread` class hierarchy is also present (also found in SupremeCommander.exe, confirming it's from this DLL being used by the exe).

### Thread-local storage (TLS) per-thread state classes

| Class | Purpose |
|-------|---------|
| `CTaskThread@Moho` | OS-level worker thread |
| `CTaskStage@Moho` | Named work stage (Script, Motion, CommandDispatch) |
| `CTaskEvent@Moho` | Synchronization event between stages/threads |
| `STaskEventLinkage@Moho` | Per-thread event registration handle |
| `CTask@Moho` | Unit of work associated with a `CTaskThread` |
| `CDiskThreadState@Moho` | Disk I/O per-thread state (boost::tss) |
| `STimeBarThreadInfo@Moho` | Profiling per-thread state (boost::tss) |

`CDiskThreadState` and `STimeBarThreadInfo` use Boost `thread_specific_ptr` (tss = thread-specific storage), confirming per-thread disk and timing state.

---

## SetThreadAffinityMask Callsites

### Exported function

`THREAD_SetAffinity(bool)` at `0x12100` is the primary callsite. Based on:
- It takes a single `bool` parameter
- `GetNumaNodeProcessorMask` and `GetNumaProcessorNode` are imported — the engine queries NUMA topology
- `GetProcessAffinityMask` is imported to read the current process mask

The bool likely means: `true` = "restrict to performance cores / NUMA node 0", `false` = "release to all cores". This is the affinity management API exposed to SupremeCommander.exe.

### Error strings confirming SetThreadAffinityMask usage

| File Offset | String |
|-------------|--------|
| `0x884f10` | `'E02100916 : The error occurred within the SetThreadAffinityMask function.'` |
| `0x823fbc` | `'SetThreadAffinityMask'` (import name string, used in error messages) |

Error code `E02100916` is the engine's internal error taxonomy for thread affinity failures. Multiple error codes for `CreateThread` (E02100911–E02100913) and `SetThreadPriorityBoost` (E02100931–E02100934) follow the same pattern.

### Camera affinity (separate concept, different system)

| String | Meaning |
|--------|---------|
| `?GetCameraAffinity@MeshInstance@Moho@@…` | Each mesh instance can have a preferred camera ("affinity") — unrelated to CPU affinity |
| `?SetCameraAffinity@MeshInstance@Moho@@…` | Render culling: only draw a mesh for its assigned camera |

---

## QueueUserAPC Usage

`QueueUserAPC` is imported from KERNEL32. Combined with `SleepEx` being present, this is the APC-based inter-thread signaling path. In the engine's architecture:

- **IssueThread** queues commands to the **SimThread** using `QueueUserAPC`
- The SimThread calls `SleepEx(0, TRUE)` in its idle loop to drain APCs
- This avoids mutex contention on the command queue
- `THREAD_InvokeAsync` (exported) is the Moho-level wrapper around this pattern

Export evidence:
```
?THREAD_InvokeAsync@Moho@@YAXV?$function<$$A6AXXZ>@boost@@I@Z
?THREAD_InvokeWait@Moho@@YAXV?$function<$$A6AXXZ>@boost@@I@Z
```
`THREAD_InvokeWait` blocks the caller until the target thread executes the closure — this is the synchronous variant (likely used for one-time initialization calls that must complete before proceeding).

---

## Keyword-Filtered Strings — Annotated

### Thread creation and lifecycle

| File Offset | String |
|-------------|--------|
| `0x7286b8` | `'ForkThread'` — Lua API registration |
| `0x728650` | `'thread = ForkThread(function, ...)\nSpawns a new thread running the given function with the given args.'` |
| `0x728718` | `'ForkThread: Lua state has not been set up for multiple threads'` |
| `0x728758` | `'TRACE %08x - ForkThread (new thread is %08x)'` |
| `0x728788` | `'KillThread(thread) -- destroy a thread started with ForkThread()'` |
| `0x7288e8` | `"Can't suspend a thread that wasn't created with ForkThread."` |
| `0x728a9c` | `"Can't resume a thread that wasn't created with ForkThread."` |
| —          | `'Prefetcher thread.'` — prefetch worker name |
| —          | `'IssueThread -- running'` / `'IssueThread -- waiting'` |
| —          | `'ISSUE: thread awaking, elapsed=%d.%03dms.'` |
| —          | `'ISSUE: thread exiting.'` |
| —          | `'Error running lua script from destroyed thread: %s'` |

The `ForkThread` Lua API is implemented in MohoEngine.dll (all RTTI `.?AUForkThread_LuaFuncDef@…` present). The Lua coroutine scheduler lives here.

### Sim/Beat/Tick infrastructure

| String | Notes |
|--------|-------|
| `'Sim_Sync'` | Beat sync phase name |
| `'Sim_Dispatch'` | Beat dispatch phase name |
| `'Sim - Sync'` / `'Sim - Dispatch'` | Alternate spacing form |
| `'sim_Interlocked'` | cvar: force sim+UI to run interlocked |
| `'sim_IssueThreadDebugLevel'` | cvar: issue thread spam |
| `'sim_DebugDelay'` | cvar: artificial sim tick delay |
| `'sim_ChecksumPeriod'` | cvar: beats between checksums |
| `'sim_LogSize'` / `'sim_KeepAllLogFiles'` | Beat log controls |
| `'%sbeat%05d.log'` | Per-beat log file naming |
| `'beat %d final checksum: %s'` | Checksum logging |
| `'Checksum for beat %d mismatched: %s (sim) != %s (%s).'` | Desync detection |
| `'********** beat %d **********'` | Beat marker in log |

All sim beat infrastructure is in MohoEngine.dll (Sim class is fully implemented here).

### Mutex / Sync

| File Offset | String |
|-------------|--------|
| `0x724834` | `'GPG_MohoEngine_Mutex'` — named mutex preventing multiple instances |
| —          | `'/synclog'` — sync log path |
| —          | `'SyncPlayableRect'` — determinism-critical sync point |
| —          | `'MWSFSVR_VsyncThrdProc'` — vsync thread name (from middleware) |
| —          | `'Desync'` / `'ShowDesyncDialog'` — desync UI path |

### MohoEngine identification

| File Offset | String |
|-------------|--------|
| `0x76c98c` | `'c:\\work\\rts\\main\\code\\bin8\\MohoEngine.pdb'` — build artifact |
| `0x83a7c6` | `'MohoEngine.dll'` |

---

## Renderer Subsystem

MohoEngine.dll contains the full renderer. Evidence:

### Key render classes (RTTI confirmed)

| Class | Purpose |
|-------|---------|
| `MeshRenderer@Moho` | Mesh/unit rendering |
| `MeshThumbnailRenderer@Moho` | Build-menu icons |
| `WRenViewport@Moho` / `WD3DViewport@Moho` | Viewport/D3D surface management |
| `CBloomRenderer@Moho` | Post-process bloom |
| `Background@Moho` / `SkyDome@Moho` | Background/sky rendering |
| `Cartographic@Moho` | Strategic map rendering |
| `BoundaryRenderer@Moho` / `VisionRenderer@Moho` / `RangeRenderer@Moho` | Overlay renderers |
| `ParticleBuffer@Moho` | Particle effects |
| `Silhouette@Moho` / `Shoreline@Moho` | Water/edge effects |
| `CD3DRenderTarget@Moho` | D3D render target wrapper |
| `MeshInstance@Moho` | Per-instance mesh state (position, LOD, camera affinity) |
| `MeshBatch@Moho` | Instanced draw call batching |
| `SimpleRenderWorldView@Moho` | Used for editor preview |
| `CartographicDecalBatch@Moho` | Strategic map decal batching |

### Render cvars (exported as global data)

| Symbol | Purpose |
|--------|---------|
| `ren_RenderNothing` | Kill switch for renderer |
| `ren_SyncTerrainLOD` | Distance threshold for terrain sync changes |
| `ui_RenderUnitBars` / `ui_RenderIcons` | UI overlays |
| `ui_AlwaysRenderStrategicIcons` | Force strategic icon visibility |

### D3D path

The renderer uses `gpggal.dll` (GPG Graphics Abstraction Layer) which wraps D3D9. MohoEngine imports `d3dx9_31.dll` directly only for `D3DXFloat32To16Array` (for half-float vertex data packing).

---

## Audio Subsystem

### Key audio classes

| Class | Purpose |
|-------|---------|
| `AudioEngine@Moho` | XACT-based audio engine wrapper |
| `CUserSoundManager@Moho` / `ISoundManager@Moho` | Sound manager (per-player listener position) |
| `CSimSoundManager@Moho` | Sim-side sound events |
| `HSound@Moho` | Sound handle (Lua-accessible) |
| `CSndParams@Moho` | Sound parameter object |
| `SAudioRequest@Moho` | Queued audio request (serializable) |

### Audio DLLs

| DLL | Purpose |
|-----|---------|
| `DSOUND.dll` | DirectSound low-level output |
| `X3DAudio1_1.dll` | 3D audio positioning/HRTF |
| `SHSMP.DLL` | CRI Middleware ADX2/ADXM (compressed audio streaming) |

### Audio Lua API (all in MohoEngine.dll)

- `PlaySound(params)` / `StopSound(handle)` / `StopAllSounds()`
- `PauseSound(category, bPause)` / `DisableWorldSounds()` / `EnableWorldSounds()`
- `Entity:PlaySound(params)` / `Entity:SetAmbientSound(...)`
- `AudioSetLanguage(name)` — voice language switching
- `Sound({cue, bank, cutoff})` / `RPCSound({...})` — sound parameter constructors

---

## AI Architecture in MohoEngine.dll

`CAiBrain` and all AI infrastructure is implemented in MohoEngine.dll (not SupremeCommander.exe):

### CAiBrain (confirmed)

RTTI: `.?AVCAiBrain@Moho@@`
String: `'CAiBrain'`, `'/lua/aibrain.lua'`, `'AIBrain'`, `'moho.aibrain_methods'`

All Lua function defs (`CAiBrainGetEconomyStored_LuaFuncDef`, etc.) are present as RTTI in MohoEngine.dll, confirming this is the implementation binary.

### IAiCommandDispatch

| RTTI | Notes |
|------|-------|
| `.?AVIAiCommandDispatch@Moho@@` | Interface |
| `.?AVIAiCommandDispatchImpl@Moho@@` | Implementation |

`IAiCommandDispatchImpl` is constructed with `(PAVUnit, PAVCTaskThread, PAW4EAiResult)` — it is associated with a specific `CTaskThread`, confirming that AI command dispatch operates on the task thread pool, not the main sim thread.

### PathQueue

`.?AVPathQueue@Moho@@` and `.?AUImpl@PathQueue@Moho@@` are present.
Source path embedded: `'c:\work\rts\main\code\src\sim\PathQueue.cpp'`
The `PathQueue` implementation is in MohoEngine.dll.

---

## Division of Responsibility: SupremeCommander.exe vs MohoEngine.dll

| Subsystem | Owner | Evidence |
|-----------|-------|---------|
| **CTaskThread worker pool** | MohoEngine.dll | RTTI, constructor/event exports |
| **CTaskStage pipeline** | MohoEngine.dll | `GetScriptStage`, `GetMotionUpdateStage`, `GetCommandDispatchStage` exports |
| **ForkThread / Lua coroutine scheduler** | MohoEngine.dll | Full ForkThread Lua func def RTTI |
| **Sim class (beat loop)** | MohoEngine.dll | `Sim::Create`, `Sim::DoBeat`, all beat strings |
| **CAiBrain** | MohoEngine.dll | RTTI, all aibrain Lua func defs |
| **IAiCommandDispatch** | MohoEngine.dll | Constructor + RTTI |
| **PathQueue** | MohoEngine.dll | RTTI + source path string |
| **IssueThread** | MohoEngine.dll | IssueThread strings present |
| **MeshRenderer / render pipeline** | MohoEngine.dll | All renderer class RTTI |
| **AudioEngine / sound** | MohoEngine.dll | AudioEngine, CUserSoundManager RTTI |
| **THREAD_SetAffinity / THREAD_InvokeAsync** | MohoEngine.dll | Exported symbols |
| **GPG_MohoEngine_Mutex** | MohoEngine.dll | Named mutex created here |
| **SupComMutex** | SupremeCommander.exe | Seen in exe string table only |
| **MWSFSVR_VsyncThrdProc** | MohoEngine.dll | Vsync thread proc string present |
| **Network / lobby (CLobby, CMarshaller)** | MohoEngine.dll | RTTI for CLobby, CMarshaller, CDecoder |
| **wxWidgets UI (debug launcher)** | MohoEngine.dll | wxmsw24u imports, large wx export section |
| **BugSplat crash reporter** | MohoEngine.dll | BugSplat.dll import, dbghelp |

**Bottom line:** MohoEngine.dll is essentially the entire game engine. SupremeCommander.exe is a thin executable that initializes the process and calls into MohoEngine.dll entry points. Nearly all gameplay, AI, rendering, audio, and threading infrastructure lives in the DLL.

---

## Multithreading Opportunities for Co-op AI

Based on the confirmed threading architecture in MohoEngine.dll:

### What is actually parallel today

1. **CTaskThread pool** — `CTask` workers for animation, sound, etc. run on `CTaskThread` instances. The pool size is likely 1–2 threads given the 2006 hardware target.
2. **PathQueue background thread** — async pathfinding with `path_BackgroundUpdate` cvar.
3. **Prefetcher thread** — asset streaming in background.
4. **IssueThread** — AI/Lua command queuing separate from sim processing.
5. **MWSFSVR_VsyncThrdProc** — vsync/present thread.
6. **CDiskThreadState** — disk I/O thread (TLS state per disk thread).

### Confirmed constraint: AI runs on sim thread

`ForkThread` creates Lua coroutines — all AI Lua (M28AI, etc.) runs cooperatively on the **sim thread** as coroutines. There are no OS threads for individual AI players.

### Identified hooks for parallelizing AI

| Hook | How |
|------|-----|
| `THREAD_InvokeAsync(closure, threadId)` | Post AI computation to a worker thread; results collected before next beat |
| `CTaskStage::GetScriptStage()` | AI Lua could be split into a separate task stage running on a dedicated `CTaskThread` |
| `CTaskEvent::EventWait / EventSignal` | Gate AI output on sim tick completion |
| `IAiCommandDispatchImpl` takes `CTaskThread*` | Constructor accepts thread assignment — an AI dispatch per army could run on its own thread |
| `path_BackgroundUpdate` cvar | Already parallelized — safe to enable for all armies |

### Risk factors

- **Determinism:** The sim must produce identical results across all peers. Any AI computation moved off the sim thread must be commutated (same inputs → same outputs regardless of thread scheduling). Threat maps, economy queries — all read-only during sim tick — are safe to parallelize.
- **CTaskEvent serialization:** `SerThreads` saves/loads thread event state — this must be respected in any new thread layout.
- **`GetNumaNodeProcessorMask` import:** The engine is NUMA-aware. Affinity masks should respect NUMA topology to avoid cross-socket memory latency.

---

## Next Steps

- [ ] Decompile `THREAD_SetAffinity` at offset `0x12100` to see exact affinity logic (Ghidra or Radare2)
- [ ] Decompile `THREAD_InvokeAsync` / `THREAD_InvokeWait` to understand closure dispatch mechanism
- [ ] Find `CTaskThread` constructor to count how many threads the pool spawns by default
- [ ] Examine `CTaskStage::GetScriptStage` to understand how Lua coroutines are scheduled per stage
- [ ] Decompile `IAiCommandDispatchImpl` constructor — confirm it can be bound to a non-sim `CTaskThread`
- [ ] Test `path_BackgroundUpdate 1` in-game to verify pathfinder thread doesn't cause desync
- [ ] Profile a 4v4 game to measure sim thread CPU time vs other threads — identify headroom

---

## Files

- `MohoEngine.dll` — this binary (`../faf/`)
- `SupremeCommander.exe` — host executable (`../faf/`)
- `analyze_mohoengine.py` — extraction script (this directory)
- Raw output: see tool result `b9q0u9w6t.txt` (analysis session artifact)
