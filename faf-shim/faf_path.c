/*
 * faf_path.dll — multi-core pathfinding offload shim.
 *
 * Offloads FAF's NavUtils.PathTo A* onto worker threads. The sim (Lua) exports the
 * static NavSection graph once (after NavGenerator.Generate) via FAF_PathSection, then
 * enqueues section->section queries via FAF_OffloadPath and reads results next tick via
 * FAF_PollPath. The A* is a C port of NavUtils.PathTo + NavDatastructures.NavHeap, proven
 * bit-identical to FAF's Lua A* (faf-shim/pathto_spike, 800/800). Determinism relies on
 * double-precision section centers + SSE2 math (build with -mfpmath=sse -msse2).
 *
 * Injected into ForgedAlliance_faf.exe via PE import patching (inject_import.py). The
 * FAForever build shares the old build's LuaPlus ABI (VAs below verified against it).
 *
 * Lua API registered (on the first GTA call, when a lua_State is in hand):
 *   FAF_PathReset(maxSectionId)                         -- allocate for a fresh mesh
 *   FAF_PathSection(id, cx, cz, label, nb1, nb2, ...)   -- one call per section
 *   FAF_PathReady()                                     -- mesh load complete
 *   handle = FAF_OffloadPath(originId, destId)          -- enqueue; returns slot handle
 *   result = FAF_PollPath(handle)  -> nil | {id1, id2, ...}   -- dest->origin chain, or nil
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

/* ── LuaPlus ABI (VAs shared with the old build; verified against FAForever) ── */
typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
#define LUA_GLOBALSINDEX  ((int)0xffffd8ef)

/* Hook a Lua C binding purely to obtain a lua_State on first call, then register.
 * CanBuildStructureAt (0x58b3a0) is called thousands of times from the first base-
 * building tick, so it registers far earlier than GTA (which waits for armies).
 * Both are identical thin stubs: mov L; push ebx; mov L+0x44; call real (8-byte boundary). */
#define REG_HOOK_VA           0x0058b3a0u  /* CanBuildStructureAt */
#define VA_lua_gettop         0x90c590u
#define VA_luaL_error         0x90c1d0u
#define VA_lua_type           0x90c740u
#define VA_lua_tonumber       0x90c9f0u   /* lua_Number (double) in st(0) */
#define VA_lua_pushnil        0x90cd00u
#define VA_lua_pushnumber     0x90cd40u
#define VA_lua_pushcclosure   0x90ced0u
#define VA_lua_newtable       0x90d110u
#define VA_lua_rawseti        0x90d2f0u
#define VA_lua_rawset         0x90d260u
#define VA_lua_pushstring     0x90cdf0u

typedef int    (__cdecl *fn_lua_gettop_t)      (lua_State*);
typedef void   (__cdecl *fn_luaL_error_t)      (lua_State*, const char*, ...);
typedef int    (__cdecl *fn_lua_type_t)        (lua_State*, int);
typedef double (__cdecl *fn_lua_tonumber_t)    (lua_State*, int);  /* DOUBLE — precision matters */
typedef void   (__cdecl *fn_lua_pushnil_t)     (lua_State*);
typedef void   (__cdecl *fn_lua_pushnumber_t)  (lua_State*, float);   /* lua_Number = float here */
typedef void   (__cdecl *fn_lua_pushcclosure_t)(lua_State*, lua_CFunction, int);
typedef void   (__cdecl *fn_lua_newtable_t)    (lua_State*);
typedef void   (__cdecl *fn_lua_rawseti_t)     (lua_State*, int, int);
typedef void   (__cdecl *fn_lua_rawset_t)      (lua_State*, int);
typedef void   (__cdecl *fn_lua_pushstring_t)  (lua_State*, const char*);
#define LUA(fn, ...) ((fn_##fn##_t)VA_##fn)(__VA_ARGS__)

typedef int (__cdecl *fn_reg_t)(lua_State *L);

/* ── config ──────────────────────────────────────────────────────────────── */
#define N_WORKERS 3
#define MAX_SLOTS 64          /* power of 2 */
#define MAX_NB    64          /* max neighbors per section */
#define FAF_MAX_PATH  4096        /* max path length (<= nSections) */

static FILE *g_log = NULL;

/* ── static navmesh (loaded once; read-only during A*) ───────────────────── */
static int      g_maxId      = 0;
static volatile LONG g_mesh_ready = 0;
static double  *g_cx = NULL, *g_cz = NULL;   /* [id] */
static int     *g_label = NULL;              /* [id]  (0 = no section) */
static int     *g_nb = NULL;                 /* [id*MAX_NB + k] */
static int     *g_nbCount = NULL;            /* [id] */

/* ── per-worker A* scratch (no shared mutable state) ─────────────────────── */
typedef struct {
    int    *seen;   /* == qid when discovered this query */
    int    *from;   /* predecessor id (-1 = none) */
    double *g, *f;
    int    *heap;   /* 1-based min-heap of ids, compared via f[] */
    int     heapSize;
    int     qid;
} Ctx;
static Ctx g_ctx[N_WORKERS];

static void ctx_alloc(Ctx *c) {
    int n = g_maxId + 1;
    c->seen = (int*)calloc(n, sizeof(int));
    c->from = (int*)malloc(n * sizeof(int));
    c->g    = (double*)malloc(n * sizeof(double));
    c->f    = (double*)malloc(n * sizeof(double));
    c->heap = (int*)malloc((n + 2) * sizeof(int));
    c->heapSize = 0; c->qid = 0;
}

/* ── NavHeap port (exact: 1-based, tie-break = strict </> on f) ──────────── */
static inline void h_rootify(Ctx *c) {
    int index = c->heapSize, parent = index / 2;
    while (parent >= 1) {
        if (c->f[c->heap[parent]] < c->f[c->heap[index]]) return;
        int t = c->heap[parent]; c->heap[parent] = c->heap[index]; c->heap[index] = t;
        index = parent; parent = parent / 2;
    }
}
static inline void h_insert(Ctx *c, int id) {
    c->heap[++c->heapSize] = id; h_rootify(c);
}
static inline void h_heapify(Ctx *c) {
    int index = 1, left = 2, right = 3;
    while (left <= c->heapSize) {
        int mn = left;
        if (right <= c->heapSize && c->f[c->heap[right]] < c->f[c->heap[left]]) mn = right;
        if (c->f[c->heap[mn]] > c->f[c->heap[index]]) return;
        int t = c->heap[mn]; c->heap[mn] = c->heap[index]; c->heap[index] = t;
        index = mn; left = 2*index; right = 2*index + 1;
    }
}
static inline int h_extract_min(Ctx *c) {
    if (c->heapSize == 0) return -1;
    int v = c->heap[1];
    c->heap[1] = c->heap[c->heapSize];
    c->heapSize--;
    h_heapify(c);
    return v;
}

static inline double dist(int a, int b) {
    double dx = g_cx[a] - g_cx[b];
    double dz = g_cz[a] - g_cz[b];
    return sqrt(dx*dx + dz*dz);
}

/* PathTo A*, replicating FAF exactly (incl. the same-label "always found" bug).
 * Fills outPath[0..*outLen-1] with the dest->origin id chain. Returns found. */
static int astar(Ctx *c, int oId, int dId, int *outPath, int *outLen) {
    *outLen = 0;
    if (oId < 0 || oId > g_maxId || dId < 0 || dId > g_maxId) return 0;
    if (g_label[oId] <= 0 || g_label[dId] <= 0) return 0;
    if (g_label[oId] != g_label[dId]) return 0;             /* CanPathTo pre-filter */
    c->qid++;
    c->heapSize = 0;
    c->seen[oId] = c->qid; c->from[oId] = -1; c->g[oId] = 0.0; c->f[oId] = dist(oId, dId);
    h_insert(c, oId);
    while (c->heapSize > 0) {
        int sec = h_extract_min(c);
        if (sec == dId) break;
        int base = sec * MAX_NB, cnt = g_nbCount[sec];
        for (int k = 0; k < cnt; k++) {
            int nb = g_nb[base + k];
            if (nb < 0 || nb > g_maxId) continue;
            if (g_label[nb] > 0 && c->seen[nb] != c->qid) {
                c->seen[nb] = c->qid;
                c->from[nb] = sec;
                c->g[nb] = c->g[sec] + dist(sec, nb);
                c->f[nb] = c->g[nb] + dist(dId, nb);
                h_insert(c, nb);
            }
        }
    }
    /* FAF's bugged guard never returns nil for a same-label pair -> found=true.
     * Trace via fresh HeapFrom only; unreached dest -> degenerate [dest]. */
    int cur = dId, guard = 0, len = 0;
    while (cur >= 0 && guard < FAF_MAX_PATH) {
        outPath[len++] = cur;
        int pr = (c->seen[cur] == c->qid) ? c->from[cur] : -1;
        if (pr < 0) break;
        cur = pr; guard++;
    }
    *outLen = len;
    return 1;
}

/* ── job queue / result slots ────────────────────────────────────────────── */
typedef struct {
    volatile LONG done;   /* -1 free, 0 pending, 1 complete */
    int origin, dest;
    int pathLen;
    int found;
    int path[FAF_MAX_PATH];   /* dest->origin ids */
} PathSlot;

typedef struct { int slot; } Job;

static PathSlot     g_slots[MAX_SLOTS];
static Job          g_queue[MAX_SLOTS];
static volatile LONG g_qhead = 0, g_qtail = 0;
static HANDLE       g_work_event = NULL;
static HANDLE       g_workers[N_WORKERS];
static volatile LONG g_shutdown = 0;
static volatile LONG g_registered = 0;

/* ── Lua-facing functions ────────────────────────────────────────────────── */
static int lua_FAF_PathReset(lua_State *L) {
    int maxId = (int)LUA(lua_tonumber, L, 1);
    if (maxId < 1 || maxId > 5000000) return 0;
    InterlockedExchange(&g_mesh_ready, 0);
    free(g_cx); free(g_cz); free(g_label); free(g_nb); free(g_nbCount);
    int n = maxId + 1;
    g_maxId = maxId;
    g_cx = (double*)calloc(n, sizeof(double));
    g_cz = (double*)calloc(n, sizeof(double));
    g_label = (int*)calloc(n, sizeof(int));
    g_nb = (int*)malloc((size_t)n * MAX_NB * sizeof(int));
    g_nbCount = (int*)calloc(n, sizeof(int));
    for (int w = 0; w < N_WORKERS; w++) {
        free(g_ctx[w].seen); free(g_ctx[w].from); free(g_ctx[w].g); free(g_ctx[w].f); free(g_ctx[w].heap);
        ctx_alloc(&g_ctx[w]);
    }
    if (g_log) { fprintf(g_log, "FAF_PathReset maxId=%d\n", maxId); fflush(g_log); }
    return 0;
}

static int lua_FAF_PathSection(lua_State *L) {
    int top = LUA(lua_gettop, L);
    if (top < 4 || !g_label) return 0;
    int id    = (int)LUA(lua_tonumber, L, 1);
    double cx =      LUA(lua_tonumber, L, 2);
    double cz =      LUA(lua_tonumber, L, 3);
    int label = (int)LUA(lua_tonumber, L, 4);
    if (id < 0 || id > g_maxId) return 0;
    g_cx[id] = cx; g_cz[id] = cz; g_label[id] = label;
    int cnt = 0, base = id * MAX_NB;
    for (int i = 5; i <= top && cnt < MAX_NB; i++) {
        g_nb[base + cnt] = (int)LUA(lua_tonumber, L, i);
        cnt++;
    }
    g_nbCount[id] = cnt;
    if ((id == 1 || id == 34 || id == 142) && g_log) {   /* precision check vs spike export */
        fprintf(g_log, "SEC %d cx=%.17g cz=%.17g label=%d nb=%d\n", id, cx, cz, label, cnt);
        fflush(g_log);
    }
    return 0;
}

static int lua_FAF_PathReady(lua_State *L) {
    (void)L;
    InterlockedExchange(&g_mesh_ready, 1);
    if (g_log) { fprintf(g_log, "FAF_PathReady (mesh loaded)\n"); fflush(g_log); }
    return 0;
}

static int lua_FAF_OffloadPath(lua_State *L) {
    if (!g_mesh_ready) { LUA(lua_pushnil, L); return 1; }
    int origin = (int)LUA(lua_tonumber, L, 1);
    int dest   = (int)LUA(lua_tonumber, L, 2);
    int slot = -1;
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (InterlockedCompareExchange(&g_slots[i].done, 0, -1) == -1) { slot = i; break; }
    }
    if (slot < 0) { LUA(lua_pushnil, L); return 1; }   /* no free slot -> caller falls back */
    PathSlot *ps = &g_slots[slot];
    ps->origin = origin; ps->dest = dest; ps->pathLen = 0; ps->found = 0;
    LONG tail = InterlockedIncrement(&g_qtail) - 1;
    g_queue[tail & (MAX_SLOTS - 1)].slot = slot;
    SetEvent(g_work_event);
    LUA(lua_pushnumber, L, (double)slot);
    return 1;
}

static int lua_FAF_PollPath(lua_State *L) {
    int slot = (int)LUA(lua_tonumber, L, 1);
    if (slot < 0 || slot >= MAX_SLOTS) { LUA(lua_pushnil, L); return 1; }
    PathSlot *ps = &g_slots[slot];
    if (ps->done != 1) { LUA(lua_pushnil, L); return 1; }   /* still pending */
    if (!ps->found) {
        InterlockedExchange(&ps->done, -1);
        LUA(lua_pushnil, L);                                 /* different labels: no path */
        return 1;
    }
    LUA(lua_newtable, L);
    for (int i = 0; i < ps->pathLen; i++) {
        LUA(lua_pushnumber, L, (double)ps->path[i]);
        LUA(lua_rawseti, L, -2, i + 1);
    }
    InterlockedExchange(&ps->done, -1);                      /* free slot on first poll */
    return 1;
}

static void register_lua(lua_State *L) {
    const struct { const char *name; lua_CFunction fn; } fns[] = {
        { "FAF_PathReset",   lua_FAF_PathReset   },
        { "FAF_PathSection", lua_FAF_PathSection },
        { "FAF_PathReady",   lua_FAF_PathReady   },
        { "FAF_OffloadPath", lua_FAF_OffloadPath },
        { "FAF_PollPath",    lua_FAF_PollPath    },
    };
    for (int i = 0; i < 5; i++) {
        LUA(lua_pushstring, L, fns[i].name);
        LUA(lua_pushcclosure, L, fns[i].fn, 0);
        LUA(lua_rawset, L, LUA_GLOBALSINDEX);
    }
    if (g_log) { fprintf(g_log, "path Lua functions registered\n"); fflush(g_log); }
}

/* ── worker ──────────────────────────────────────────────────────────────── */
static DWORD WINAPI worker_thread(LPVOID arg) {
    int wid = (int)(intptr_t)arg;
    /* pin off core 0 (the sim core) */
    DWORD_PTR pm, sm;
    GetProcessAffinityMask(GetCurrentProcess(), &pm, &sm);
    int seen = 0;
    for (int i = 1; i < 32; i++) if (pm & (1u << i)) {
        if (seen++ == wid % 8) { SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)(1u << i)); break; }
    }
    Ctx *c = &g_ctx[wid];
    while (!g_shutdown) {
        WaitForSingleObject(g_work_event, 50);
        for (;;) {
            LONG head = g_qhead, tail = g_qtail;
            if (head >= tail) break;
            if (InterlockedCompareExchange(&g_qhead, head + 1, head) != head) continue;
            int slot = g_queue[head & (MAX_SLOTS - 1)].slot;
            PathSlot *ps = &g_slots[slot];
            if (g_mesh_ready) {
                ps->found = astar(c, ps->origin, ps->dest, ps->path, &ps->pathLen);
            } else {
                ps->found = 0; ps->pathLen = 0;
            }
            MemoryBarrier();
            InterlockedExchange(&ps->done, 1);
        }
    }
    return 0;
}

/* ── GTA hook (grab L on first call, register, then chain) ───────────────── */
static BYTE *g_reg_tramp = NULL;

/* Steal n>=6 bytes (must end on an instruction boundary): patch = push imm32; ret (6)
 * + NOP pad to n; trampoline = n original bytes + JMP rel32 -> src+n. */
static BYTE* make_inline_hook_n(void *src, void *dst, int n) {
    if (n < 6 || n > 16) return NULL;
    BYTE *tramp = (BYTE*)VirtualAlloc(NULL, 32, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tramp) return NULL;
    DWORD old;
    if (!VirtualProtect(src, n, PAGE_EXECUTE_READWRITE, &old)) { VirtualFree(tramp, 0, MEM_RELEASE); return NULL; }
    memcpy(tramp, src, n);
    BYTE *jf = tramp + n + 5; BYTE *jt = (BYTE*)src + n;
    INT32 rel = (INT32)(jt - jf);
    tramp[n] = 0xE9; memcpy(tramp + n + 1, &rel, 4);
    BYTE patch[16]; patch[0] = 0x68; *(DWORD*)(patch + 1) = (DWORD)(uintptr_t)dst; patch[5] = 0xC3;
    for (int i = 6; i < n; i++) patch[i] = 0x90;
    memcpy(src, patch, n);
    VirtualProtect(src, n, old, &old);
    return tramp;
}

static volatile LONG g_hookfires = 0;
static int __cdecl hook_reg(lua_State *L) {
    LONG n = InterlockedIncrement(&g_hookfires);
    if (n <= 3 && g_log) { fprintf(g_log, "hook_reg fired #%ld L=%p\n", n, (void*)L); fflush(g_log); }
    if (InterlockedCompareExchange(&g_registered, 1, 0) == 0) register_lua(L);
    return ((fn_reg_t)g_reg_tramp)(L);
}

/* ── DllMain ─────────────────────────────────────────────────────────────── */
BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);
        g_log = fopen("Z:\\tmp\\faf_path.log", "w");
        if (g_log) { fprintf(g_log, "faf_path: attached\n"); fflush(g_log); }
        for (int i = 0; i < MAX_SLOTS; i++) g_slots[i].done = -1;
        g_work_event = CreateEvent(NULL, FALSE, FALSE, NULL);
        for (int i = 0; i < N_WORKERS; i++)
            g_workers[i] = CreateThread(NULL, 0, worker_thread, (LPVOID)(intptr_t)i, 0, NULL);
        g_reg_tramp = make_inline_hook_n((void*)(uintptr_t)REG_HOOK_VA, (void*)hook_reg, 8);
        if (g_log) {
            BYTE *p = (BYTE*)(uintptr_t)REG_HOOK_VA;   /* read back to confirm the patch applied */
            fprintf(g_log, "hook installed=%p, %d workers; hook bytes now: %02x %02x %02x %02x %02x %02x\n",
                    (void*)g_reg_tramp, N_WORKERS, p[0], p[1], p[2], p[3], p[4], p[5]);
            fflush(g_log);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        InterlockedExchange(&g_shutdown, 1);
    }
    return TRUE;
}

__declspec(dllexport) int faf_path_init(void) { return 0; }
