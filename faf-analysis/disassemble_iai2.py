#!/usr/bin/env python3
"""Follow-up: deeper context around the IAiCommandDispatchImpl ctor at 0x10189210.

Key question: is arg2 (CTaskThread*) stored as a member, and where is it used?
We trace:
  - the ctor 0x10189210 body more carefully (look at sub-call 0x10188ff0 = likely CTask base ctor)
  - the wider context of caller 0x10285b3c (looks like SimArmy/AIBrain init)
  - search for nearby strings around those callers
"""

import pefile, struct, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

DLL = "/home/narfman0/.openclaw/workspace/faf/MohoEngine.dll"
IMAGE_BASE = 0x10000000

pe = pefile.PE(DLL, fast_load=True)
pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']])

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

def disasm_va(va, count=80, stop_on_ret=True):
    raw, sec = va_data(va, 2048)
    if raw is None:
        return ["<not in any section>"]
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    out = []
    n = 0
    for ins in md.disasm(raw, va):
        out.append(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
        n += 1
        if stop_on_ret and ins.mnemonic == "ret":
            break
        if n >= count:
            break
    return out

def find_string_va(needle_bytes):
    out = []
    for name, (base, sz, d) in secs.items():
        i = 0
        while True:
            j = d.find(needle_bytes, i)
            if j < 0: break
            out.append((name, base + j))
            i = j + 1
    return out

def find_xrefs(target_va, sections=('.text',)):
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

print("=" * 70)
print("CTOR 0x10189210 — ARG TRACE")
print("=" * 70)
print("Disassembling first 60 instructions:")
for ln in disasm_va(0x10189210, 60, stop_on_ret=False):
    print(ln)

print()
print("Disassembling sub-call 0x10188ff0 (called inside ctor):")
for ln in disasm_va(0x10188ff0, 80):
    print(ln)

print()
print("Disassembling sub-call 0x10009310 (called near end of ctor):")
for ln in disasm_va(0x10009310, 40):
    print(ln)

print()
print("=" * 70)
print("CALLER CONTEXT 0x10285b3c (outside the IAiCommandDispatchImpl module)")
print("=" * 70)
# Disassemble ~200 bytes before the call
for ln in disasm_va(0x10285a80, 80, stop_on_ret=False):
    print(ln)

print()
print("=" * 70)
print("CALLER CONTEXT 0x1018992c (inside the same code module)")
print("=" * 70)
for ln in disasm_va(0x101898a0, 80, stop_on_ret=False):
    print(ln)

print()
print("=" * 70)
print("SEARCH NEARBY STRINGS")
print("=" * 70)
# Get all near-string refs in .text around the call sites
# For each LEA / PUSH offset, look up if it resolves to a string in .rdata/.data
def is_printable_string(va, maxlen=80):
    raw, _ = va_data(va, maxlen)
    if not raw: return None
    end = raw.find(b'\x00')
    if end < 4 or end > maxlen-1: return None
    try:
        s = raw[:end].decode('ascii')
    except UnicodeDecodeError:
        return None
    if all(32 <= ord(c) < 127 for c in s):
        return s
    return None

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

def scan_strings_around(start, end):
    raw, _ = va_data(start, end - start)
    if raw is None: return
    for ins in md.disasm(raw, start):
        for op in ins.operands:
            if op.type == 2:  # IMM
                v = op.imm
                s = is_printable_string(v)
                if s:
                    print(f"  0x{ins.address:08x}: {ins.mnemonic} {ins.op_str}   ; -> {s!r}")

print("\n-- around caller 0x10285b3c --")
scan_strings_around(0x10285a00, 0x10285c00)
print("\n-- around caller 0x1018992c --")
scan_strings_around(0x101898a0, 0x10189a40)
print("\n-- around ctor 0x10189210 --")
scan_strings_around(0x10189210, 0x101892e8)

# ---- Look at the vftable contents to count virtual methods ----
print()
print("=" * 70)
print("VFTABLE @ 0x1073a668 (most-derived IAiCommandDispatchImpl)")
print("=" * 70)
raw, _ = va_data(0x1073a668, 80)
for i in range(20):
    p = struct.unpack('<I', raw[i*4:i*4+4])[0]
    if 0x10001000 <= p < 0x10600000:
        print(f"  slot {i:2d}: 0x{p:08x}  (in .text)")
    else:
        print(f"  slot {i:2d}: 0x{p:08x}")
        break

# Disassemble first few vftable entries to see what they do
print("\n-- vftable[0] = first virtual method --")
raw, _ = va_data(0x1073a668, 4)
vm0 = struct.unpack('<I', raw)[0]
for ln in disasm_va(vm0, 40):
    print(ln)
