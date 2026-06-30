# LuaPlus VA Table — ForgedAlliance.exe

Statically linked LuaPlus in ForgedAlliance.exe (ASLR disabled, base 0x00400000).
All VAs confirmed via objdump disassembly cross-referenced against known string anchors.

## String constant offsets

| Value | Meaning |
|-------|---------|
| `0xffffd8ef` (−10001) | `LUA_GLOBALSINDEX` |
| `0xffffd8f0` (−10000) | `LUA_REGISTRYINDEX` |

## Lua_State* global

| VA | Description |
|----|------------|
| `0xf5a124` | Global pointer to main `lua_State*` (read at `0x590280`) |

## Type tag constants (TValue.tag == lua_type() return value)

| Tag | LuaPlus constant |
|-----|-----------------|
| 0 | LUA_TNIL |
| 1 | LUA_TBOOLEAN |
| 3 | LUA_TNUMBER (single-precision float in value field) |
| 4 | LUA_TSTRING |
| 5 | LUA_TTABLE |
| 6 | LUA_TFUNCTION |
| 7 | LUA_TUSERDATA |

`lua_type()` returns the raw TValue.tag field directly (no translation table).

## TValue layout

Each stack slot = 8 bytes: `[tag: uint32][value: uint32]`
- Number: `[3][float32]`
- String: `[4][GCObject* → string data at +0x14]`
- Function/Closure: `[6][Closure* → C fn ptr at +0x10]`

## Confirmed Lua API VAs

| Function signature | VA |
|-------------------|-----|
| `int lua_gettop(L)` | `0x90c590` |
| `void* lua_topointer(L, idx)` (index→slot) | `0x90c340` |
| `void lua_pushvalue(L, idx)` | `0x90c6e0` |
| `void luaL_error(L, fmt, ...)` | `0x90c1d0` |
| `int lua_type(L, idx)` | `0x90c740` |
| `int lua_isnumber(L, idx)` | `0x90c7a0` |
| `float lua_tonumber(L, idx)` ← returns via FPU st(0) | `0x90c9f0` |
| `const char* lua_tostring(L, idx)` | `0x90ca90` |
| `void lua_pushnil(L)` | `0x90cd00` |
| `void lua_pushnumber(L, float n)` | `0x90cd40` |
| `void lua_pushlstring(L, str, len)` | `0x90cd80` |
| `void lua_pushstring(L, s)` | `0x90cdf0` |
| `void lua_pushcclosure(L, fn_ptr, n_upvalues)` | `0x90ced0` |
| `void lua_newtable(L)` ← `lua_createtable(L,0,0)` equivalent | `0x90d110` |
| `void lua_gettable(L, idx)` ← uses stack top as key, replaces with value | `0x90d000` |
| `void lua_rawget(L, idx)` ← bypasses metamethods | `0x90d050` |
| `void lua_rawgeti(L, idx, int n)` ← pushes `table[n]` | `0x90d0a0` |
| `void lua_rawset(L, idx)` ← pops key+value (2 slots) | `0x90d260` |
| `void lua_rawseti(L, idx, int n)` ← pops value, sets `table[n]` | `0x90d2f0` |

### lua_pushcfunction macro
`lua_pushcfunction(L, f)` = `lua_pushcclosure(L, f, 0)` = call `0x90ced0` with third arg = 0.

### lua_pop macro
`lua_pop(L, n)` requires `lua_settop` — `lua_settop` VA not yet confirmed.  
**Workaround:** use `lua_rawseti` which pops automatically, or restructure code to avoid manual pops.

### lua_register macro
```c
// lua_register(L, "name", fn) is:
lua_pushstring(L, "name");    // 0x90cdf0
lua_pushcclosure(L, fn, 0);   // 0x90ced0
lua_rawset(L, LUA_GLOBALSINDEX); // 0x90d260 with idx=0xffffd8ef
```

### lua_tonumber calling convention note
`0x90c9f0` returns float via x87 FPU `fld dword` instruction (loads `TValue.value` as float32 → st(0)).  
Declare return type as `float` in C typedef. On MSVC/MinGW x86, `float`-returning cdecl functions return via `st(0)`.

## Engine threat map VAs

| VA | Description |
|----|------------|
| `0x590260` | `GetThreatAtPosition` — Lua C binding (wrapper) |
| `0x5902e0` | Inner implementation of GTA Lua binding |
| `0x715c60` | Position→grid index converter: `(L, vec3*) → int cell_index` |
| `0x715ff0` | Threat accumulation loop: takes 6 args including threat map object ptr; sums threat values across a ring of cells |

### 0x715ff0 — CORRECTED & VALIDATED (2026-06-29)

**STDCALL, not cdecl.** 0x715ff0 ends with `ret 0x18` — it pops its own 6 args.
The caller must NOT clean the stack. (The old worker wrapper added `addl $24`
after the call, double-cleaning esp by 24 bytes → stack corruption → the worker
thread died inside the call. This was the sole cause of the offload hang.)

True signature (from the engine call site `0x59054a–0x590562` + the body):
```c
float __stdcall f715ff0(void *tmap,      // arg1
                        int   x_cell,    // arg2  (cell_idx % grid_w)
                        int   ring_radius,// arg3 (0 = single cell; loop bound y_cell±C)
                        int   restrict_flag, // arg4 (byte flag; 0 = off)
                        int   threat_type,   // arg5 (enum index; 0 = 'Overall')
                        int   army);     // arg6  (1-based army index, AS-IS — NOT army-1)
// implicit: eax = y_cell (cell_idx / grid_w)   ; returns float in xmm0
```
Push order at the call site (arg6 first … arg1 last), with `eax = y_cell`.

**Threat-type index** matches the `BrainThreatType` Lua alias order — confirmed by
a live sweep at an enemy-ACU cell: `0`→Overall(=80), `11`→AntiSurface(=75),
`13`→Economy(=5). **Army index is passed as-is** (the brain's `GetArmyIndex()`,
1-based) — the sweep showed `army=1` yields the threat, `army=0` yields nothing.

Validated: `query_threat_at` (worker thread) returns exactly the synchronous
`GetThreatAtPosition(pos,0,true,'Overall')` value (80.0 at the enemy ACU cell,
0.0 at empty cells). See `faf_worker.c:call_715ff0` / `query_threat_at`.

### How to obtain the threat map object pointer (for direct calls from worker threads)

**STATUS (2026-06-29): SOLVED via an armed second hook on `0x5930d0`.** The static
chain below was wrong (the failures are kept as a record of what NOT to retry). The
working solution: hook `0x5930d0` (returns the AIBrain in EAX), arm it only across the
real GTA trampoline call from `hook_gta`, capture EAX, then run step 2
(`aibrain+0x34` → `vtable[6]@0x18` thiscall) to get the threat map. See
`faf-worker-design.md` → "AIBrain pointer / threat map pointer — RESOLVED" and
`faf_worker.c` (`hook_x5930d0`, `cache_tmap_from_aibrain`). Worker chain is 5/5 green.

#### What was WRONG in the earlier "RESOLVED" chain
- `bw = *(L+0x44)` is correct as the engine's getter (`0x9240a0` is literally
  `mov eax,[esp+4]; mov eax,[eax+0x44]; ret`), BUT `bw` is a LuaPlus **LuaState
  wrapper**, NOT the AIBrain userdata. Live dump: `bw+0x0c` is a heap pointer
  (not `8`), `bw+0x00 == L`, and `bw+0x4c` holds a traceback string.
- So `type_tag@bw+0x0c==8` and `gcobj@bw+0x10` never held. `try_cache_tmap`
  failed at runtime with `type_tag=215670540`.

#### Ground truth from disassembly of GTA (`0x590260` → `0x5902e0`)
```
0x590260: mov eax,[esp+4]      ; L (LuaState wrapper)
          push eax
          call 0x90a510         ; = jmp 0x9240a0 → returns *(L+0x44) = bw
          mov ebx, eax          ; ebx = bw
          call 0x5902e0         ; inner worker
; inside 0x5902e0:
0x590345: call 0x908a70         ; build LuaStackObject(bw, index=1)  [self]
0x59035b: call 0x5930d0         ; → AIBrain C++ ptr (RTTI-checked downcast)
0x590364: mov [esp+8], eax      ; aibrain stored
0x59052c: mov eax,[esp+8]       ; eax = aibrain
0x590530: mov ecx,[eax+0x34]    ; sub_obj
0x590533: mov edx,[ecx]         ; sub_obj vtable
0x590535: mov eax,[edx+0x18]    ; vtable[6]
0x59053c: call eax              ; thiscall(ecx=sub_obj) → tmap
```
So `self` (the AIBrain) is **Lua stack argument 1**, unwrapped by `0x5930d0`
(a dynamic_cast via cached type descriptor at `0x10c6fa0`, helper `0x8d9590`).
Step 2 (`aibrain+0x34` → `vtable[6]@+0x18` thiscall, `this=sub_obj`) is confirmed.

#### Extraction attempts that FAILED (do not retry these)
- `*(L+8)` as stack base → slots were string/function, not the self userdata
  (`L` is the wrapper, not a raw lua_State).
- Global `*(0xf5a124)` as main lua_State → returned an image address
  (`0xf5a1d8`), not a heap state; slots were ASCII text. `0xf5a124` is NOT a
  lua_State pointer here.
- Broad scan of every heap pointer in `L`/`bw`, treating each as a lua_State and
  reading `*(state+8)` slots 0..5 for a tag-7 userdata with a C++ vtable at
  `val+0x10` → **24 candidates, zero hits**. The AIBrain is not reachable by
  naive pointer-chasing.

#### Recommended next technique — armed second hook on `0x5930d0`
Reuse the engine's own extraction instead of guessing layout: install an inline
hook on `0x5930d0`. In the outer GTA hook (`hook_gta`), set a one-shot flag
before calling the trampoline; the real GTA then calls `0x5930d0` to extract its
`self`, and the `0x5930d0` hook records `eax` (the AIBrain) when the flag is set,
then disarms. `0x5930d0` is also called for non-AIBrain args, so the flag must be
scoped tightly (set right before, clear right after the trampoline call).
Then `aibrain+0x34 → vtable[6] → tmap` (step 2, already proven).

Alternative: replicate `0x908a70`(LuaStackObject for arg 1) + `0x5930d0` directly
— more inline asm, more crash surface.

### 0x715c60 calling convention (confirmed)
stdcall (`ret 0x4`): 1 explicit arg (pos_vec3_ptr), **implicit `edi` = tmap**.
Reads `tmap->field_0x10` (cell_size) and `tmap->field_0x8` (grid_width).
Returns `cell_index = z_cell * grid_width + x_cell` in eax.
Requires inline asm to set edi before call (see `call_715c60` in faf_worker.c).

## Still unconfirmed

| Function | Note |
|----------|------|
| `lua_settop(L, n)` | Needed for lua_pop; VA not yet found |
| `lua_createtable(L, narr, nrec)` | `lua_newtable` (0x90d110) is the 0,0 case; non-zero hints not found |
| `lua_tointeger(L, idx)` | Use `(int)lua_tonumber(L, idx)` as workaround |
