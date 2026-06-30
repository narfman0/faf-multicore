#!/usr/bin/env python3
"""Final pass:
  - Disassemble sub 0x10008bc0  (the per-task dispatch invoked inside CTaskStage::DispatchAll)
  - Disassemble sub 0x10008ab0  (cleanup branch for -1 return)
  - Find how a CTask enters a CTaskStage's list. Look at  WIN_GetBeforeEventsStage usage
  - Find what CTaskThread+0x10 list is FOR if it's not the dispatch list. Look at CTask::~CTask
    (0x10008730) which must remove from it.
  - Search for any "Run" or "Execute" virtual on CTaskStage by looking at vftable 0x1071de50
    (CTaskEvent vtbl). Also CTask vtbl 0x1071dfb0.
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

def disasm_va(va, count=180, stop_on_ret=True):
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
                if base + i + 5 + rel == target_va:
                    out.append(base + i)
    return out

print("=" * 70)
print("Per-task dispatch invoked in DispatchAll: 0x10008bc0")
print("=" * 70)
for ln in disasm_va(0x10008bc0, 200, stop_on_ret=False):
    print(ln)
    if 'ret ' in ln or 'ret\n' in ln or ln.endswith('  ret'): break

print()
print("=" * 70)
print("Cleanup branch when task returns -1: 0x10008ab0")
print("=" * 70)
for ln in disasm_va(0x10008ab0, 120, stop_on_ret=False):
    print(ln)
    if ln.endswith('  ret'): break

print()
print("=" * 70)
print("CTask::~CTask (0x10008730) - removal from CTaskThread+0x10 list")
print("=" * 70)
for ln in disasm_va(0x10008730, 100):
    print(ln)

print()
print("=" * 70)
print("CTask vftable @ 0x1071dfb0  - virtuals")
print("=" * 70)
raw, _ = va_data(0x1071dfb0, 0x40)
if raw:
    for i in range(16):
        v = struct.unpack('<I', raw[i*4:i*4+4])[0]
        if 0x10001000 <= v < 0x10600000:
            print(f"  vtbl[{i:2d}] = 0x{v:08x}")
        else:
            print(f"  vtbl[{i:2d}] = 0x{v:08x}  (stop)")
            break

print()
print("=" * 70)
print("CTaskEvent vftable @ 0x1071de50 - virtuals")
print("=" * 70)
raw, _ = va_data(0x1071de50, 0x40)
if raw:
    for i in range(16):
        v = struct.unpack('<I', raw[i*4:i*4+4])[0]
        if 0x10001000 <= v < 0x10600000:
            print(f"  vtbl[{i:2d}] = 0x{v:08x}")
        else:
            print(f"  vtbl[{i:2d}] = 0x{v:08x}  (stop)")
            break

# To find what calls 0x10008bc0 from outside CTaskStage::DispatchAll:
print()
print("=" * 70)
print("Callers of 0x10008bc0 (CTask dispatch)")
print("=" * 70)
for c in find_call_sites_to(0x10008bc0)[:30]:
    print(f"  0x{c:08x}")
