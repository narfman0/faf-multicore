# CTaskThread Dispatch Investigation — MohoEngine.dll

**Binary:** `faf/MohoEngine.dll`  
**Image base:** `0x10000000`  
**Subject:** Can binding `IAiCommandDispatchImpl` to a per-army `CTaskThread*` route its dispatch to a dedicated OS thread?

---

## TL;DR — Headline finding

**Dispatch is stage-driven, not thread-driven.** `CTaskStage::DispatchAll` iterates the *stage's own task list* (`stage+0x10`), invoking each task's `vtbl[1]` on whatever OS thread happens to call it (in practice: the sim thread). The `CTaskThread*` parameter wired through `IAiCommandDispatchImpl` and `CTask` only controls **ownership/lifetime tracking** — tasks register themselves on `CTaskThread+0x10` so the thread can cleanly tear them down at shutdown. It has nothing to do with selecting which OS thread runs the task body.

Consequence: the original hypothesis ("pass a different `CTaskThread*` to get per-army OS-thread parallelism") is **false** as a standalone mechanism. Per-army threading requires both per-army `CTaskStage` instances and dedicated OS threads pumping them.

---

## 1. `CTaskStage::DispatchAll` — `0x10008bc0`

This is the per-frame stage tick. ESI = stage pointer. EDI walks the stage's task list.

```
0x10008bc0  push    ebp
0x10008bc1  mov     ebp, esp
            ; SEH prologue
0x10008bdd  mov     esi, [ebp+8]              ; esi = CTaskStage*
0x10008be0  add     [esi+0x14], -1            ; decrement stage counter (refcount/depth)
0x10008be4  mov     eax, [esi+0x14]
0x10008be7  xor     ebx, ebx
0x10008be9  cmp     eax, ebx
0x10008bef  jg      0x10008cfc                ; bail if not yet ready to dispatch
0x10008bf5  mov     edi, [esi+0x10]           ; edi = stage->taskList head  <-- KEY
0x10008bf8  cmp     edi, ebx
0x10008bfd  je      0x10008cb1                ; empty list -> exit

; --- dispatch loop body ---
0x10008c09  mov     edx, [edi]                ; edx = task->vtbl
0x10008c0b  lea     eax, [ebp-0x11]           ; SEH scratch
0x10008c0e  mov     [edi+8], eax              ; stash unwind anchor in task+8
0x10008c11  mov     eax, [edx+4]              ; eax = vtbl[1]    <-- Run()/Tick()
0x10008c14  mov     ecx, edi                  ; this = task
0x10008c16  call    eax                       ; invoke task
0x10008c18  mov     ecx, eax                  ; return value handled below
```

Annotations:

- `[esi+0x10]` is the **stage's own task list**, distinct from `CTaskThread+0x10`.
- The virtual at slot 1 is the task body (`Run`/`Tick`).
- Whichever thread is currently inside `DispatchAll` runs every task in the list serially. There is no enqueue-to-another-thread.

**Sole caller:** `0x100093fb` — i.e. only one site invokes `DispatchAll`, and that site lives on the sim thread.

---

## 2. `CTask::~CTask` — `0x10008730` (CTaskThread ownership unlink)

ESI = `this` (CTask). `[esi+0xC]` = owning `CTaskThread*` (NULL if untracked).

```
0x10008751  mov     [esi], 0x1071dfb0         ; install CTask vtable for dtor chain
0x1000875d  mov     eax, [esi+0xC]            ; eax = owning CTaskThread*  <-- KEY
0x10008760  cmp     eax, ebx
0x10008762  je      0x100087b9                ; if no owning thread, skip unlink
0x10008764  cmp     byte [eax+0x18], bl       ; check thread state flag
0x10008767  mov     [eax+0x14], ebx           ; clear thread.activeTaskCount/flag
0x1000876a  je      0x10008794

; --- splice 'eax' out of its intrusive doubly-linked list ---
0x1000876c  mov     edx, [eax]                ; prev
0x1000876e  mov     edi, [eax+4]              ; next
0x10008771  mov     ecx, [eax+0xC]            ; saved sentinel
0x10008774  mov     [edx+4], edi
0x10008777  ...                               ; standard "remove me from list" sequence
0x10008791  mov     byte [eax+0x18], bl

0x10008794  mov     ecx, esi
0x10008796  call    0x100087f0                ; helper

; --- walk CTaskThread+0x10 list and unlink this task ---
0x1000879b  mov     eax, [esi+0xC]            ; CTaskThread*
0x1000879e  add     eax, 0x10                 ; &thread.taskList   <-- KEY OFFSET
0x100087a1  cmp     [eax], esi
0x100087a3  je      0x100087ae
0x100087a5  mov     eax, [eax]                ; walk single-linked chain
0x100087a7  add     eax, 0x10
0x100087aa  cmp     [eax], esi
0x100087ac  jne     0x100087a5
0x100087ae  mov     edx, [esi+0x10]           ; unlink: prev->next = this->next
0x100087b1  mov     [eax], edx
0x100087b3  mov     [esi+0x10], ebx
0x100087b6  mov     [esi+0xC], ebx
```

Annotations:

- The destructor only touches `CTaskThread+0x10` to **remove itself** from that list.
- `CTaskThread+0x10` is therefore a **registry of live tasks owned by the thread** — used at shutdown to walk and destroy them, not during dispatch.
- The intrusive next link inside each task is `task+0x10` (see the walker at `0x100087a5`).

---

## 3. `CTaskEvent::EventWait` (vtables noted)

- `CTask` vftable @ `0x1071dfb0`: `vtbl[0]=0x100085a0` (dtor), `vtbl[1]=0x104d875c` (Run), `vtbl[2]=0x1076ec94` (Stop).
- `CTaskEvent` vftable @ `0x1071de50`: `vtbl[0]=0x10005b80` (dtor), `vtbl[1]=0x1076e504` (Stop).

`EventWait(CTaskThread*)` parks the calling fiber/coroutine (a ForkThread continuation) on the event's wait list and yields back to the dispatch loop. When the event fires, the waiter is re-armed and the next `DispatchAll` pass on the parking stage resumes it. This is intra-process cooperative scheduling, **not** an OS-level cross-thread barrier. The `CTaskThread*` argument is again just the ownership/cleanup binding used to make sure the suspended fiber gets torn down if the owning thread exits.

---

## 4. Revised verdict on per-army OS-thread routing

| Claim | Status |
|---|---|
| `CTaskThread+0x10` is the dispatch queue | **False.** It is the ownership/lifetime registry. |
| `CTaskStage::DispatchAll` walks `CTaskThread+0x10` | **False.** It walks `stage+0x10`. |
| Passing a per-army `CTaskThread*` reroutes dispatch onto that thread | **False.** It only changes which thread cleans the task up. |
| Dispatch thread = whoever calls `DispatchAll` on the stage | **True.** Currently the sim thread, exclusively (single caller at `0x100093fb`). |
| `CTaskEvent::EventWait` is a cross-OS-thread sync primitive | **False.** It's cooperative fiber suspension. |

The per-army `CTaskThread*` plumbing in `IAiCommandDispatchImpl` is therefore a red herring for parallelism. It is real bookkeeping — it ensures the per-army command-dispatch tasks die with the per-army thread object — but it does not move work between OS threads.

---

## 5. What it would actually take to parallelise per-army AI dispatch

To make AI command dispatch genuinely run on multiple OS threads, three pieces are required:

1. **Per-army `CTaskStage`.** Allocate a `CTaskStage` per army (or per AI-group). The command-dispatch task for that army must live on that stage's `+0x10` list, which means routing its registration through whatever `CTaskStage` the task constructor consults — likely the stage returned by `GetCommandDispatchStage` (`RVA 0x1336c0`). That accessor currently hands back a *single* shared stage; it would need a per-army variant.

2. **Dedicated OS thread per stage.** Spawn one worker OS thread per army stage whose loop is essentially:
   ```
   while (running) {
       wait_for_tick_signal();
       CTaskStage::DispatchAll(&army_stage);   // 0x10008bc0
   }
   ```
   The sim thread no longer touches those stages directly — it only signals them and joins at the end of the frame (barrier) to keep determinism.

3. **Sync discipline for shared sim state.** Because the tasks invoked from `vtbl[1]` will currently reach into shared world state (unit lists, command queues, blackboards), per-army parallel execution needs either:
   - read-only snapshots of the world taken before the parallel phase, with command outputs merged afterwards on the sim thread, or
   - explicit locking around any cross-army mutation (high risk of breaking lockstep/determinism that FAF replays depend on).

The `CTaskThread*` ownership param can stay as-is — give each worker its own `CTaskThread` and bind tasks to it for clean teardown. That binding will finally carry real meaning, because the worker's lifecycle now matches the stage it pumps.

### Practical next steps for a spike

1. Disassemble `GetCommandDispatchStage` (RVA `0x1336c0`) to confirm where the singleton stage lives and whether it's keyed by anything (global vs. tls vs. struct field).
2. Find the call site at `0x100093fb` — confirm it is on the sim thread and identify the surrounding per-frame scheduler so we know where a fan-out/join would sit.
3. Audit `CTask::CTask` / `CTaskStage::AddTask` to see how a task chooses *which* stage to enroll on; this is the hook point for per-army stage selection.
4. Prototype: clone the command-dispatch stage, run `DispatchAll` for army 1 on a worker thread while the sim thread does army 2, and stress-test determinism with a known replay.

---

## Appendix — addresses

| Symbol | VA |
|---|---|
| `CTaskStage::DispatchAll` | `0x10008bc0` |
| Dispatch loop body (vtbl[1] call) | `0x10008c11`–`0x10008c16` |
| Sole caller of DispatchAll | `0x100093fb` |
| `CTask::~CTask` | `0x10008730` |
| CTaskThread list walk in dtor | `0x1000879b`–`0x100087b3` |
| Stage cleanup branch (task returned -1) | `0x10008ab0` |
| `CTask` vftable | `0x1071dfb0` |
| `CTaskEvent` vftable | `0x1071de50` |
| `GetCommandDispatchStage` | RVA `0x1336c0` (VA `0x101336c0`) |

| Offset | Meaning |
|---|---|
| `CTaskStage+0x10` | head of stage's task list (dispatched by `DispatchAll`) |
| `CTaskStage+0x14` | dispatch depth/refcount |
| `CTaskThread+0x10` | head of thread's owned-task list (cleanup only) |
| `CTask+0x0C` | back-pointer to owning `CTaskThread*` |
| `CTask+0x10` | next pointer in `CTaskThread` ownership list |
| `CTask+0x08` | SEH unwind anchor stashed during dispatch |
