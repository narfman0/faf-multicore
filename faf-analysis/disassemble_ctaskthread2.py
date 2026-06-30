#!/usr/bin/env python3
"""Follow-up:
  - Disassemble around the 'Prefetcher thread.' xref to find the prefetcher proc
    (a simple CTaskThread user) and identify CTaskThread::Run
  - Read full mangled symbol strings near CTaskThread occurrences
  - Disassemble around 0x10006120 area: looks like EventWait calls operator new() to
    queue a waiter then... we need to see if it blocks. Look at sub_10005a50 (called inside).
  - Look up sub-calls inside EventWait: 0x10005a50 (called at 0x10006177)
  - Investigate the Sim object structure: GetCommandDispatchStage returns this+0x968.
    Find what owns the CTaskStage and its dispatch.
"""

import pefile, struct, sys
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

def find_xrefs_to(target_va, sections=('.text',)):
    needle = struct.pack('<I', target_va)
    out = []
    for name, (base, sz, d) in secs.items():
        if name not in sections: continue
        i = 0
        while True:
            j = d.find(needle, i)
            if j < 0: break
            out.append(base + j)
            i = j + 1
    return out

def read_cstr(va, maxlen=300):
    raw, _ = va_data(va, maxlen)
    if not raw: return None
    end = raw.find(b'\x00')
    if end < 0: end = maxlen
    try:
        return raw[:end].decode('ascii')
    except Exception:
        return None

def find_function_start(call_va, max_back=0x2000):
    """Walk backwards from call_va looking for a likely function prologue."""
    raw, _ = va_data(call_va - max_back, max_back + 64)
    if not raw: return None
    # Heuristic: find 'push ebp; mov ebp, esp' (55 8B EC) or 'push -1 / push <handler>' SEH prologue
    base = call_va - max_back
    # Scan backwards for 0xCC int3 padding, function usually starts right after
    for back in range(64, max_back, 1):
        addr = call_va - back
        off = addr - base
        if off < 4: continue
        # check for int3 padding before
        if raw[off-1] == 0xCC and raw[off] in (0x55, 0x6A, 0x53, 0x56, 0x57, 0x83, 0x81, 0x8B):
            return addr
    return None

print("=" * 70)
print("1. Prefetcher thread xref - find function entry")
print("=" * 70)
xref = 0x100a2e95
print(f"xref site: 0x{xref:08x}")
# print prior 80 instructions to find function start
raw, _ = va_data(xref - 400, 600)
md2 = Cs(CS_ARCH_X86, CS_MODE_32)
for ins in md2.disasm(raw, xref - 400):
    print(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
    if ins.address > xref + 200: break

print()
print("=" * 70)
print("2. Find function start nearby 0x100a2e95 (heuristic)")
print("=" * 70)
fs = find_function_start(xref, max_back=0x600)
print(f"  heuristic function start: 0x{fs:08x}" if fs else "  not found")
if fs:
    print("  full function:")
    for ln in disasm_va(fs, 300, stop_on_ret=False):
        print(ln)
        if 'ret' in ln: break

print()
print("=" * 70)
print("3. Full mangled symbol scan: print all strings containing 'CTaskThread'")
print("=" * 70)
# Symbols are stored as C strings -- find all
import re
for name in ('.rdata', '.data'):
    if name not in secs: continue
    base, sz, d = secs[name]
    # Find every '?' that begins a mangled symbol
    for m in re.finditer(rb'\?[A-Za-z0-9_@?$]+CTaskThread[A-Za-z0-9_@?$]*', d):
        va = base + m.start()
        s = read_cstr(va, 300)
        if s and len(s) < 250:
            print(f"  0x{va:08x}  {s}")

print()
print("=" * 70)
print("4. EventWait sub-call 0x10005a50 (waiter constructor?)")
print("=" * 70)
for ln in disasm_va(0x10005a50, 80):
    print(ln)

print()
print("=" * 70)
print("5. EventWait body second time -- with calls resolved")
print("=" * 70)
md3 = Cs(CS_ARCH_X86, CS_MODE_32)
md3.detail = True
raw, _ = va_data(0x10006120, 200)
for ins in md3.disasm(raw, 0x10006120):
    line = f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}"
    if ins.mnemonic == 'call':
        for op in ins.operands:
            if op.type == 2:
                tgt = op.imm
                line += f"    ; -> 0x{tgt:08x}"
    print(line)
    if ins.mnemonic == 'ret': break

print()
print("=" * 70)
print("6. Look for CTaskThread::Run / CTaskThread::Loop / mangled symbol RVAs")
print("=" * 70)
# Pull the export table for any Moho exports involving CTaskThread/CTaskStage
pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']])
if hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
    for exp in pe.DIRECTORY_ENTRY_EXPORT.symbols:
        nm = exp.name
        if nm is None: continue
        try:
            s = nm.decode('ascii')
        except Exception: continue
        if 'CTaskThread' in s or 'CTaskStage' in s or 'CTaskEvent' in s or 'CTask@' in s:
            va = IMAGE_BASE + exp.address
            print(f"  0x{va:08x}  {s}")

print()
print("=" * 70)
print("7. EventWait nested calls: who calls 0x10006120?")
print("=" * 70)
# Look for E8 calls targeting 0x10006120 by byte scan
target = 0x10006120
for name, (base, sz, d) in secs.items():
    if name != '.text': continue
    for i in range(len(d) - 5):
        if d[i] == 0xE8:
            rel = struct.unpack('<i', d[i+1:i+5])[0]
            call_va = base + i
            tgt = call_va + 5 + rel
            if tgt == target:
                print(f"  caller @ 0x{call_va:08x}")
