#!/usr/bin/env python3
"""
Static analysis of MohoEngine.dll for Supreme Commander: Forged Alliance.
Extracts PE metadata, imports, and keyword-filtered strings.
"""

import pefile
import subprocess
import sys
import re
from collections import defaultdict

DLL_PATH = "/home/narfman0/.openclaw/workspace/faf/MohoEngine.dll"

KEYWORDS = [
    "thread", "Thread", "worker", "Worker", "AIBrain", "aibrain", "brain", "Brain",
    "Dispatch", "dispatch", "queue", "Queue", "Sim", "sim_", "SIM", "mutex", "Mutex",
    "sync", "Sync", "TaskMan", "taskman", "sched", "Sched", "beginthreadex",
    "CreateThread", "AffinityMask", "ForkThread", "MohoEngine", "GPG_", "beat", "Beat",
    "tick", "Tick", "CTaskThread", "affinity", "Affinity", "QueueUserAPC",
    "render", "Render", "audio", "Audio", "sound", "Sound", "vsync", "VSync",
    "RTTI", "AVCTask", "AVPaused",
]

def pe_metadata(pe):
    print("=" * 70)
    print("PE METADATA")
    print("=" * 70)
    print(f"Machine: {hex(pe.FILE_HEADER.Machine)}")
    print(f"TimeDateStamp: {hex(pe.FILE_HEADER.TimeDateStamp)}")
    print(f"Characteristics: {hex(pe.FILE_HEADER.Characteristics)}")

    print("\n--- Sections ---")
    print(f"{'Name':<12} {'VirtAddr':<12} {'VirtSize':<12} {'RawSize':<12} {'Chars'}")
    for s in pe.sections:
        name = s.Name.decode(errors='replace').rstrip('\x00')
        print(f"{name:<12} {hex(s.VirtualAddress):<12} {hex(s.Misc_VirtualSize):<12} {hex(s.SizeOfRawData):<12} {hex(s.Characteristics)}")

def pe_imports(pe):
    print("\n" + "=" * 70)
    print("IMPORTS")
    print("=" * 70)

    if not hasattr(pe, 'DIRECTORY_ENTRY_IMPORT'):
        print("No import directory found.")
        return {}

    all_imports = {}
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll_name = entry.dll.decode(errors='replace')
        funcs = []
        for imp in entry.imports:
            if imp.name:
                funcs.append(imp.name.decode(errors='replace'))
            else:
                funcs.append(f"ordinal_{imp.ordinal}")
        all_imports[dll_name] = funcs

    for dll_name, funcs in sorted(all_imports.items()):
        print(f"\n  [{dll_name}]")
        for f in sorted(funcs):
            print(f"    {f}")

    return all_imports

def thread_related_imports(all_imports):
    print("\n" + "=" * 70)
    print("THREAD-RELATED IMPORTS SUMMARY")
    print("=" * 70)

    thread_keywords = [
        "thread", "Thread", "affinity", "Affinity", "Priority", "priority",
        "Mutex", "mutex", "Event", "Semaphore", "Critical", "APC", "Queue",
        "Suspend", "Resume", "Exit", "Create", "Open", "Sleep"
    ]

    for dll_name, funcs in sorted(all_imports.items()):
        matching = [f for f in funcs if any(k.lower() in f.lower() for k in thread_keywords)]
        if matching:
            print(f"\n  [{dll_name}]")
            for f in sorted(matching):
                print(f"    {f}")

def extract_strings():
    print("\n" + "=" * 70)
    print("KEYWORD-FILTERED STRINGS")
    print("=" * 70)

    result = subprocess.run(
        ["strings", "-a", "-n", "6", DLL_PATH],
        capture_output=True, text=True, errors='replace'
    )

    all_strings = result.stdout.splitlines()
    print(f"Total strings extracted: {len(all_strings)}")

    matched = []
    for s in all_strings:
        if any(k in s for k in KEYWORDS):
            matched.append(s)

    print(f"Keyword-matching strings: {len(matched)}")
    print()

    # Group by theme
    themes = {
        "Thread/Task": ["thread", "Thread", "CTaskThread", "beginthreadex", "CreateThread", "AVCTask", "AVPaused", "worker", "Worker"],
        "Affinity/Priority": ["affinity", "Affinity", "AffinityMask"],
        "AI/Brain": ["AIBrain", "aibrain", "brain", "Brain"],
        "Dispatch/Queue": ["Dispatch", "dispatch", "queue", "Queue", "QueueUserAPC"],
        "Sim/Beat/Tick": ["Sim", "sim_", "SIM", "beat", "Beat", "tick", "Tick"],
        "Sync/Mutex": ["mutex", "Mutex", "sync", "Sync"],
        "Scheduler": ["TaskMan", "taskman", "sched", "Sched"],
        "ForkThread/Lua": ["ForkThread"],
        "MohoEngine/GPG": ["MohoEngine", "GPG_"],
        "Render/Audio": ["render", "Render", "audio", "Audio", "sound", "Sound", "vsync", "VSync"],
    }

    printed = set()
    for theme, keys in themes.items():
        group = [s for s in matched if any(k in s for k in keys) and s not in printed]
        if group:
            print(f"\n--- {theme} ---")
            for s in group:
                print(f"  {s!r}")
                printed.add(s)

    # Remaining
    leftover = [s for s in matched if s not in printed]
    if leftover:
        print(f"\n--- Other matching strings ---")
        for s in leftover:
            print(f"  {s!r}")

    return matched, all_strings

def extract_strings_with_offset():
    """Try to get strings with their file offsets using strings -t x"""
    result = subprocess.run(
        ["strings", "-a", "-n", "6", "-t", "x", DLL_PATH],
        capture_output=True, text=True, errors='replace'
    )

    all_strings = result.stdout.splitlines()
    matched = []
    for line in all_strings:
        parts = line.split(None, 1)
        if len(parts) == 2:
            offset, s = parts
            if any(k in s for k in KEYWORDS):
                matched.append((offset, s))
    return matched

def rtti_analysis(all_strings):
    print("\n" + "=" * 70)
    print("RTTI / CLASS NAME STRINGS")
    print("=" * 70)

    rtti = [s for s in all_strings if s.startswith('.?AV') or s.startswith('.?AU')]
    if rtti:
        for s in sorted(rtti):
            print(f"  {s}")
    else:
        print("  No RTTI strings found (stripped or in separate section)")

def exports_analysis(pe):
    print("\n" + "=" * 70)
    print("EXPORTS")
    print("=" * 70)

    if not hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
        print("  No export directory found.")
        return

    exports = pe.DIRECTORY_ENTRY_EXPORT
    print(f"  DLL Name: {exports.name.decode(errors='replace') if exports.name else 'N/A'}")
    print(f"  Number of exports: {len(exports.symbols)}")
    print()

    for exp in exports.symbols:
        if exp.name:
            print(f"  [{hex(exp.address)}] {exp.name.decode(errors='replace')}")
        else:
            print(f"  [{hex(exp.address)}] ordinal_{exp.ordinal}")

def main():
    print(f"Analyzing: {DLL_PATH}\n")

    pe = pefile.PE(DLL_PATH)

    pe_metadata(pe)
    all_imports = pe_imports(pe)
    thread_related_imports(all_imports)
    exports_analysis(pe)

    matched_strings, all_strings = extract_strings()
    rtti_analysis(all_strings)

    print("\n" + "=" * 70)
    print("STRINGS WITH FILE OFFSETS (keyword matches)")
    print("=" * 70)
    offset_matches = extract_strings_with_offset()
    for offset, s in offset_matches:
        print(f"  0x{offset:<10} {s!r}")

    pe.close()

if __name__ == "__main__":
    main()
