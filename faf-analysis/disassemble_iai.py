#!/usr/bin/env python3
"""
Targeted disassembly of MohoEngine.dll to validate the hypothesis:
  IAiCommandDispatchImpl takes a CTaskThread* parameter in its constructor,
  and that parameter controls which OS thread AI commands are dispatched to.

Approach:
  1. Locate RTTI string `.?AVIAiCommandDispatchImpl@Moho@@` in .rdata
  2. Find the type_descriptor (string is at +0x08 of a struct)
  3. Find the COL (Complete Object Locator) and vftable for that class
  4. Find references to vftable in .text -> constructor candidates
  5. Disassemble candidates and THREAD_InvokeAsync / THREAD_SetAffinity
"""

import pefile
import struct
import sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32

DLL_PATH = "/home/narfman0/.openclaw/workspace/faf/MohoEngine.dll"
IMAGE_BASE = 0x10000000

# Known export RVAs
RVA_CTASK_CTOR        = 0x86e0
RVA_THREAD_INVOKEASYNC = 0x11ac0
RVA_THREAD_INVOKEWAIT  = 0x11ba0
RVA_THREAD_SETAFFINITY = 0x12100
RVA_GET_CMD_DISPATCH_STAGE = 0x1336c0

TARGET_RTTI = b".?AVIAiCommandDispatchImpl@Moho@@\x00"


def load_pe():
    pe = pefile.PE(DLL_PATH, fast_load=True)
    pe.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT'],
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
    ])
    return pe


def section_info(pe):
    secs = {}
    for s in pe.sections:
        name = s.Name.rstrip(b'\x00').decode(errors='replace')
        secs[name] = {
            'va': IMAGE_BASE + s.VirtualAddress,
            'rva': s.VirtualAddress,
            'vsize': s.Misc_VirtualSize,
            'raw': s.SizeOfRawData,
            'data': s.get_data(),
        }
    return secs


def find_all(haystack, needle, start=0):
    out = []
    i = start
    while True:
        j = haystack.find(needle, i)
        if j < 0:
            break
        out.append(j)
        i = j + 1
    return out


def rva_to_offset(pe, rva):
    return pe.get_offset_from_rva(rva)


def va_to_section(secs, va):
    for n, s in secs.items():
        if s['va'] <= va < s['va'] + s['vsize']:
            return n, s
    return None, None


def read_bytes_at_va(secs, va, n):
    sname, s = va_to_section(secs, va)
    if not s:
        return None
    off = va - s['va']
    return s['data'][off:off+n]


def disasm_at_rva(pe, rva, count=80, label=""):
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True
    off = pe.get_offset_from_rva(rva)
    data = pe.__data__[off:off+1024]
    out = []
    addr = IMAGE_BASE + rva
    n = 0
    for ins in md.disasm(data, addr):
        out.append(f"  0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
        n += 1
        # stop at ret if we've done some work
        if ins.mnemonic in ("ret", "retn") and n > 4:
            out.append(f"  ; --- ret ---")
            break
        if n >= count:
            break
    return out


def find_string_va(secs, target):
    """Search all sections for the RTTI string, return VAs."""
    found = []
    for name, s in secs.items():
        for off in find_all(s['data'], target):
            found.append((name, s['va'] + off))
    return found


def find_dword_refs(secs, target_va, in_sections=None):
    """Find all little-endian DWORD references to target_va."""
    needle = struct.pack('<I', target_va)
    found = []
    for name, s in secs.items():
        if in_sections and name not in in_sections:
            continue
        for off in find_all(s['data'], needle):
            found.append((name, s['va'] + off))
    return found


def main():
    pe = load_pe()
    secs = section_info(pe)
    text = secs.get('.text')
    rdata = secs.get('.rdata')
    data = secs.get('.data')
    print(f"[*] Image base: 0x{IMAGE_BASE:08x}")
    for n, s in secs.items():
        print(f"    {n:<10} VA 0x{s['va']:08x}  vsize 0x{s['vsize']:06x}")

    # ---- 1. find RTTI string ----
    print("\n[*] Searching for RTTI string .?AVIAiCommandDispatchImpl@Moho@@")
    hits = find_string_va(secs, TARGET_RTTI[:-1])  # without null
    for sec, va in hits:
        print(f"    string at VA 0x{va:08x} in {sec}")
    if not hits:
        print("    NOT FOUND. Trying without trailing @")
        hits = find_string_va(secs, b"IAiCommandDispatchImpl")
        for sec, va in hits:
            print(f"    partial at VA 0x{va:08x} in {sec}")
        if not hits:
            print("[!] giving up")
            sys.exit(1)

    string_va = hits[0][1]
    # The MSVC type_descriptor struct: vftable ptr (4) + spare (4) + name[]
    # So type_descriptor VA = string_va - 8
    type_desc_va = string_va - 8
    print(f"[*] Inferred type_descriptor VA: 0x{type_desc_va:08x}")

    # ---- 2. find references to the type_descriptor ----
    print("\n[*] Searching .rdata for pointers to type_descriptor (RTTI COL chain)")
    td_refs = find_dword_refs(secs, type_desc_va, in_sections={'.rdata'})
    for sec, va in td_refs:
        print(f"    ref to type_desc at 0x{va:08x} in {sec}")

    # The type_descriptor is referenced from RTTI_BaseClassDescriptor and from
    # RTTI_CompleteObjectLocator. The COL is referenced from vftable[-1].
    # We need to walk: type_desc -> COL -> vftable.
    # Heuristic: any dword refs to td_refs entries might be COL.
    print("\n[*] Searching for refs to those references (COL candidates)")
    col_candidates = []
    for sec, ref_va in td_refs:
        # COL has structure: signature(0/1), offset, cdOffset, pTypeDescriptor, pClassHierarchyDescriptor[, pSelf]
        # So pTypeDescriptor is at +0x0C from COL start
        col_va = ref_va - 0x0C
        # check signature word at col_va
        sig_bytes = read_bytes_at_va(secs, col_va, 4)
        if sig_bytes:
            sig = struct.unpack('<I', sig_bytes)[0]
            print(f"    candidate COL at 0x{col_va:08x}, signature={sig:#x}")
            col_candidates.append(col_va)

    # ---- 3. find vftables that reference COL ----
    print("\n[*] Searching .rdata for pointers to COL (vftable[-1])")
    vftables = []
    for col_va in col_candidates:
        refs = find_dword_refs(secs, col_va, in_sections={'.rdata'})
        for sec, ref_va in refs:
            # vftable starts at ref_va + 4 (the first virtual method)
            vftable_va = ref_va + 4
            print(f"    COL 0x{col_va:08x} referenced at 0x{ref_va:08x} -> vftable @ 0x{vftable_va:08x}")
            vftables.append(vftable_va)

    # ---- 4. find references in .text to vftable VA ----
    print("\n[*] Searching .text for references to vftable (constructor/init sites)")
    ctor_sites = []
    for vft in vftables:
        refs = find_dword_refs(secs, vft, in_sections={'.text'})
        for sec, ref_va in refs:
            print(f"    vftable 0x{vft:08x} referenced at .text VA 0x{ref_va:08x}")
            ctor_sites.append(ref_va)

    # ---- 5. Disassemble around the constructor sites ----
    md = Cs(CS_ARCH_X86, CS_MODE_32)
    md.detail = True

    results = {
        'type_desc_va': type_desc_va,
        'string_va': string_va,
        'col_candidates': col_candidates,
        'vftables': vftables,
        'ctor_sites': ctor_sites,
        'disasm': {},
    }

    # For each vftable reference site, walk backward in .text to find function start
    # Strategy: vftable is loaded with `mov dword ptr [ecx], offset vftable` -- this is
    # the constructor body. Disassemble backward to find the function prologue.
    print("\n[*] Disassembling around each vftable load site")
    text_va = text['va']
    text_data = text['data']
    for site_va in ctor_sites:
        # Site is the VA of the 4-byte immediate. The mov instruction starts ~4-5 bytes before.
        # Common encoding: C7 01 <vftable>     -> mov dword ptr [ecx], imm32 (6 bytes total)
        # Or: C7 41 XX <vftable>               -> mov dword ptr [ecx+XX], imm32
        # Or: A1/B8 family for absolute moves
        # Scan backward up to 8 bytes for C7
        site_off = site_va - text_va
        instr_start_off = None
        for back in range(2, 9):
            b = text_data[site_off - back]
            if b == 0xC7:
                instr_start_off = site_off - back
                break
            if b == 0xB8:  # mov eax, imm32 (rare for vftable but check)
                instr_start_off = site_off - back
                break
        if instr_start_off is None:
            print(f"  [!] could not find instruction start before site 0x{site_va:08x}")
            continue
        instr_va = text_va + instr_start_off
        print(f"\n  --- Constructor body (vftable stored at instr 0x{instr_va:08x}) ---")
        # Now find function start by walking back to find a prior INT3 (CC) or RET (C3) or aligned 8-byte boundary
        func_start_off = instr_start_off
        for back in range(0, 600):
            o = instr_start_off - back
            if o <= 0:
                break
            # Look for previous int3 padding indicating prior function end
            if text_data[o-1] == 0xCC and text_data[o-2] == 0xCC:
                func_start_off = o
                break
            # Or RET followed by alignment (C3 CC CC...)
            if text_data[o-1] == 0xC3 and text_data[o] == 0xCC:
                func_start_off = o + 1
                # consume CC padding
                while func_start_off < instr_start_off and text_data[func_start_off] == 0xCC:
                    func_start_off += 1
                break
        func_va = text_va + func_start_off
        print(f"  [function start guess: 0x{func_va:08x}]")
        # Disassemble from function start
        out = []
        n = 0
        for ins in md.disasm(text_data[func_start_off:func_start_off+512], func_va):
            mark = "  >>>" if ins.address == instr_va else "     "
            out.append(f"  {mark} 0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
            n += 1
            if ins.mnemonic == "ret" and ins.address >= instr_va:
                break
            if n >= 80:
                break
        for line in out:
            print(line)
        results['disasm'].setdefault('ctors', []).append({
            'site_va': site_va,
            'instr_va': instr_va,
            'func_va': func_va,
            'lines': out,
        })

    # ---- 6. Disassemble THREAD_InvokeAsync ----
    print("\n[*] Disassembling THREAD_InvokeAsync (RVA 0x11ac0)")
    inv = disasm_at_rva(pe, RVA_THREAD_INVOKEASYNC, count=120)
    for ln in inv:
        print(ln)
    results['disasm']['THREAD_InvokeAsync'] = inv

    # ---- 7. Disassemble THREAD_SetAffinity ----
    print("\n[*] Disassembling THREAD_SetAffinity (RVA 0x12100)")
    aff = disasm_at_rva(pe, RVA_THREAD_SETAFFINITY, count=80)
    for ln in aff:
        print(ln)
    results['disasm']['THREAD_SetAffinity'] = aff

    # ---- 8. Disassemble CTask ctor for comparison ----
    print("\n[*] Disassembling CTask ctor (RVA 0x86e0)")
    ctk = disasm_at_rva(pe, RVA_CTASK_CTOR, count=60)
    for ln in ctk:
        print(ln)
    results['disasm']['CTask_ctor'] = ctk

    # ---- 9. Find callers of each ctor candidate ----
    print("\n[*] Finding CALL sites to constructor candidates")
    for entry in results['disasm'].get('ctors', []):
        func_va = entry['func_va']
        # relative call: E8 <rel32> ;  abs target = caller_va + 5 + rel32
        # iterate over .text bytes looking for E8 with matching target
        callers = []
        for off in range(0, len(text_data) - 5):
            if text_data[off] == 0xE8:
                rel = struct.unpack('<i', text_data[off+1:off+5])[0]
                call_va = text_va + off
                target = call_va + 5 + rel
                if target == func_va:
                    callers.append(call_va)
        print(f"  func 0x{func_va:08x}: {len(callers)} callers")
        for c in callers[:20]:
            print(f"    call from 0x{c:08x}")
            # disassemble 6 instructions before the call to grab context
            # walk back roughly 30 bytes
            c_off = c - text_va
            start = max(0, c_off - 40)
            ctx = []
            for ins in md.disasm(text_data[start:c_off+5], text_va + start):
                ctx.append(f"      0x{ins.address:08x}  {ins.mnemonic:<7} {ins.op_str}")
            for ln in ctx[-8:]:
                print(ln)
        entry['callers'] = callers

    # Save results pickle for the report writer
    import json
    out_path = "/home/narfman0/.openclaw/workspace/faf-analysis/iai_results.json"
    # Convert ints to hex strings for readability
    def conv(o):
        if isinstance(o, int):
            return f"0x{o:08x}"
        if isinstance(o, dict):
            return {k: conv(v) for k, v in o.items()}
        if isinstance(o, list):
            return [conv(x) for x in o]
        return o
    with open(out_path, 'w') as f:
        json.dump(conv(results), f, indent=2)
    print(f"\n[*] wrote {out_path}")


if __name__ == "__main__":
    main()
