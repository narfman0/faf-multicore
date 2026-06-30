#!/usr/bin/env python3
"""CTaskThread worker loop / CTaskStage / EventWait investigation.

Goals:
  1. Disassemble CTaskEvent::EventWait at RVA 0x6120  (the sync barrier)
  2. Disassemble ?GetCommandDispatchStage@Sim@Moho@@QAEAAVCTaskStage@2@XZ @ 0x1336c0
     and trace what CTaskStage object it returns.
  3. Find the CTaskThread worker loop:
       - Walk xrefs to memory accesses of [reg+0x10] near "Prefetcher thread." string ref
       - Look for exported CTaskThread methods
       - Find function that loads the head and walks ->next
  4. Find / disassemble CTaskStage::Tick or similar that iterates its CTask list.
  5. Identify the NULL-CTaskThread inline dispatch path -- search for callers of
     IAiCommandDispatchImpl::vftable[*] virtual that runs the AI command.
"""

import pefile, struct, sys, re
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

md = Cs(CS_ARCH_X86, CS_MODE_32)
md.detail = True

def disasm_va(va, count=120, stop_on_ret=True, stop_on_jmp_far=False):
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

def find_string_va(needle):
    if isinstance(needle, str):
        needle = needle.encode()
    out = []
    for name, (base, sz, d) in secs.items():
        if name in ('.text',): continue
        i = 0
        while True:
            j = d.find(needle, i)
            if j < 0: break
            out.append((name, base + j))
            i = j + 1
    return out

def find_call_sites_to(target_va):
    """Find E8 (call rel32) instructions whose target is target_va."""
    out = []
    for name, (base, sz, d) in secs.items():
        if name != '.text': continue
        # scan all positions; capstone-disasm is too slow over .text -- use byte scan for E8
        for i in range(len(d) - 5):
            if d[i] == 0xE8:
                rel = struct.unpack('<i', d[i+1:i+5])[0]
                call_va = base + i
                tgt = call_va + 5 + rel
                if tgt == target_va:
                    out.append(call_va)
    return out

print("=" * 70)
print("1. CTaskEvent::EventWait @ RVA 0x6120")
print("=" * 70)
for ln in disasm_va(0x10006120, 200, stop_on_ret=False):
    print(ln)

print()
print("=" * 70)
print("2. ?GetCommandDispatchStage @ RVA 0x1336c0")
print("=" * 70)
for ln in disasm_va(0x101336c0, 80):
    print(ln)

print()
print("=" * 70)
print("3. 'Prefetcher thread.' string xrefs")
print("=" * 70)
for sec, va in find_string_va("Prefetcher thread."):
    print(f"  string in {sec} @ 0x{va:08x}")
    xrefs = find_xrefs_to(va)
    for x in xrefs:
        print(f"    xref @ 0x{x:08x}")

print()
print("=" * 70)
print("4. Search for other thread-name strings (CTaskThread is usually named on creation)")
print("=" * 70)
for needle in ["thread.", "Worker", "TaskThread", "Sim thread", "AI thread", "Dispatcher"]:
    for sec, va in find_string_va(needle):
        # bound the print
        raw, _ = va_data(va, 64)
        if raw:
            s = raw.split(b'\x00')[0]
            try:
                s = s.decode('ascii')
            except Exception:
                continue
            if len(s) < 4 or len(s) > 60: continue
            xrefs = find_xrefs_to(va)
            if xrefs:
                print(f"  {s!r} @ 0x{va:08x} in {sec}  xrefs={[hex(x) for x in xrefs]}")

print()
print("=" * 70)
print("5. CTask::CTask call sites - find what calls CTask base ctor 0x86e0 / CCommandTask base ctor 0x10188ff0")
print("    (to find the CTaskThread worker loop indirectly)")
print("=" * 70)
print("CTask::CTask (0x100086e0) callers:")
callers = find_call_sites_to(0x100086e0)
print(f"  {len(callers)} call sites")
for c in callers[:30]:
    print(f"    0x{c:08x}")

print()
print("=" * 70)
print("6. CTaskThread vftable hunt - search RTTI for '.?AVCTaskThread@Moho@@'")
print("=" * 70)
for sec, va in find_string_va(".?AVCTaskThread@Moho@@"):
    print(f"  RTTI name @ 0x{va:08x} (sec={sec})")
    td_va = va - 8  # type descriptor starts 8 bytes before the string
    print(f"  TD VA candidate: 0x{td_va:08x}")
    td_xrefs = find_xrefs_to(td_va, sections=('.rdata','.data'))
    print(f"  TD refs: {[hex(x) for x in td_xrefs]}")

print()
print("=" * 70)
print("7. CTaskStage RTTI search")
print("=" * 70)
for sec, va in find_string_va(".?AVCTaskStage@Moho@@"):
    print(f"  RTTI name @ 0x{va:08x} (sec={sec})")
    td_va = va - 8
    td_xrefs = find_xrefs_to(td_va, sections=('.rdata','.data'))
    print(f"  TD refs: {[hex(x) for x in td_xrefs]}")
    # for each TD ref, look ~4 dwords ahead to find COL pattern
    for tdx in td_xrefs:
        # the COL is typically the structure containing tdx at offset 0xc
        col_candidate = tdx - 0xc
        # find xrefs to col_candidate -> vftable[-1]
        col_xrefs = find_xrefs_to(col_candidate, sections=('.rdata',))
        for cx in col_xrefs:
            vftable_va = cx + 4
            print(f"    candidate vftable @ 0x{vftable_va:08x}")
            raw, _ = va_data(vftable_va, 80)
            if raw:
                for i in range(16):
                    p = struct.unpack('<I', raw[i*4:i*4+4])[0]
                    if 0x10001000 <= p < 0x10600000:
                        print(f"      slot {i:2d}: 0x{p:08x}")
                    else:
                        break

print()
print("=" * 70)
print("8. Walk to find CTaskThread worker loop")
print("=" * 70)
# Look for the typical pattern of CTaskThread::Run:
#   - loads [this+0x10] (task list head)
#   - has a wait/sleep/wakeup
# We grep for common mangled CTaskThread symbols.
for sec, va in find_string_va("?Run@CTaskThread"):
    print(f"  exported-ish symbol @ 0x{va:08x}: ")
    raw, _ = va_data(va, 200)
    if raw:
        s = raw.split(b'\x00')[0].decode('ascii', errors='replace')
        print(f"    {s}")
for sec, va in find_string_va("CTaskThread@"):
    raw, _ = va_data(va, 200)
    if not raw: continue
    s = raw.split(b'\x00')[0].decode('ascii', errors='replace')
    if 8 < len(s) < 150 and 'CTaskThread' in s:
        print(f"  symbol @ 0x{va:08x}: {s}")
