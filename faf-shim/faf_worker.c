/*
 * faf_worker.dll — Option A multi-core AI offload shim
 *
 * Injected into ForgedAlliance.exe via PE import patching (inject_import.py).
 * ASLR disabled; EXE always loads at 0x00400000.
 *
 * Full VA reference: faf-analysis/lua-va-table.md
 *
 * ── Design ──────────────────────────────────────────────────────────────────
 * Spawns N_WORKERS OS threads outside the engine's 8 CTaskThread pool.
 * Exposes two Lua globals to M28AI:
 *
 *   handle = FAF_OffloadThreatMap(army_index, x1, y1, z1 [, x2, y2, z2, ...])
 *     Copies position args out of Lua, enqueues a batch threat query,
 *     returns an integer slot handle (future id).
 *
 *   result = FAF_PollResult(handle)
 *     Returns nil if the worker hasn't finished yet.
 *     Returns a flat array of threat floats (one per input position) when done.
 *     Frees the slot on first successful poll — do NOT call again with same handle.
 *
 * ── Safety model ────────────────────────────────────────────────────────────
 * Workers call 0x715ff0 (inner threat accumulation loop) — a read-only operation
 * against the threat map grid. The threat map is written by the sim thread between
 * beats; reads during a beat are safe. Workers never touch lua_State*.
 *
 * ── AIBrain / threat map pointer extraction ──────────────────────────────────
 * Confirmed chain (from objdump analysis — see lua-va-table.md):
 *
 *   binding_wrapper = *(void**)(L + 0x44)          // getter at 0x9240a0
 *   type_tag        = *(int*)(binding_wrapper + 0xc) // should be 8 for full C++ obj
 *   gcobj           = *(void**)(binding_wrapper + 0x10)
 *   aibrain         = (char*)gcobj + 0x10           // C++ object, vtable at [0]
 *
 *   sub_obj = *(void**)(aibrain + 0x34)             // sub-object with its own vtable
 *   vtable  = *(void**)sub_obj
 *   fn      = *(void**)((char*)vtable + 0x18)       // vtable[6] = get_threat_map
 *   tmap    = fn(sub_obj)                           // thiscall: ecx = sub_obj
 *
 * ── 0x715c60 / 0x715ff0 calling conventions ──────────────────────────────────
 *   0x715c60(pos_ptr):  stdcall (ret 0x4), edi = tmap (implicit register arg)
 *                       returns cell_index in eax
 *   0x715ff0(tmap, x_cell, arg3, is_naval, ring, army_0based):
 *                       cdecl (6 explicit args), eax = y_cell (implicit register arg)
 *                       returns float via xmm0
 *
 * Implicit register args require inline asm helpers (see call_715c60, call_715ff0).
 *
 * ── Lua state capture ────────────────────────────────────────────────────────
 * We hook GetThreatAtPosition (VA 0x590260) with a PUSH/RET trampoline (identical
 * to faf_profiler). The hook fires on the sim thread's first GTA call and captures
 * lua_State*, then registers the two Lua globals and caches g_tmap before falling
 * through to the original function.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/* ── Engine VA constants ─────────────────────────────────────────────────── */
#define GTA_VA  0x00590260u   /* Lua C binding: GetThreatAtPosition */

/* ── LuaPlus ABI (confirmed VAs — see lua-va-table.md) ───────────────────── */
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);

#define LUA_GLOBALSINDEX  ((int)0xffffd8ef)  /* -10001 */

/* Confirmed function VAs */
#define VA_lua_gettop         0x90c590u
#define VA_luaL_error         0x90c1d0u
#define VA_lua_type           0x90c740u
#define VA_lua_tonumber       0x90c9f0u  /* returns float via FPU st(0) */
#define VA_lua_pushnil        0x90cd00u
#define VA_lua_pushnumber     0x90cd40u
#define VA_lua_pushstring     0x90cdf0u
#define VA_lua_pushcclosure   0x90ced0u
#define VA_lua_newtable       0x90d110u
#define VA_lua_rawseti        0x90d2f0u
#define VA_lua_rawset         0x90d260u

typedef int   (__cdecl *fn_lua_gettop_t)      (lua_State*);
typedef void  (__cdecl *fn_luaL_error_t)      (lua_State*, const char*, ...);
typedef int   (__cdecl *fn_lua_type_t)        (lua_State*, int);
typedef float (__cdecl *fn_lua_tonumber_t)    (lua_State*, int);
typedef void  (__cdecl *fn_lua_pushnil_t)     (lua_State*);
typedef void  (__cdecl *fn_lua_pushnumber_t)  (lua_State*, float);
typedef void  (__cdecl *fn_lua_pushstring_t)  (lua_State*, const char*);
typedef void  (__cdecl *fn_lua_pushcclosure_t)(lua_State*, lua_CFunction, int);
typedef void  (__cdecl *fn_lua_newtable_t)    (lua_State*);
typedef void  (__cdecl *fn_lua_rawseti_t)     (lua_State*, int, int);
typedef void  (__cdecl *fn_lua_rawset_t)      (lua_State*, int);

#define LUA(fn, ...) ((fn_##fn##_t)VA_##fn)(__VA_ARGS__)

/* ── Worker thread config ────────────────────────────────────────────────── */
#define N_WORKERS     2
#define MAX_SLOTS     64    /* power of 2; must be >= concurrent offload count */
#define MAX_POSITIONS 256   /* max position triples per offload call */

/* ── Per-job result slot ─────────────────────────────────────────────────── */
typedef struct {
    volatile LONG done;        /* -1=free, 0=pending, 1=complete */
    int           army_index;
    int           n_positions;
    float         px[MAX_POSITIONS];  /* flat: x,y,z per position */
    float         py[MAX_POSITIONS];
    float         pz[MAX_POSITIONS];
    float         results[MAX_POSITIONS];
} ResultSlot;

/* ── Job queue (simple MPSC via interlocked increment on tail) ───────────── */
typedef struct { int slot_index; } Job;

static ResultSlot g_slots[MAX_SLOTS];
static Job        g_queue[MAX_SLOTS];
static volatile LONG g_queue_head = 0;
static volatile LONG g_queue_tail = 0;

static HANDLE        g_work_event;
static HANDLE        g_workers[N_WORKERS];
static volatile LONG g_shutdown = 0;

/* ── GTA hook state ──────────────────────────────────────────────────────── */
typedef int (__cdecl *fn_gta_t)(lua_State *L);
static BYTE*         g_gta_trampoline = NULL;
static volatile LONG g_lua_registered = 0;

/* Cached threat map object — set once from hook_gta on the sim thread.
 * Workers read it after it is non-NULL; the store happens before the first
 * SetEvent(g_work_event), so no explicit fence is needed beyond the event. */
static void * volatile g_tmap = NULL;

/* ── 0x5930d0 "get AIBrain from arg1" hook state ─────────────────────────────
 * The AIBrain self is unwrapped by 0x5930d0 (RTTI downcast) inside the real GTA.
 * Rather than re-derive the object layout (which failed), we hook 0x5930d0 and,
 * while ARMED (set only during the GTA trampoline call), capture its return
 * value — the genuine AIBrain C++ pointer the engine itself produced.
 * These are non-static so the naked asm stub can reference them by symbol. */
void *        g_x5930d0_tramp     = NULL;
volatile LONG g_arm_x5930d0       = 0;
void *        g_captured_aibrain  = NULL;

typedef void *(__attribute__((thiscall)) *fn_get_tmap_t)(void *);

static FILE* g_log = NULL;

/* ── Engine call helpers (inline asm) ───────────────────────────────────── */

/*
 * Call 0x715c60(pos_ptr) with edi = tmap (implicit register arg).
 * 0x715c60 is stdcall (ret 0x4): it pops its one stack arg.
 * Returns cell_index in eax.
 *
 * pos is a float[3] (or float[4] padded): {x, y_ignored, z}.
 */
static int __attribute__((noinline))
call_715c60(void *tmap, const float *pos)
{
    int cell;
    __asm__ volatile (
        "movl  %[tm], %%edi  \n\t"   /* edi = tmap */
        "pushl %[pos]        \n\t"   /* push pos_ptr (cleaned by callee) */
        "movl  $0x715c60, %%eax \n\t"
        "call  *%%eax        \n\t"
        /* callee does ret 0x4 — stack is already clean */
        "movl  %%eax, %[out] \n\t"
        : [out] "=&a"(cell)
        : [tm]  "g" (tmap),
          [pos] "g" (pos)
        : "ebx", "ecx", "edx", "edi", "esi",
          "cc", "memory"
    );
    return cell;
}

/*
 * Call the threat-accumulation function at 0x715ff0. Confirmed from the engine
 * call site (0x59054a–0x590562) and 0x715ff0's body/epilogue:
 *
 *   float __stdcall f715ff0(void *tmap, int x_cell, int ring_radius,
 *                           int restrict_flag, int threat_type, int army0);
 *   // implicit: eax = y_cell ; returns float in xmm0
 *
 * CRITICAL: 0x715ff0 ends with `ret 0x18` — it is STDCALL and pops its own 6
 * args. The previous wrapper added `addl $24` (cdecl cleanup) AFTER the call,
 * double-cleaning esp by 24 bytes and corrupting the stack → the worker died
 * inside the call. We must NOT clean the stack here.
 *
 * Loop bounds: ring_radius controls the cell ring (ring 0 = single cell).
 * restrict_flag (byte) gates extra bounds checks (0 = off). threat_type is the
 * GTA threat-type enum index. army0 is the 0-based army index.
 */
static float __attribute__((noinline))
call_715ff0(void *tmap, int x_cell, int y_cell,
            int ring_radius, int restrict_flag, int threat_type, int army0)
{
    float result = 0.0f;
    __asm__ volatile (
        /* push args right-to-left: arg6 (army0) first, arg1 (tmap) last */
        "pushl %[army]   \n\t"   /* arg6: army (0-based) */
        "pushl %[ttype]  \n\t"   /* arg5: threat type index */
        "pushl %[restr]  \n\t"   /* arg4: restriction flag */
        "pushl %[ring]   \n\t"   /* arg3: ring radius */
        "pushl %[xcell]  \n\t"   /* arg2: x_cell */
        "pushl %[tmap]   \n\t"   /* arg1: tmap */
        "movl  %[ycell], %%eax \n\t"   /* implicit register arg: y_cell */
        "movl  $0x715ff0, %%ecx \n\t"
        "call  *%%ecx    \n\t"
        /* STDCALL: callee did `ret 0x18`, esp already balanced — do NOT clean */
        "movss %%xmm0, %[res] \n\t"   /* capture float result */
        : [res]   "+m" (result)
        : [tmap]  "g"  (tmap),
          [xcell] "g"  (x_cell),
          [ycell] "g"  (y_cell),
          [ring]  "g"  (ring_radius),
          [restr] "g"  (restrict_flag),
          [ttype] "g"  (threat_type),
          [army]  "g"  (army0)
        : "eax", "ecx", "edx", "esi", "edi",
          "xmm0",
          "cc", "memory"
    );
    return result;
}

/* ── Inline hook (PUSH/RET trampoline — same as faf_profiler) ─────────────
 * Steals `n` bytes (>= 6, must end on an instruction boundary). The patch is
 * always 6 bytes (push imm32; ret); bytes 6..n-1 are NOP-padded so the patched
 * region stays instruction-aligned and the trampoline jumps back to src+n. */
static BYTE* make_inline_hook_n(void *src, void *dst, int n) {
    if (n < 6 || n > 12) return NULL;
    BYTE *tramp = (BYTE*)VirtualAlloc(NULL, 32,
                                      MEM_COMMIT | MEM_RESERVE,
                                      PAGE_EXECUTE_READWRITE);
    if (!tramp) return NULL;

    DWORD old;
    if (!VirtualProtect(src, n, PAGE_EXECUTE_READWRITE, &old)) {
        VirtualFree(tramp, 0, MEM_RELEASE);
        return NULL;
    }
    memcpy(tramp, src, n);

    /* trampoline: [n original bytes] [JMP rel32 → src+n] */
    BYTE *jmp_from = tramp + n + 5;
    BYTE *jmp_to   = (BYTE*)src + n;
    INT32 rel = (INT32)(jmp_to - jmp_from);
    tramp[n] = 0xE9;
    memcpy(tramp + n + 1, &rel, 4);

    BYTE patch[12];
    patch[0] = 0x68;
    *(DWORD*)(patch + 1) = (DWORD)dst;
    patch[5] = 0xC3;
    for (int i = 6; i < n; i++) patch[i] = 0x90;  /* NOP fill */
    memcpy(src, patch, n);
    VirtualProtect(src, n, old, &old);
    return tramp;
}

static BYTE* make_inline_hook(void *src, void *dst) {
    return make_inline_hook_n(src, dst, 6);
}

/* ── Lua function implementations ────────────────────────────────────────── */

/*
 * FAF_OffloadThreatMap(army_index, x1, y1, z1 [, x2, y2, z2, ...])
 *   → handle (integer) or nil if all slots are full
 *
 * Positions are passed as flat varargs: x,y,z triplets starting at stack slot 2.
 * n_positions = (lua_gettop(L) - 1) / 3
 */
static int lua_FAF_OffloadThreatMap(lua_State *L) {
    int nargs = LUA(lua_gettop, L);
    if (nargs < 4) {
        LUA(lua_pushnil, L);
        return 1;
    }

    int army_index = (int)LUA(lua_tonumber, L, 1);
    int n_positions = (nargs - 1) / 3;
    if (n_positions > MAX_POSITIONS) n_positions = MAX_POSITIONS;

    /* Find a free result slot */
    int slot = -1;
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (InterlockedCompareExchange(&g_slots[i].done, 0, -1) == -1) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        LUA(lua_pushnil, L);
        return 1;
    }

    /* Copy positions from Lua stack (sim thread only — do this before enqueue) */
    ResultSlot *rs = &g_slots[slot];
    rs->army_index  = army_index;
    rs->n_positions = n_positions;
    for (int i = 0; i < n_positions; i++) {
        int base = 2 + i * 3;
        rs->px[i] = LUA(lua_tonumber, L, base);
        rs->py[i] = LUA(lua_tonumber, L, base + 1);
        rs->pz[i] = LUA(lua_tonumber, L, base + 2);
    }

    /* Enqueue job — tail increment is the publish */
    LONG tail = InterlockedIncrement(&g_queue_tail) - 1;
    g_queue[tail & (MAX_SLOTS - 1)].slot_index = slot;
    SetEvent(g_work_event);

    LUA(lua_pushnumber, L, (float)slot);
    return 1;
}

/*
 * FAF_PollResult(handle) → nil | result_table
 * result_table is a flat array: {threat1, threat2, ...} (one per input position)
 * Frees the slot on first successful poll.
 */
static int lua_FAF_PollResult(lua_State *L) {
    int slot = (int)LUA(lua_tonumber, L, 1);
    if (slot < 0 || slot >= MAX_SLOTS || g_slots[slot].done != 1) {
        LUA(lua_pushnil, L);
        return 1;
    }

    ResultSlot *rs = &g_slots[slot];

    /* Build result table */
    LUA(lua_newtable, L);                       /* push {} onto stack */
    for (int i = 0; i < rs->n_positions; i++) {
        LUA(lua_pushnumber, L, rs->results[i]); /* push value */
        LUA(lua_rawseti, L, -2, i + 1);         /* table[i+1] = value; pops value */
    }

    /* Free the slot */
    InterlockedExchange(&rs->done, -1);
    return 1;  /* table is at top */
}

/* Register both Lua functions into the global namespace */
static void register_lua_functions(lua_State *L) {
    /* lua_register(L, "FAF_OffloadThreatMap", fn) */
    LUA(lua_pushstring, L, "FAF_OffloadThreatMap");
    LUA(lua_pushcclosure, L, lua_FAF_OffloadThreatMap, 0);
    LUA(lua_rawset, L, LUA_GLOBALSINDEX);

    /* lua_register(L, "FAF_PollResult", fn) */
    LUA(lua_pushstring, L, "FAF_PollResult");
    LUA(lua_pushcclosure, L, lua_FAF_PollResult, 0);
    LUA(lua_rawset, L, LUA_GLOBALSINDEX);

    if (g_log) {
        fprintf(g_log, "FAF_OffloadThreatMap / FAF_PollResult registered\n");
        fflush(g_log);
    }
}

/*
 * Extract and cache g_tmap from the Lua binding state.
 *
 * Called on sim thread from hook_gta. Confirmed chain:
 *
 *   binding_wrapper = *(void**)(L + 0x44)           [getter 0x9240a0]
 *   type_tag        = *(int*)(bw + 0x0c)             [should be 8]
 *   gcobj           = *(void**)(bw + 0x10)           [GCObject* of userdata]
 *   aibrain         = (char*)gcobj + 0x10            [C++ object, vtable@[0]]
 *   sub_obj         = *(void**)(aibrain + 0x34)      [sub-object with own vtable]
 *   vtable          = *(void**)sub_obj
 *   fn              = *(void**)((char*)vtable + 0x18) [vtable[6] = get_threat_map]
 *   tmap            = fn(sub_obj)                    [thiscall, ecx = sub_obj]
 *
 * All pointer steps are guarded; if anything is null we bail without crashing.
 */
static int ptr_image(unsigned int p) {  /* looks like a code/vtable ptr in the EXE image */
    return p >= 0x00400000u && p <= 0x01100000u;
}
static int ptr_heap(unsigned int p) {    /* looks like a readable heap pointer */
    return p >= 0x00010000u && p < 0xC0000000u && !IsBadReadPtr((void*)(uintptr_t)p, 4);
}

/*
 * Given the real AIBrain C++ pointer (captured from 0x5930d0), walk to the
 * threat map and cache it. Step 2 of the chain — confirmed from disassembly of
 * GTA at 0x590530–0x59053c:
 *     sub_obj = *(aibrain + 0x34)
 *     tmap    = sub_obj->vtable[6] (offset 0x18) (sub_obj)   [thiscall, ecx=sub_obj]
 */
/* Walk aibrain → sub_obj → vtable[6]() → CURRENT threat map pointer.
 * Returns NULL on any invalid step. Safe to call repeatedly. */
/* Given the threat sub-object directly: sub_obj->vtable[6](sub_obj) → tmap. */
static void *tmap_from_subobj(void *sub_obj) {
    if (!ptr_heap((unsigned int)(uintptr_t)sub_obj)) return NULL;
    void *sub_vtable = *(void**)sub_obj;
    if (!ptr_image((unsigned int)(uintptr_t)sub_vtable)) return NULL;
    void *fn_ptr = *(void**)((char*)sub_vtable + 0x18);            /* vtable[6] */
    if (!ptr_image((unsigned int)(uintptr_t)fn_ptr)) return NULL;
    return ((fn_get_tmap_t)fn_ptr)(sub_obj);
}

static void *derive_tmap(void *aibrain) {
    if (!ptr_heap((unsigned int)(uintptr_t)aibrain)) return NULL;
    if (!ptr_image(*(unsigned int*)aibrain)) return NULL;          /* aibrain vtable */
    return tmap_from_subobj(*(void**)((char*)aibrain + 0x34));     /* sub_obj at +0x34 */
}

/* The engine's global army list is reachable from ANY aibrain:
 *   army_mgr = *(aibrain + 0xa4)
 *   start    = *(army_mgr + 0x910)   ; end = *(army_mgr + 0x914)
 *   count    = (end - start) / 4     ; element[i] (0-based) = army i's threat
 *                                       SUB-OBJECT (the get-threat-map provider,
 *                                       == that brain's aibrain+0x34)
 * (Confirmed live: element[k] == captured aibrain's sub-object; tmap_from_subobj
 * on each yields 8 distinct per-army maps. Bounds from GTA check 0x5904f4–0x59051c.)
 * Returns army `lua_army` (1-based, as Lua's GetArmyIndex reports) sub-object, or NULL. */
static void *army_object(void *any_aibrain, int lua_army) {
    if (!ptr_heap((unsigned int)(uintptr_t)any_aibrain)) return NULL;
    void *army_mgr = *(void**)((char*)any_aibrain + 0xa4);
    if (!ptr_heap((unsigned int)(uintptr_t)army_mgr)) return NULL;
    unsigned int start = *(unsigned int*)((char*)army_mgr + 0x910);
    unsigned int end   = *(unsigned int*)((char*)army_mgr + 0x914);
    if (!ptr_heap(start) || end < start) return NULL;
    int count = (int)((end - start) / 4);
    int idx = lua_army - 1;                      /* Lua 1-based → 0-based */
    if (idx < 0 || idx >= count) return NULL;
    void *elem = *(void**)((char*)(uintptr_t)start + idx * 4);
    if (!ptr_heap((unsigned int)(uintptr_t)elem)) return NULL;
    return elem;
}

/* Threat map for a specific army, via the global army list. Falls back to the
 * cached g_tmap if the per-army lookup can't be resolved. */
static void *tmap_for_army(int lua_army) {
    if (g_captured_aibrain) {
        void *elem = army_object(g_captured_aibrain, lua_army);
        if (elem) {
            void *t = tmap_from_subobj(elem);   /* element is the threat sub-object */
            if (!t) t = derive_tmap(elem);       /* or a full aibrain */
            if (t) return t;
        }
    }
    return g_tmap;
}

static void cache_tmap_from_aibrain(void *aibrain) {
    void *tmap = derive_tmap(aibrain);
    if (!tmap) { if (g_log) { fprintf(g_log, "cache_tmap: derive failed (aibrain=%p)\n", aibrain); fflush(g_log); } return; }
    g_tmap = tmap;
    if (g_log) {
        fprintf(g_log, "cache_tmap: OK aibrain=%p tmap=%p\n", aibrain, tmap);
        fflush(g_log);
    }
}

/* ── 0x5930d0 hook (naked) — capture the AIBrain the engine extracts ─────────
 * 0x5930d0 takes its arg in EAX and returns the AIBrain in EAX (plain `ret`).
 * We run the original via the trampoline (it returns into us), then, if armed,
 * stash EAX as the captured AIBrain and disarm. EAX is preserved as our return
 * value. Symbols are referenced with the i686 leading-underscore decoration. */
__attribute__((naked, used)) static void hook_x5930d0(void) {
    __asm__ (
        "call *_g_x5930d0_tramp\n\t"      /* eax := real 0x5930d0(arg in eax) */
        "cmpl $0, _g_arm_x5930d0\n\t"
        "je   1f\n\t"
        "movl %eax, _g_captured_aibrain\n\t"
        "movl $0, _g_arm_x5930d0\n\t"     /* one-shot: disarm immediately */
        "1:\n\t"
        "ret\n\t"
    );
}

/* ── GTA hook — register Lua API, and capture the AIBrain → tmap ───────────── */
static int __cdecl hook_gta(lua_State *L) {
    if (InterlockedCompareExchange(&g_lua_registered, 1, 0) == 0) {
        register_lua_functions(L);
    }

    /* Until the threat map is cached, arm the 0x5930d0 capture across the real
     * GTA call. The engine's GTA extracts its `self` AIBrain via 0x5930d0 once;
     * we grab that pointer, then walk it to the threat map. Retries each GTA
     * call until it succeeds (g_tmap set), then stops arming. */
    if (!g_tmap && g_x5930d0_tramp) {
        g_captured_aibrain = NULL;
        InterlockedExchange(&g_arm_x5930d0, 1);
        int r = ((fn_gta_t)g_gta_trampoline)(L);
        InterlockedExchange(&g_arm_x5930d0, 0);  /* belt-and-suspenders disarm */

        if (g_captured_aibrain) {
            cache_tmap_from_aibrain(g_captured_aibrain);
        } else if (g_log) {
            fprintf(g_log, "hook_gta: armed but 0x5930d0 captured nothing this call\n");
            fflush(g_log);
        }
        return r;
    }

    return ((fn_gta_t)g_gta_trampoline)(L);
}

/* ── Worker: per-position threat query ─────────────────────────────────────
 *
 * Uses 0x715c60 (pos→cell, edi=tmap implicit) then 0x715ff0 (threat sum,
 * stdcall, eax=y_cell implicit) to replicate GTA('Overall') off the sim thread.
 *
 * Validated live: returns exactly what the synchronous engine
 * GetThreatAtPosition(pos, 0, true, 'Overall') returns (e.g. 80.0 at an enemy
 * ACU cell, 0.0 at empty cells). ring_radius=0 → single-cell query.
 */
static float query_threat_at(void *tmap, float px, float pz)
{
    float pos[4] = {px, 0.0f, pz, 0.0f};  /* x, y_ignored, z; 16-byte aligned */

    /* Position → flat cell index (0x715c60 reads tmap->field_0x10 for cell_size,
       tmap->field_0x8 for grid_width, via edi register) */
    int cell_idx = call_715c60(tmap, pos);

    /* Decompose into grid coordinates */
    int grid_w = *(int*)((char*)tmap + 0x8);
    if (grid_w <= 0) return 0.0f;
    int x_cell = cell_idx % grid_w;
    int y_cell = cell_idx / grid_w;

    /* Call inner threat accumulation loop. ring_radius=0 (single cell),
     * restrict_flag=0, threat_type=0 ('Overall'). army = -1 → the per-cell
     * function 0x715750 SUMS all per-army threat entries (this is what the
     * engine's default GetThreatAtPosition does — validated 23/23 in a 4v4).
     * Passing a specific army>=0 reads only that one army's contribution. */
    return call_715ff0(tmap, x_cell, y_cell,
                       /*ring_radius=*/0, /*restrict_flag=*/0,
                       /*threat_type=*/0, /*army=*/-1);
}

/* ── Worker thread ────────────────────────────────────────────────────────── */
static DWORD WINAPI worker_thread(LPVOID arg) {
    (void)arg;

    /*
     * Pin worker to a non-sim core.
     * Sim thread pins to the lowest set bit (bit 0) via THREAD_SetAffinity(true).
     * We pin to the second lowest set bit to stay off core 0.
     */
    DWORD_PTR proc_mask, sys_mask;
    GetProcessAffinityMask(GetCurrentProcess(), &proc_mask, &sys_mask);
    int found = 0;
    for (int i = 1; i < 32; i++) {
        if (proc_mask & (1u << i)) {
            SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)(1u << i));
            found = 1;
            break;
        }
    }
    (void)found;

    while (!g_shutdown) {
        WaitForSingleObject(g_work_event, 50);

        /* Claim one job via CAS on head */
        LONG head = g_queue_head;
        LONG tail = g_queue_tail;
        if (head >= tail) continue;
        if (InterlockedCompareExchange(&g_queue_head, head + 1, head) != head)
            continue;

        int slot = g_queue[head & (MAX_SLOTS - 1)].slot_index;
        ResultSlot *rs = &g_slots[slot];

        /* Per-brain: use the QUERYING army's own threat map (looked up via the
         * global army list), re-derived fresh each job. Threat maps are
         * per-brain/team-relative, so the caller's army must select the map. */
        void *tmap = tmap_for_army(rs->army_index);

        for (int i = 0; i < rs->n_positions; i++) {
            if (tmap) {
                rs->results[i] = query_threat_at(tmap, rs->px[i], rs->pz[i]);
            } else {
                rs->results[i] = 0.0f;  /* tmap not yet cached; caller falls back */
            }
        }

        MemoryBarrier();
        InterlockedExchange(&rs->done, 1);
    }
    return 0;
}

/* ── DllMain ──────────────────────────────────────────────────────────────── */
BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved) {
    (void)hInst; (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);

        g_log = fopen("Z:\\tmp\\faf_worker.log", "w");
        if (g_log) { fprintf(g_log, "faf_worker: attached\n"); fflush(g_log); }

        /* Init all slots as free */
        for (int i = 0; i < MAX_SLOTS; i++)
            g_slots[i].done = -1;

        /* Auto-reset event: each SetEvent wakes exactly one waiting worker */
        g_work_event = CreateEvent(NULL, FALSE, FALSE, NULL);

        for (int i = 0; i < N_WORKERS; i++) {
            g_workers[i] = CreateThread(NULL, 0, worker_thread, NULL, 0, NULL);
            if (g_log) {
                fprintf(g_log, "worker[%d]: %p\n", i, (void*)g_workers[i]);
                fflush(g_log);
            }
        }

        /* Install GTA hook to capture lua_State* and tmap on first AI call */
        void *gta_src = (void*)GTA_VA;
        BYTE expected[6] = {0x8b, 0x44, 0x24, 0x04, 0x53, 0x50};
        if (memcmp(gta_src, expected, 6) != 0) {
            if (g_log) {
                BYTE *b = (BYTE*)gta_src;
                fprintf(g_log, "GTA_VA byte mismatch: %02x %02x %02x %02x %02x %02x\n",
                        b[0], b[1], b[2], b[3], b[4], b[5]);
                fflush(g_log);
            }
            return TRUE;  /* workers run but Lua functions won't register */
        }

        g_gta_trampoline = make_inline_hook(gta_src, hook_gta);
        if (g_log) {
            fprintf(g_log, "GTA hook installed: VA=0x%x tramp=%p\n",
                    GTA_VA, (void*)g_gta_trampoline);
            fflush(g_log);
        }

        /* Install the 0x5930d0 "get AIBrain from arg1" hook. Its prologue is
         * 7 bytes of whole instructions (sub esp,0x18 / push esi / sub esp,0x14),
         * so steal 7. We capture its return value while armed (see hook_gta). */
        void *unwrap_src = (void*)0x5930d0;
        BYTE expect_unwrap[7] = {0x83, 0xec, 0x18, 0x56, 0x83, 0xec, 0x14};
        if (memcmp(unwrap_src, expect_unwrap, 7) != 0) {
            if (g_log) {
                BYTE *b = (BYTE*)unwrap_src;
                fprintf(g_log, "0x5930d0 byte mismatch: %02x %02x %02x %02x %02x %02x %02x\n",
                        b[0], b[1], b[2], b[3], b[4], b[5], b[6]);
                fflush(g_log);
            }
        } else {
            g_x5930d0_tramp = (void*)make_inline_hook_n(unwrap_src, (void*)hook_x5930d0, 7);
            if (g_log) {
                fprintf(g_log, "0x5930d0 hook installed: tramp=%p\n", g_x5930d0_tramp);
                fflush(g_log);
            }
        }
    }

    if (reason == DLL_PROCESS_DETACH) {
        InterlockedExchange(&g_shutdown, 1);
        if (g_work_event) {
            SetEvent(g_work_event);
            WaitForMultipleObjects(N_WORKERS, g_workers, TRUE, 2000);
            CloseHandle(g_work_event);
        }
        for (int i = 0; i < N_WORKERS; i++)
            if (g_workers[i]) CloseHandle(g_workers[i]);
        if (g_log) { fprintf(g_log, "faf_worker: detached\n"); fclose(g_log); }
    }

    return TRUE;
}

__declspec(dllexport) int faf_worker_init(void) { return 0; }
