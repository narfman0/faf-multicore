#!/usr/bin/env python3
"""Fourth pass - the actual dispatch function.
  - 0x10009390 = CTaskStage::DispatchAll-equivalent (called from main loop with a CTaskStage*)
  - Trace it to see how it walks tasks and whether it respects CTaskThread*
  - Identify CTaskThread::Run if it exists as a separate entry
  - Disassemble related stage runner functions
  - Find xrefs to 0x10009390 to see other callers
"""

import pefile, struct
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

def disasm_va(va, count=200, stop_on_ret=True):
    raw, sec = va_data(va, 8192)
    if raw is None: return ["<not in section>"]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    out = []
    n = 0
    for ins in md.disasm(raw, va):
        out.append(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
        n += 1
        if stop_on_ret and ins.mnemonic == "ret": break
        if n >= count: break
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
print("CTaskStage::DispatchAll @ 0x10009390  (called from main loop with ecx=stage)")
print("=" * 70)
for ln in disasm_va(0x10009390, 250, stop_on_ret=False):
    print(ln)

print()
print("=" * 70)
print("Callers of 0x10009390 - who else runs CTaskStages?")
print("=" * 70)
callers = find_call_sites_to(0x10009390)
print(f"{len(callers)} call sites")
for c in callers[:30]:
    print(f"  0x{c:08x}")

print()
print("=" * 70)
print("Sub 0x100091e0 - called by WIN_GetBeforeEventsStage (CTaskStage::ctor likely)")
print("=" * 70)
for ln in disasm_va(0x100091e0, 80):
    print(ln)

print()
print("=" * 70)
print("Sub 0x10009310 - called by IAiCommandDispatchImpl::ctor (Listener::Register most likely)")
print("=" * 70)
for ln in disasm_va(0x10009310, 80):
    print(ln)

# What does CTaskStage layout look like?
# WIN_GetBeforeEventsStage initializes via call 0x100091e0(0x10a18958)
# WIN_GetBeforeWaitStage    initializes via call 0x100091e0(0x10a18940)
# So CTaskStage stride is 0x18? (0x10a18958 - 0x10a18940 = 0x18). And after CTaskStage::ctor, an at_exit handler runs.

print()
print("=" * 70)
print("Look at the actual CTaskStage objects' data section content")
print("=" * 70)
for va in [0x10a18940, 0x10a18958]:
    print(f"@ 0x{va:08x}:")
    raw, _ = va_data(va, 0x18)
    if raw:
        for i in range(6):
            v = struct.unpack('<I', raw[i*4:i*4+4])[0]
            print(f"   [+0x{i*4:x}] = 0x{v:08x}")
