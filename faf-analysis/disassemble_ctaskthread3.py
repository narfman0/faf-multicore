#!/usr/bin/env python3
"""Third pass:
  - Disassemble each Sim::Get*Stage getter: 0x1336a0, 0x1336b0, 0x1336c0  and the WIN_ versions 0xe1640, 0xe16b0
  - Disassemble CTaskStage RTTI structures: find vftable, list virtuals to see Tick/Run.
  - Disassemble CTask helpers: TaskGetThread (0x59f0), TaskRunningNow (0x5a00), TaskResume (0x8830), TaskInterruptSubtasks (0x87f0)
  - Disassemble EventSignal (0x5b20) and EventSetSignaled (0x6090) - figures out what waking up looks like
  - Find xrefs to 'CTaskStage' RTTI - locate vftable
  - Find call sites to EventWait (caller @ 0x100bc656 - disassemble surrounding to see if it actually blocks)
  - Find the CTaskThread Run loop - search for callers of EventWait that have a 'while' loop walking a task list
"""

import pefile, struct, re
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

DLL = "/home/narfman0/.openclaw/workspace/faf/MohoEngine.dll"
IMAGE_BASE = 0x10000000

pe = pefile.PE(DLL, fast_load=True)
secs = {}
for s in pe.sections:
    n = s.Name.rstrip(b'\x00').decode(errors='replace')
    secs[n] = (IMAGE_BASE + s.VirtualAddress, s.Misc_VirtualSize, s.get_data())

def va_data(va, n=4):
    for name, (base, sz, d) in secs.items():
        if base <= va < base + sz:
            off = va - base
            return d[off:off+n], name
    return None, None

def disasm_va(va, count=120, stop_on_ret=True):
    raw, sec = va_data(va, 4096)
    if raw is None:
        return ["<not in any section>"]
    md2 = Cs(CS_ARCH_X86, CS_MODE_32)
    out = []
    n = 0
    for ins in md2.disasm(raw, va):
        out.append(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
        n += 1
        if stop_on_ret and ins.mnemonic == "ret":
            break
        if n >= count:
            break
    return out

def find_xrefs_to(target_va, sections=('.text','.rdata','.data')):
    needle = struct.pack('<I', target_va)
    out = []
    for name, (base, sz, d) in secs.items():
        if name not in sections: continue
        i = 0
        while True:
            j = d.find(needle, i)
            if j < 0: break
            out.append((name, base + j))
            i = j + 1
    return out

def find_call_sites_to(target_va):
    out = []
    for name, (base, sz, d) in secs.items():
        if name != '.text': continue
        for i in range(len(d) - 5):
            if d[i] == 0xE8:
                rel = struct.unpack('<i', d[i+1:i+5])[0]
                call_va = base + i
                tgt = call_va + 5 + rel
                if tgt == target_va:
                    out.append(call_va)
    return out

print("=" * 70)
print("Sim::Get*Stage accessors")
print("=" * 70)
for va, name in [(0x101336a0, "GetMotionUpdateStage"),
                  (0x101336b0, "GetScriptStage"),
                  (0x101336c0, "GetCommandDispatchStage"),
                  (0x100e1640, "WIN_GetBeforeEventsStage"),
                  (0x100e16b0, "WIN_GetBeforeWaitStage")]:
    print(f"\n-- {name} @ 0x{va:08x} --")
    for ln in disasm_va(va, 20):
        print(ln)

print()
print("=" * 70)
print("CTask helpers")
print("=" * 70)
for va, name in [(0x100059f0, "TaskGetThread"),
                  (0x10005a00, "TaskRunningNow"),
                  (0x10008830, "TaskResume"),
                  (0x100087f0, "TaskInterruptSubtasks")]:
    print(f"\n-- {name} @ 0x{va:08x} --")
    for ln in disasm_va(va, 80):
        print(ln)

print()
print("=" * 70)
print("CTaskEvent helpers")
print("=" * 70)
for va, name in [(0x10005b10, "EventIsSignaled"),
                  (0x10005b20, "EventSignal"),
                  (0x10005b30, "EventReset"),
                  (0x10006090, "EventSetSignaled"),
                  (0x10005f90, "CTaskEvent::ctor"),
                  (0x10005fd0, "CTaskEvent::dtor")]:
    print(f"\n-- {name} @ 0x{va:08x} --")
    for ln in disasm_va(va, 80):
        print(ln)

print()
print("=" * 70)
print("EventWait caller @ 0x100bc656 - surrounding code")
print("=" * 70)
for ln in disasm_va(0x100bc580, 150, stop_on_ret=False):
    print(ln)

print()
print("=" * 70)
print("CTaskStage vftable hunt -- callers of WIN_GetBeforeEventsStage")
print("=" * 70)
callers = find_call_sites_to(0x100e1640)
print(f"WIN_GetBeforeEventsStage callers ({len(callers)}):")
for c in callers[:20]:
    print(f"  0x{c:08x}")
callers = find_call_sites_to(0x100e16b0)
print(f"\nWIN_GetBeforeWaitStage callers ({len(callers)}):")
for c in callers[:20]:
    print(f"  0x{c:08x}")
callers = find_call_sites_to(0x101336c0)
print(f"\nGetCommandDispatchStage callers ({len(callers)}):")
for c in callers[:20]:
    print(f"  0x{c:08x}")

print()
print("=" * 70)
print("CTaskStage static functions - WIN_GetBeforeEventsStage body")
print("=" * 70)
# It probably returns &globalStage
for ln in disasm_va(0x100e1640, 30):
    print(ln)
print()
for ln in disasm_va(0x100e16b0, 30):
    print(ln)

print()
print("=" * 70)
print("Disassemble around first WIN_GetBeforeEventsStage caller - that's likely the worker loop")
print("=" * 70)
callers = find_call_sites_to(0x100e1640)
for c in callers[:8]:
    print(f"\n--- caller @ 0x{c:08x}, prior 200 / next 50 ---")
    raw, _ = va_data(c - 200, 280)
    if not raw: continue
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    for ins in md.disasm(raw, c - 200):
        print(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
        if ins.address > c + 60: break
