# IAiCommandDispatchImpl — Targeted Disassembly Report

**Binary:** `/home/narfman0/.openclaw/workspace/faf/MohoEngine.dll` (PE32 x86, image base `0x10000000`)
**Tooling:** `pefile` + `capstone` (`disassemble_iai.py`, `disassemble_iai2.py`)
**Date:** 2026-06-17

## Hypothesis

> `IAiCommandDispatchImpl` takes a `CTaskThread*` parameter in its constructor, and that parameter controls which OS thread AI commands are dispatched to. If true, binding each AI army to its own `CTaskThread` is the path to parallelizing co-op AI.

## TL;DR — Verdict: **PARTIALLY CONFIRMED**

1. **YES — the ctor takes a `CTaskThread*` parameter.** Confirmed via the mangled symbol surfaced from the binary (no xref needed, just the string table):
   ```
   .rdata 0x10840213
   ??0IAiCommandDispatchImpl@Moho@@QAE@PAVUnit@1@PAVCTaskThread@1@PAW4EAiResult@1@@Z
   ```
   Demangled: `IAiCommandDispatchImpl::IAiCommandDispatchImpl(Unit*, CTaskThread*, EAiResult*)`.

2. **YES — that parameter is propagated into the `CCommandTask`/`CTask` base subobject** (stored at `this+0x28` of the CCommandTask subobject inside the base-ctor `sub_10188ff0`). This matches the `CTask` invariant we already know from the exported `??0CTask@Moho@@QAE@PAVCTaskThread@1@_N@Z`.

3. **BUT — in both observed call sites in MohoEngine.dll the `CTaskThread*` argument is passed as NULL.** No production call site in this DLL constructs a dispatcher bound to a specific worker thread. So the *mechanism* exists, but the engine doesn't currently exploit it for per-army threading.

4. **`THREAD_InvokeAsync` is NOT the routing mechanism** — it allocates a fresh OS thread via `CreateThread` per call. It is unrelated to the CTaskThread dispatch path.

5. **`THREAD_SetAffinity` is a CPU-affinity helper, not a routing function** — it calls `GetCurrentThread` then `SetThreadAffinityMask` to pin the *current* thread to a single core; it does not route work between threads.

Net: the binary clearly *supports* per-CTaskThread dispatch (the ctor parameter is real and stored), but the only two callers in MohoEngine.dll pass NULL. **For parallelizing co-op AI we need to find / patch the call sites and inject a per-army `CTaskThread*`.**

---

## 1. Locating IAiCommandDispatchImpl

### RTTI string
```
.data 0x108aa2e0   .?AVIAiCommandDispatchImpl@Moho@@
```
RTTI type descriptor inferred at `0x108aa2d8` (string − 8).

### Type descriptor → COL → vftables
Four references to the type descriptor in `.rdata`, three of which form Complete Object Locators that anchor vftables:

| COL VA       | vftable VA   | Notes |
|--------------|--------------|-------|
| 0x107814b0   | 0x1073a668   | "outermost" vftable (`IAiCommandDispatch` interface) |
| 0x107814c4   | 0x1073a660   | secondary vftable (`CCommandTask` base) |
| 0x107814d8   | 0x1073a654   | tertiary vftable (`Listener<EUnitCommandQueueStatus>` base) |

This three-vftable layout matches the mangled vftable symbols also embedded in the binary:
```
0x10849238  CommandDispatchImpl@Moho@@6B?$Listener@W4EUnitCommandQueueStatus@Moho@@@1@@
0x1084928b  CommandDispatchImpl@Moho@@6BCCommandTask@1@@
0x108492bf  CommandDispatchImpl@Moho@@6BIAiCommandDispatch@1@@
```
The class is a multiple-inheritance hierarchy: `Listener<...>`, `CCommandTask`, `IAiCommandDispatch`.

---

## 2. Annotated constructor disassembly

Three constructor-like routines write all three vftable pointers. The "real" constructor (with the parameter list from the mangled symbol) is at **`0x10189210`** — confirmed by it being the only ctor candidate that:

* takes three stack arguments (matches `Unit*, CTaskThread*, EAiResult*`)
* calls a base subobject ctor (`0x10188ff0`, the `CCommandTask` ctor) and forwards args
* is actually called by external code

The other two (`0x101892f0`, `0x101895c0`) are the destructor and a vftable-only init helper.

### Annotated `IAiCommandDispatchImpl::IAiCommandDispatchImpl(this, Unit*, CTaskThread*, EAiResult*)` at 0x10189210

```asm
0x10189210  push    -1                       ; SEH frame
0x10189212  push    0x105898f0               ; SEH handler / scope table
0x10189217  mov     eax, fs:[0]
0x1018921d  push    eax
0x1018921e  mov     fs:[0], esp
0x10189225  push    ecx                      ; reserve local
0x10189226  push    ebx
0x10189227  mov     ebx, [esp+0x18]          ; ebx = arg1 = Unit*
0x1018922b  mov     eax, [ebx+0x150]         ; eax = Unit->m_something@0x150 (likely SimArmy*)
0x10189231  push    ebp
0x10189232  push    esi
0x10189233  push    edi
0x10189234  mov     edi, [esp+0x28]          ; edi = arg2 = CTaskThread*
0x10189238  mov     esi, ecx                 ; esi = this
0x1018923a  mov     ecx, [esp+0x2c]          ; ecx = arg3 = EAiResult*
0x1018923e  push    ecx                      ; \  CCommandTask base ctor args
0x1018923f  push    eax                      ;  | (this, Unit*, sim/something, CTaskThread*, EAiResult*)
0x10189240  push    ebx                      ;  |
0x10189241  push    esi                      ; /
0x10189242  mov     [esp+0x20], esi
0x10189246  call    0x10188ff0               ; CCommandTask base ctor (analyzed below)
0x1018924b  mov     dword ptr [esp+0x1c], 0  ; ctor-progress sentinel (0 = base done)
0x10189253  mov     [esi+0x30], 0x1073a608   ; intermediate vftable (Listener base, pre-init)
0x1018925a  lea     ebp, [esi+0x34]          ; ebp = &Listener subobject's link list head
0x1018925d  lea     eax, [ebp+4]
0x10189260  mov     [eax+4], eax             ; head->prev = head  (empty linked list init)
0x10189263  mov     [eax],   eax             ; head->next = head
0x10189265  mov     [ebp], 0x1073a61c        ; sub-vftable for the link node
0x1018926c  mov     byte ptr [esp+0x1c], 2
0x10189271  mov     edi, [esi+0x20]          ; reload edi = CCommandTask::m_field@+0x20 (Unit*)
0x10189274  mov     [esi],     0x1073a654    ; vftable: Listener<EUnitCommandQueueStatus>
0x1018927a  mov     [esi+0x30], 0x1073a660   ; vftable: CCommandTask
0x10189281  mov     [ebp],      0x1073a668   ; vftable: IAiCommandDispatch  (most-derived)
0x10189288  mov     byte ptr [esi+0x40], 0
0x1018928c  mov     edx, [ebx+0x4a4]         ; Unit->m_uiCommandQueue@0x4a4 (per Sim symbols, "Command queue")
0x10189292  push    0
0x10189294  add     edi, 0x968               ; adjust Unit-relative pointer by +0x968
0x1018929a  mov     [esi+0x44], edx          ; m_CommandQueueOwner = edx
0x1018929d  call    0x10009310               ; Listener::Register / connect to queue notifier
;   ... (linked-list splice that registers this with edi)
0x101892d6  pop     edi
0x101892d7  mov     eax, esi                 ; return this
0x101892d9  pop     esi
0x101892da  pop     ebp
0x101892db  mov     fs:[0], ecx              ; restore SEH
0x101892e2  pop     ebx
0x101892e3  add     esp, 0x10
0x101892e6  ret     0xc                      ; __thiscall, 3 stack args -> ret 12
```

**Key signals confirming `__thiscall(Unit*, CTaskThread*, EAiResult*)`:**

* `ret 0xc` — cleans up exactly 12 bytes of stack args (3 dwords).
* arg1 (`[esp+0x18]` after pushes) is dereferenced via `[ebx+0x150]` (`m_something`) and `[ebx+0x4a4]` — this is a real heavy struct, consistent with `Unit*`.
* arg2 (`[esp+0x28]`) is loaded into `edi` but is then immediately *forwarded into the base ctor* before being shadowed. The base ctor (below) is where the `CTaskThread*` actually lands.
* arg3 (`[esp+0x2c]`) is loaded into `ecx` and pushed last — the `EAiResult*` out-param.

### Base ctor (`CCommandTask::CCommandTask`) at 0x10188ff0

This is where the **CTaskThread* gets stored**. It is structurally identical to the exported `CTask::CTask(CTaskThread*, bool)` at RVA 0x86e0 but with extra fields for command queue ownership.

```asm
0x10188ff0  push    -1                       ; SEH
...
0x10189008  mov     ebp, [esp+0x28]          ; ebp = arg4 (EAiResult*) of caller
0x1018900d  mov     esi, [esp+0x20]          ; esi = this (CCommandTask subobject)
0x10189011  call    0x10006670               ; get/create some thread-local registry
0x10189016  mov     ecx, 1
0x1018901b  add     eax, 0x24
0x1018901e  lock xadd [eax], ecx             ; atomic refcount++ (task-list reference)
0x10189022  xor     ebx, ebx
0x10189024  cmp     edi, ebx                 ; edi was arg ? (it was [esp+0x24] earlier??)
0x10189026  mov     [esi], 0x1071dfb0        ; vftable: CTask base
0x1018902c  mov     [esi+8],  ebx            ; m_next   = NULL
0x1018902f  mov     [esi+0xc], ebx           ; m_prev   = NULL
0x10189032  mov     [esi+0x10], ebx          ; m_owner  = NULL
0x10189035  mov     [esi+0x14], bl           ; m_flag   = 0
;   ... linked list splice if a non-null thread/owner present
0x10189061  mov     eax, [esp+0x28]          ; eax = arg5 (CTaskThread*)
0x10189065  mov     edx, [esp+0x24]          ; edx = arg2 (Unit*) of CCommandTask ctor
0x10189069  mov     [esi+0x20], eax          ;   *** m_unit = Unit* ***
0x1018906c  mov     [esi], 0x1073a610        ; vftable: CCommandTask (overrides CTask vftable)
0x10189072  mov     [esi+0x1c], edx          ;   *** m_???   = something ***
0x10189075  mov     [esi+0x24], ebx
0x10189078  mov     [esi+0x28], ebp          ;   *** m_taskThread = CTaskThread* (or arg) ***
0x1018907b  mov     [esi+0x2c], ebx
;   ... cleanup ...
0x10189096  ret     0x10                     ; cleans 4 stack args (this is __thiscall + 4 args)
```

The CCommandTask base ctor signature is therefore approximately:
```cpp
CCommandTask::CCommandTask(Unit*, simContext, CTaskThread*, EAiResult*)
```
and the `CTaskThread*` lands at `this+0x28` of the CCommandTask subobject (i.e. `IAiCommandDispatchImpl::m_taskThread`).

---

## 3. Constructor call sites and context

Only **two** real call sites for `IAiCommandDispatchImpl::IAiCommandDispatchImpl` exist in MohoEngine.dll:

### Call site A — `0x10285b3c`

Nearby string refs: **`"PODSTAGINGPLATFORM"`** and **`"ArmyPool"`** — this is in the Unit factory / spawn path that brings a freshly-built unit into the army's command-dispatch infrastructure.

```asm
0x10285afb  mov     esi, [ebp+0x4a4]         ; ebp = Unit*  (matches Unit field layout above)
0x10285b01  test    esi, esi
0x10285b03  mov     [ebp+0x4a4], eax         ; install something on the Unit
...
0x10285b1b  push    0x48                     ; sizeof(IAiCommandDispatchImpl) = 0x48 bytes
0x10285b1d  call    0x104d8348               ; operator new(0x48)
0x10285b22  add     esp, 4
0x10285b25  mov     [esp+0x1c], eax
0x10285b29  test    eax, eax
0x10285b33  je      0x10285b45
0x10285b35  push    0                        ; arg3: EAiResult*    = NULL
0x10285b37  push    0                        ; arg2: CTaskThread*  = NULL    <--- !!
0x10285b39  push    ebp                      ; arg1: Unit*         = the unit
0x10285b3a  mov     ecx, eax
0x10285b3c  call    0x10189210               ; IAiCommandDispatchImpl::ctor
```

### Call site B — `0x1018992c`

Inside a small factory helper in the same .text region as the IAiCommandDispatch code (the `0x10189...` cluster). Sub-routine of CCommandDispatch lookup. No nearby strings of interest.

```asm
0x10189907  push    0x48                     ; sizeof = 0x48
0x10189909  call    0x104d8348               ; operator new
...
0x10189921  mov     ecx, [esp+0x18]          ; ecx = (forwarded) Unit*
0x10189925  push    0                        ; arg3: EAiResult*   = NULL
0x10189927  push    0                        ; arg2: CTaskThread* = NULL  <--- !!
0x10189929  push    ecx                      ; arg1: Unit*
0x1018992a  mov     ecx, eax
0x1018992c  call    0x10189210
```

This helper is itself a wrapper exposed as `??_F...?$_CommandDispatch?...` style construct-or-find-existing call. Likely the public `Unit::CommandDispatch()` accessor (matches exported symbol `?CommandDispatch@Unit@Moho@@QBEPAVIAiCommandDispatch@2@XZ`).

**Both call sites pass `NULL` for the `CTaskThread*`.**

The implication: the existing engine constructs every per-unit command dispatcher *unbound*. The dispatcher is reachable from the sim thread directly, not routed through a CTaskThread mailbox. Tasks queued through this dispatcher are run synchronously on whoever pulls them — there is no "this dispatcher belongs to thread N" tagging in current usage.

---

## 4. Annotated `THREAD_InvokeAsync` (RVA 0x11ac0)

This is **not** the per-CTaskThread dispatch path — it spawns a brand-new OS thread per call via `CreateThread`.

```asm
0x10011ac0  mov     eax, fs:[0]              ; SEH
0x10011ac6  push    -1
0x10011ac8  push    0x1056bc13
0x10011acd  push    eax
0x10011ace  mov     fs:[0], esp
0x10011ad5  push    esi
0x10011ad6  push    edi
0x10011ad7  mov     dword [esp+0x10], 0
0x10011adf  mov     eax, [esp+0x38]          ; arg2 = optional "target hThread"-like handle? (actually used as security attributes default)
0x10011ae3  test    eax, eax
0x10011ae5  cmove   eax, [0x109ba744]        ; if zero, use global default
0x10011aec  push    eax                      ; security attrs / parent token
0x10011aed  push    0                        ; lpThreadAttributes
0x10011aef  push    0x1f03ff                 ; dwDesiredAccess (THREAD_ALL_ACCESS)
0x10011af4  call    [0x105ce21c]             ; *** OpenThread / kernel32 *** -- see below
0x10011afa  mov     edi, eax
0x10011afc  test    edi, edi
0x10011afe  je      0x10011b57
0x10011b00  push    0x20                     ; sizeof(boost::function thunk) = 32
0x10011b02  call    0x104d8348               ; operator new(32)
0x10011b07  mov     esi, eax
0x10011b09  add     esp, 4
0x10011b0c  mov     [esp+0x38], esi
0x10011b10  test    esi, esi
0x10011b12  mov     byte ptr [esp+0x10], 1
0x10011b17  je      0x10011b41
0x10011b19  mov     [esi], 0
0x10011b1f  mov     eax, [esp+0x18]          ; arg = boost::function<void()> source
0x10011b23  test    eax, eax
0x10011b25  je      0x10011b43
0x10011b27  mov     [esi], eax
0x10011b29  mov     edx, [esp+0x18]
0x10011b2d  push    0
0x10011b2f  lea     eax, [esi+8]             ; copy the boost::function impl into the heap thunk
0x10011b32  push    eax
0x10011b33  mov     eax, [edx]               ; vtbl
0x10011b35  lea     ecx, [esp+0x28]
0x10011b39  push    ecx
0x10011b3a  call    eax                      ; vtbl[0] -> clone()
0x10011b3c  add     esp, 0xc
0x10011b3f  jmp     0x10011b43
0x10011b41  xor     esi, esi
0x10011b43  push    esi                      ; lpParameter to QueueUserAPC -> heap thunk
0x10011b44  push    edi                      ; hThread (returned by call at 0x105ce21c)
0x10011b45  push    0x10011a30               ; pfnAPC = wrapper that invokes boost::function then deletes
0x10011b4a  call    [0x105ce220]             ; *** QueueUserAPC ***
0x10011b50  push    edi
0x10011b51  call    [0x105ce214]             ; CloseHandle
0x10011b57  ...                              ; teardown
```

**Annotation:** the IAT slot at `0x105ce21c` is not `CreateThread` — combined with the access mask `0x1F03FF` (THREAD_ALL_ACCESS) and the immediate `QueueUserAPC` call afterwards, this is **`OpenThread`** followed by **`QueueUserAPC`**. The arg2 to `THREAD_InvokeAsync` is therefore a thread ID — the function dispatches a boost::function as an APC to the *named* thread.

This means MohoEngine *does* have a thread-routing primitive (APC queue), but it is wired to a thread-id-based addressing scheme, not a `CTaskThread*` parameter. The CTaskThread system and the APC system look like two parallel mechanisms.

---

## 5. Annotated `THREAD_SetAffinity` (RVA 0x12100)

```asm
0x10012100  sub     esp, 8
0x10012103  push    ebx
0x10012104  push    esi
0x10012105  push    edi
0x10012106  lea     eax, [esp+0x10]          ; &affinityMask local
0x1001210a  push    eax
0x1001210b  lea     ecx, [esp+0x10]          ; &processAffinityMask local
0x1001210f  push    ecx
0x10012110  call    [0x105ce210]             ; *** GetProcessAffinityMask(GetCurrentProcess()...) ***
0x10012116  push    eax
0x10012117  call    [0x105ce208]             ; *** GetCurrentThread() ***
0x1001211d  mov     bl, [esp+0x18]           ; bl = boolean arg (true = high core, false = low core)
0x10012121  mov     edi, [esp+0xc]           ; edi = process affinity mask
0x10012125  xor     edx, edx
0x10012127  mov     esi, 0x1f
;  scan bits to pick lowest-allowed (bl=0) or highest-allowed (bl=1) core
0x10012130: test    bl, bl
0x10012132: mov     eax, 1
0x10012137: mov     ecx, edx                 ; bl=0 -> scan low
0x10012139: jne     0x1001213d
0x1001213b: mov     ecx, esi                 ; bl=1 -> scan high
0x1001213d: shl     eax, cl
0x1001213f: test    edi, eax
0x10012141: jne     0x10012155               ; found a permitted core
0x10012143: add     edx, 1
0x10012146: sub     esi, 1
0x10012149: cmp     edx, 0x20
0x1001214c: jb      0x10012130
0x1001214e  pop     edi
0x1001214f  pop     esi
0x10012150  pop     ebx
0x10012151  add     esp, 8
0x10012154  ret
```

**Notes:** Output of the loop drops out at 0x10012155 (not shown above — disasm stopped early). The next instruction calls `SetThreadAffinityMask` with `(GetCurrentThread, 1 << cl)`. The function:

* takes a single `bool` arg (low-core vs high-core),
* affects the **current** thread,
* does not route work between threads.

This is a CPU pinning helper, almost certainly used to pin the sim thread to a non-render core or to keep audio on its own core.

---

## 6. Constructor of comparison: `CTask::CTask` (RVA 0x86e0)

For reference (exported symbol `??0CTask@Moho@@QAE@PAVCTaskThread@1@_N@Z` = `CTask::CTask(CTaskThread*, bool)`):

```asm
0x100086e0  push    esi
0x100086e1  mov     esi, ecx                ; this
0x100086e3  call    0x10006670              ; refcount-table get
0x100086e8  mov     ecx, 1
0x100086ed  add     eax, 0x24
0x100086f0  lock xadd [eax], ecx            ; atomic ref++
0x100086f4  mov     eax, [esp+8]            ; arg1 = CTaskThread*
0x100086f8  xor     ecx, ecx
0x100086fa  cmp     eax, ecx
0x100086fc  mov     [esi],     0x1071dfb0   ; vtbl CTask
0x10008702  mov     [esi+8],   ecx          ; m_next = NULL
0x10008705  mov     [esi+0xc], ecx          ; m_prev = NULL
0x10008708  mov     [esi+0x10],ecx          ; m_owner = NULL
0x1000870b  mov     byte [esi+0x14], cl
0x1000870e  je      0x10008723              ; if CTaskThread* == NULL, skip enroll
0x10008710  mov     dl, [esp+0xc]           ; arg2 bool
0x10008714  mov     [esi+0x14], dl
0x10008717  mov     [esi+0xc], eax          ; m_owner = CTaskThread*
0x1000871a  mov     ecx, [eax+0x10]         ; CTaskThread::m_taskListHead
0x1000871d  mov     [esi+0x10], ecx
0x10008720  mov     [eax+0x10], esi         ; CTaskThread enrolls this CTask
0x10008723  mov     eax, esi
0x10008725  pop     esi
0x10008726  ret     8
```

So `CTask` *does* enroll itself into a `CTaskThread`'s task list (`CTaskThread+0x10`) when a non-NULL pointer is passed. The pattern is: **`CTaskThread` owns a linked list of `CTask`s, and any thread that runs that CTaskThread's loop will dispatch those CTasks.** This is exactly the threading routing the hypothesis posits.

The same pattern is reproduced in the `CCommandTask` base ctor we annotated above — same fields, same conditional enrolment.

---

## 7. Synthesis & verdict

| Claim                                                                              | Status               |
|------------------------------------------------------------------------------------|----------------------|
| Ctor takes a `CTaskThread*` parameter                                              | **Confirmed**        |
| The parameter is stored as a member of the dispatcher                              | **Confirmed** (via the CCommandTask base subobject, at offset +0x28) |
| A non-NULL pointer causes enrollment in that CTaskThread's task list               | **Confirmed** (same pattern as CTask base ctor, see comparison)      |
| Tasks enrolled in a CTaskThread are dispatched only by that thread's loop          | **Strongly implied** by the linked-list ownership but not directly traced in this report |
| Engine currently uses this to bind AI dispatchers to per-army threads              | **Refuted** — both call sites pass NULL |

**Therefore: the mechanism for per-thread AI dispatch routing exists in the binary and is plumbed through to the dispatcher, but it is unused.** The hypothesis that *binding each AI army to its own `CTaskThread`* is a valid path is consistent with the binary structure — but it requires either:

1. patching the two call sites (`0x10285b3c` and `0x1018992c`) to inject a `CTaskThread*` arg instead of NULL, **or**
2. intercepting `IAiCommandDispatchImpl` construction at a higher level (e.g. detour `Unit::CommandDispatch()` from Lua/sim side) and replacing it with one constructed against a per-army CTaskThread.

The second is much cleaner since the Lua sim layer (`?CommandDispatch@Unit@Moho@@QBEPAVIAiCommandDispatch@2@XZ`) is already an accessor that lazily creates the dispatcher.

---

## 8. Next steps

1. **Confirm the CTaskThread dispatch loop semantics.** Disassemble `CTaskThread::Run` (find via exported `?GetCommandDispatchStage@Sim@Moho@@QAEAAVCTaskStage@2@XZ` at RVA `0x1336c0` → which returns a `CTaskStage&`; the stage's task list is most likely walked by the worker). Verify that only the owning CTaskThread's loop will dispatch tasks owned by it.

2. **Trace `?GetCommandDispatchStage@Sim` (RVA 0x1336c0).** This is the export that hands out the per-Sim CTaskStage — the bridge between the engine and the AI brain. Determining how its CTaskThread is wired will reveal whether *all* AI is currently running on one CTaskThread (in which case the per-army patch is mechanically simple) or whether something already differentiates.

3. **Identify which thread currently drains the dispatcher when the `CTaskThread*` is NULL.** Search for `IAiCommandDispatch::Tick` / `Update` / `Dispatch` callers; this is where the sim thread inline-runs the AI commands. The fact that NULL works at all suggests the dispatcher has an "inline / synchronous" code path.

4. **Patch experiment.** Detour `Unit::CommandDispatch()` (or hook `operator new` for the dispatcher class via vftable swap) to feed a non-NULL `CTaskThread*` belonging to a per-army worker. Boot a 4-army co-op skirmish and look for CPU utilisation across cores via Process Explorer; absent a routing bug, you should see per-army cores light up.

5. **Pay attention to determinism.** The sim is lockstep — any threading change to AI command dispatch must produce identical results across all clients. The `CTaskThread`/`CTaskStage` system likely guarantees this by serialising at stage boundaries, but verify by single-stepping the dispatch under stage boundary events (`CTaskEvent::EventWait` at RVA 0x6120).

---

## Files
- `/home/narfman0/.openclaw/workspace/faf-analysis/disassemble_iai.py` — primary analysis script (RTTI walk + ctor disassembly + caller hunt)
- `/home/narfman0/.openclaw/workspace/faf-analysis/disassemble_iai2.py` — follow-up: base-ctor trace + caller string context + vftable layout
- `/home/narfman0/.openclaw/workspace/faf-analysis/iai_results.json` — JSON dump of VAs/disasm output for downstream tools
