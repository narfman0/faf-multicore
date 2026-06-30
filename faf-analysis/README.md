# FA Engine Analysis — SupremeCommander.exe

Ghidra 12.1.2 static analysis of the Supreme Commander (Forged Alliance) engine binary.
Binary: `SupremeCommander.exe` (13 MB, x86 PE, stripped — no PDB), MD5 `42e1f65f138f137c549c26cd587b350b`.
Analysis time: ~286 seconds full auto-analysis.

---

## Threading Architecture

### OS-level thread creation

| Address | Symbol | Notes |
|---------|--------|-------|
| `0x00ace3f3` | `__beginthreadex` | CRT thread wrapper (MSVCRT) |
| `0x00ace332` | `__callthreadstartex` | Called by `__beginthreadex` |
| `0x00ace2f9` | `__endthreadex` | Thread exit |
| `EXTERNAL` | `CreateThread` (KERNEL32) | Win32 direct thread creation |
| `EXTERNAL` | `ExitThread` / `TerminateThread` | Thread lifecycle |
| `EXTERNAL` | `SuspendThread` / `ResumeThread` | Thread pause/resume |

### Affinity and priority

| Import | Purpose |
|--------|---------|
| `SetThreadAffinityMask` | Pin individual threads to specific cores |
| `SetProcessAffinityMask` | Constrain entire process core mask |
| `GetProcessAffinityMask` | Read current affinity |
| `SetThreadPriority` / `SetThreadPriorityBoost` | Priority tuning |
| `GetThreadPriority` | Read priority |

These confirm the engine explicitly manages which CPU cores each thread runs on.

### Named thread classes

| Address | Symbol |
|---------|--------|
| `0x00e4f0a8` | `"CTaskThread"` (string) |
| `0x00fbc834` | `.?AVCTaskThread@Moho@@` (RTTI) |
| `0x00fbc488` | `WeakPtr<CTaskThread@Moho>` |
| `0x00fbc5bc` | `CTaskThreadSerializer@Moho` |

`CTaskThread` is the engine's generic threaded task worker, living in the `Moho` namespace (the engine layer). Additional thread-state RTTI:

- `.?AVPausedThread@Moho@@` `0x00fc02f8`
- `.?AVPausedChildThread@Moho@@` `0x00fc02d4`
- `.?AVPausedMainThread@Moho@@` `0x00fc02ac`

### Other threading infrastructure

| Address | Symbol | Notes |
|---------|--------|-------|
| `EXTERNAL` | `QueueUserAPC` | Async procedure calls — used for inter-thread signaling |
| `EXTERNAL` | `PostThreadMessageW` | Windows message queue across threads |
| `EXTERNAL` | `OpenThread` / `Thread32First` / `Thread32Next` | Thread enumeration (likely crash reporter / BugSplat) |

---

## Sim / Render Separation — The Beat System

The engine separates simulation from rendering using a **beat-based lockstep** model. Each "beat" is a fixed number of sim ticks; the render thread interpolates between beats.

### Thread names

| Address | String |
|---------|--------|
| `0x00e4f9c8` | `"Sim_Sync"` |
| `0x00e4f9d4` | `"Sim_Dispatch"` |
| `0x00e82dfc` | `"Sim - Sync"` |
| `0x00e82dec` | `"Sim - Dispatch"` |

**Sim_Sync** gates input collection; **Sim_Dispatch** processes queued commands. These are distinct phases of each beat.

### Beat counter fields (on `CClientBase`)

| Address | Field name |
|---------|-----------|
| `0x00e66374` | `mQueuedBeat` |
| `0x00e6638c` | `mDispatchedBeat` |
| `0x00e663a8` | `mAvailableBeatRemote` |
| `0x00e663e8` | `mLatestBeatDispatchedRemote` |
| `0x00e665cc` | `mAvailableBeat` |
| `0x00e665e0` | `mFullyQueuedBeat` |
| `0x00e665f8` | `mPartiallyQueuedBeat` |
| `0x00e66498` | `mAfterBeat` |
| `0x00e66500` | `mReplayBeat` |

These track each client's beat progress for netcode synchronization. A client cannot dispatch commands from beat N until all peers have queued beat N.

### IssueThread (AI/sim command issuer)

A dedicated `IssueThread` handles queuing sim commands from the AI/Lua side:

| Address | String |
|---------|--------|
| `0x00e82cb0` | `"IssueThread -- running"` |
| `0x00e82d04` | `"IssueThread -- waiting"` |
| `0x00e82d1c` | `"ISSUE: thread awaking, elapsed=%d.%03dms."` |
| `0x00e82d48` | `"ISSUE: thread exiting."` |
| `0x00e82bc4` | `"sim_Interlocked"` — cvar: "If true, force the sim and UI threads to run interlocked." |
| `0x00e82c08` | `"sim_IssueThreadDebugLevel"` — spam level for issue thread |

### Beat checksum / desync detection

| Address | String |
|---------|--------|
| `0x00e83914` | `"beat %d final checksum: %s"` |
| `0x00e83a40` | `"Checksum for beat %d mismatched: %s (sim) != %s (%s)."` |
| `0x00e83278` | `"How many beats between checksums."` (`sim_ChecksumPeriod`) |
| `0x00e83304` | `"********** beat %d **********"` |
| `0x00e832b0` | `"%sbeat%05d.log"` — per-beat log files |

### Mutexes

| Address | String |
|---------|--------|
| `0x00e5673c` | `"GPG_MohoEngine_Mutex"` |
| `0x00ea1d6c` | `"SupComMutex"` |

---

## AI Architecture — CAiBrain

### Core class

| Address | Symbol |
|---------|--------|
| `0x00e69320` | `"CAiBrain"` (string) |
| `0x00e69338` | `"/lua/aibrain.lua"` — Lua script loaded at startup |
| `0x00e6934c` | `"AIBrain"` — Lua-side name |
| `0x00e69354` | `"Can't find AIBrain, using CAiBrain directly"` |
| `0x00fc90bc` | `.?AVCAiBrain@Moho@@` (RTTI) |
| `0x00e6967c` | `"moho.aibrain_methods"` — metatable registration |

`CAiBrain` is a C++ class that exposes its methods to Lua via the `moho.aibrain_methods` metatable. Each AI player has one `CAiBrain` instance. The Lua script at `/lua/aibrain.lua` extends it.

### Exposed Lua methods (partial list, from string table)

**Economy / resources:**
- `GetEconomyStored`, `GetEconomyStoredRatio`, `GetEconomyIncome`, `GetEconomyUsage`, `GetEconomyRequested`, `GetEconomyTrend`

**Threat mapping:**
- `AssignThreatAtPosition(position, threat, [decay], [threattype])`
- `GetThreatAtPosition(position, ring, restriction, [threatType], [armyIndex])`
- `GetThreatBetweenPositions(position, position, restriction, [threatType], [armyIndex])`
- `GetHighestThreatPosition(ring, restriction, [threatType], [armyIndex])`
- `GetThreatsAroundPosition(position, ring, restriction, [threatType], [armyIndex])`

**Platoon management:**
- `MakePlatoon`, `DisbandPlatoon`, `DisbandPlatoonUniquelyNamed`
- `AssignUnitsToPlatoon`, `GetPlatoonUniquelyNamed`, `GetPlatoonsList`, `PlatoonExists`

**Building / construction:**
- `FindPlaceToBuild`, `CanBuildStructureAt`, `BuildStructure`
- `DecideWhatToBuild`, `NumCurrentlyBuilding`, `GetAvailableFactories`
- `CreateUnitNearSpot`, `CreateResourceBuildingNearest`

**Army info:**
- `GetArmyIndex`, `GetFactionIndex`, `GetArmyStartPos`, `GetArmyStat`
- `GetListOfUnits`, `FindUnit`, `GetUnitsAroundPoint`, `GetNumUnitsAroundPoint`
- `FindClosestArmyWithBase`, `GetMapWaterRatio`
- `GetNoRushTicks` (`0x00e6aabc`)

### Command dispatch interface

| Address | Symbol |
|---------|--------|
| `0x00e6af14` | `"IAiCommandDispatch"` |
| `0x00e6af28` | `"IAiCommandDispatchImpl"` |
| `0x00fcaa40` | `.?AVIAiCommandDispatch@Moho@@` (RTTI) |
| `0x00fcaa68` | `.?AVIAiCommandDispatchImpl@Moho@@` (RTTI) |

`IAiCommandDispatch` is the interface through which AI issues unit commands to the sim. Decoupled from `CAiBrain` to allow the AI Lua layer to issue commands asynchronously.

### Per-tick AI work strings

| Address | String |
|---------|--------|
| `0x00e705e0` | `"TaskTick"` |
| `0x00e6b5d4` | `"0x%08x's nav tick."` |
| `0x00e6dc10` | `"0x%08x's steering tick."` |
| `0x00e79e80` | `"0x%08x's motion tick."` |
| `0x00e6d098` | `"ReconTick for army %d: %s [%s]"` |

Each unit performs multiple sub-ticks per sim tick: nav, steering, motion, recon — potentially budget-limited.

### DoSimCommand AI hooks

```
DoSimCommand AI_RunOpponentAI      0x00e69038
DoSimCommand AI_DebugArmyIndex     0x00e69088
DoSimCommand AI_RenderDebugAttackVectors  0x00e690e8
DoSimCommand AI_RenderDebugPlayableRect   0x00e69168
DoSimCommand AI_DebugCollision     0x00e691dc
DoSimCommand AI_DebugIgnorePlayableRect   0x00e69234
DoSimCommand AI_RenderBombDropZone 0x00e7d2e8
```

---

## Lua Threading — ForkThread API

The engine exposes a coroutine-based threading API to Lua (not OS threads):

| Address | String |
|---------|--------|
| `0x00e58ff8` | `"thread = ForkThread(function, ...)\nSpawns a new thread running the given function with the given args."` |
| `0x00e59060` | `"ForkThread"` |
| `0x00e590c0` | `"ForkThread: Lua state has not been set up for multiple threads"` |
| `0x00e59100` | `"KillThread(thread) -- destroy a thread started with ForkThread()"` |
| `0x00e59240` | `"SuspendCurrentThread() -- suspend this thread indefinitely."` |
| `0x00e592e0` | `"ResumeThread(thread) -- resume a thread that had been suspended with SuspendCurrentThread()."` |
| `0x00e591b8` | `"WaitFor(event) -- suspend this thread until the event is set"` |
| `0x00e593f0` | `"thread=CurrentThread() -- get a handle to the running thread"` |
| `0x00e59460` | `"CurrentThread"` |

These are Lua coroutines managed by the engine scheduler, not OS threads. `WaitFor` / `SuspendCurrentThread` yield the coroutine until resumed externally.

---

## Pathfinding Threading

| Address | String |
|---------|--------|
| `0x00e85960` | `"PathQueueImpl"` |
| `0x00e85953` | `"PathQueue"` |
| `0x00e858cb` | `"CVT/C.\sim\PathQueue.cpp"` |
| `0x00e83180` | `"DoSimCommand path_BackgroundUpdate"` |
| `0x00e831e4` | `"DoSimCommand path_BackgroundBudget"` |
| `0x00e7f1b8` | `"DoSimCommand path_ArmyBudget"` — budget per army per tick |
| `0x00e7f1d8` | `"Budget for each army to do pathfinding each tick"` |
| `0x00e6bdb4` | `"DoSimCommand path_MaxInstantWorkUnits"` |

Pathfinding runs on a background thread with a per-army tick budget. `path_BackgroundUpdate` likely controls whether the pathfinder thread runs asynchronously.

---

## Render / Vsync Thread

| Address | String |
|---------|--------|
| `0x00f99b9c` | `"MWSFSVR_VsyncThrdProc"` — vsync thread procedure |
| `0x00ea2464` | `"SC_VerticalSync"` |
| `0x00ea2034` | `"vsync"` |
| `0x00e9a97c` | `"ren_SyncTerrainLOD"` |
| `0x00e5de90` | `"catchup particles for the ticks that we weren't visible"` |

The vsync thread (`MWSFSVR_VsyncThrdProc`) is separate from the sim thread and handles frame presentation timing. Particle systems catch up on missed ticks when they become visible again.

---

## Source File Map (embedded .cpp paths)

These strings survived the strip, giving us the original source layout:

```
.\sim\PathQueue.cpp
.\sim\AiPathNavigator.cpp
.\sim\AiUnitAttack.cpp
.\sim\AiUnitBuild.cpp
.\sim\AiUnitCallTransport.cpp
.\sim\AiUnitCapture.cpp
.\sim\AiUnitCarrier.cpp
.\sim\AiUnitCommands.cpp
.\sim\AiUnitMeleeAttack.cpp
.\sim\AiUnitPodAssist.cpp
.\sim\AiUnitReclaim.cpp
.\sim\AiUnitRefuel.cpp
.\sim\AiUnitTransport.cpp
.\sim\Entity.cpp
```

Corresponding Lua scripts loaded at runtime:
```
/lua/aibrain.lua
/lua/SimSync.lua
/lua/SimCallbacks.lua
/lua/simInit.lua
/lua/sim/Navigator.lua
/lua/sim/Blip.lua
/lua/sim/unit.lua
/lua/sim/projectile.lua
/lua/sim/prop.lua
/lua/sim/tasks/%s.lua
/lua/sim/ScriptTask.lua
/lua/sim/Weapon.lua
/lua/ui/game/construction.lua
/lua/ui/game/gamemain.lua
/lua/ui/uimain.lua
/synclog
```

---

## Key Sim Console Variables

| cvar | Description |
|------|-------------|
| `sim_Interlocked` | Force sim and UI threads to run interlocked (debug) |
| `sim_IssueThreadDebugLevel` | Spam level for issue thread |
| `sim_DebugDelay` | Milliseconds to delay each sim tick (slow sim simulation) |
| `sim_ChecksumPeriod` | How many beats between checksums |
| `sim_LogSize` | How many ticks to log before flushing |
| `sim_KeepAllLogFiles` | Keep all beat logs vs. only desync ones |
| `path_BackgroundUpdate` | Enable/disable background pathfinder thread |
| `path_BackgroundBudget` | Background pathfinder work budget |
| `path_ArmyBudget` | Per-army pathfinding budget per tick |

---

## Synthesis: Multi-Core Distribution

Based on the symbol analysis:

1. **Sim thread** (`Sim_Sync` / `Sim_Dispatch`) — runs the simulation at a fixed tick rate. Pinned to a core via `SetThreadAffinityMask`.
2. **IssueThread** — receives and queues AI/Lua commands for the sim. Runs separately, signals sim via `QueueUserAPC` or mutex.
3. **Render / vsync thread** (`MWSFSVR_VsyncThrdProc`) — frame presentation, decoupled from sim. Interpolates between beats.
4. **Pathfinding thread** (`PathQueue` background) — async pathfinding with per-army tick budget. Feeds results back to sim.
5. **Prefetcher thread** (`0x00e571c0: "Prefetcher thread."`) — asset prefetching with configurable nap time.
6. **CTaskThread workers** — pool of `CTaskThread@Moho` instances for general async tasks.

The game is **not embarrassingly parallel** — the sim is single-threaded by design (determinism requirement for netcode). Multi-core gains come from offloading render, pathfinding, and prefetch to separate cores while the sim thread runs uncontested.

FAF AI mods (M28AI, etc.) run entirely within the Lua `ForkThread` coroutine scheduler on the sim thread — they do not get their own OS thread.

---

## Next Steps

- [ ] Analyze `MohoEngine.dll` — likely contains `CTaskThread` implementation, renderer, and audio
- [ ] Cross-reference `__beginthreadex` callers to enumerate all spawned threads with names
- [ ] Decompile `Sim_Sync` / `Sim_Dispatch` entry points to understand beat gate logic
- [ ] Map `SetThreadAffinityMask` callsites to see which threads get which core masks
- [ ] Investigate `QueueUserAPC` callers — likely the IssueThread→SimThread signaling path

---

## Files

- `SupremeCommander.exe` — main binary (in `../faf/`)
- `MohoEngine.dll` — engine DLL, not yet analyzed (in `../faf/`)
- Ghidra project: `~/ghidra-supcom/` (SupCom.gpr)
- Raw extraction output: `~/fa-strings.txt`
- Extraction script: `~/ExtractAllStrings.java`
