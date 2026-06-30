/*
 * faf_profiler.dll — GetThreatAtPosition call-time profiler
 *
 * Injected into ForgedAlliance.exe via PE import patching (inject_import.py).
 *
 * ForgedAlliance.exe (FAF version) has LuaPlus and MohoEngine statically
 * linked — no separate DLLs to hook.  ASLR is disabled; the EXE always
 * loads at 0x00400000.
 *
 * We install a 6-byte PUSH/RET inline hook at the Lua C binding for
 * GetThreatAtPosition, VA 0x00590260.  That address was found by:
 *   1. Locating the string "Invalid army index passed in to GetThreatAtPosition"
 *      in .rdata (VA 0x00e1ac24).
 *   2. Tracing the single call site back to its wrapper (VA 0x00590260).
 *
 * Output:
 *   Z:\tmp\faf_profiler.log  (= /tmp/faf_profiler.log)
 *   Z:\tmp\faf_profile.csv   (= /tmp/faf_profile.csv)  per-call timing
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* VA of the Lua C binding for GetThreatAtPosition (ASLR=0, base 0x400000) */
#define GTA_VA   0x00590260u

typedef int (__cdecl *fn_gta_t)(void *L);

static BYTE* g_gta_trampoline = NULL;
static volatile LONG g_gta_calls = 0;

static FILE* g_csv = NULL;
static FILE* g_log = NULL;
static LARGE_INTEGER g_qpf;

/* ---- 6-byte PUSH/RET inline hook with trampoline ---- */
static BYTE* make_inline_hook(void *src, void *dst) {
    BYTE *tramp = (BYTE*)VirtualAlloc(NULL, 32,
                                      MEM_COMMIT | MEM_RESERVE,
                                      PAGE_EXECUTE_READWRITE);
    if (!tramp) return NULL;

    DWORD old;
    if (!VirtualProtect(src, 6, PAGE_EXECUTE_READWRITE, &old)) {
        if (g_log) {
            fprintf(g_log, "VirtualProtect(%p) failed: %lu\n", src, GetLastError());
            fflush(g_log);
        }
        VirtualFree(tramp, 0, MEM_RELEASE);
        return NULL;
    }

    memcpy(tramp, src, 6);                  /* save original 6 bytes */

    /* Trampoline: [6 original bytes] [JMP rel32 → src+6] */
    BYTE *jmp_from = tramp + 11;            /* instruction after the JMP */
    BYTE *jmp_to   = (BYTE*)src + 6;
    INT32 rel = (INT32)(jmp_to - jmp_from);
    tramp[6] = 0xE9;
    memcpy(tramp + 7, &rel, 4);

    /* Patch src: PUSH dst; RET */
    BYTE patch[6];
    patch[0] = 0x68;
    *(DWORD*)(patch + 1) = (DWORD)dst;
    patch[5] = 0xC3;
    memcpy(src, patch, 6);
    VirtualProtect(src, 6, old, &old);
    return tramp;
}

/* ---- GetThreatAtPosition hook ---- */
static int __cdecl hook_gta(void *L) {
    LARGE_INTEGER t1, t2;
    QueryPerformanceCounter(&t1);

    int r = ((fn_gta_t)g_gta_trampoline)(L);

    QueryPerformanceCounter(&t2);
    double us = (double)(t2.QuadPart - t1.QuadPart) * 1e6 /
                (double)g_qpf.QuadPart;
    LONG seq = InterlockedIncrement(&g_gta_calls);
    if (g_csv) {
        fprintf(g_csv, "%ld,%.2f\n", (long)seq, us);
        if (seq % 200 == 0) fflush(g_csv);
    }
    return r;
}

/* ---- DllMain ---- */
BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved) {
    (void)hInst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);
        QueryPerformanceFrequency(&g_qpf);

        g_log = fopen("Z:\\tmp\\faf_profiler.log", "w");
        if (g_log) { fprintf(g_log, "DllMain: attached\n"); fflush(g_log); }

        void *gta_src = (void*)GTA_VA;

        /* Verify the bytes at GTA_VA match what we expect */
        BYTE expected[6] = {0x8b, 0x44, 0x24, 0x04, 0x53, 0x50};
        if (memcmp(gta_src, expected, 6) != 0) {
            if (g_log) {
                BYTE *b = (BYTE*)gta_src;
                fprintf(g_log, "MISMATCH at GTA_VA=%#x: got %02x %02x %02x %02x %02x %02x\n",
                        GTA_VA, b[0], b[1], b[2], b[3], b[4], b[5]);
                fflush(g_log);
            }
            return TRUE;  /* abort hook, game still runs */
        }
        if (g_log) { fprintf(g_log, "GTA bytes verified\n"); fflush(g_log); }

        g_csv = fopen("Z:\\tmp\\faf_profile.csv", "w");
        if (g_csv) { fprintf(g_csv, "call_num,elapsed_us\n"); fflush(g_csv); }

        g_gta_trampoline = make_inline_hook(gta_src, hook_gta);
        if (g_log) {
            fprintf(g_log, "hook installed: GTA_VA=%#x tramp=%p\n",
                    GTA_VA, (void*)g_gta_trampoline);
            fflush(g_log);
        }
    }
    return TRUE;
}

__declspec(dllexport) int faf_profiler_init(void) { return 0; }
