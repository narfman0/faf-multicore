#!/usr/bin/env python3
"""
inject_import.py — Add faf_profiler.dll as a PE import to SupremeCommander.exe

Usage:
    python3 inject_import.py <path/to/SupremeCommander.exe>

Creates SupremeCommander_patched.exe in the same directory.
The patched binary imports faf_profiler_init() from faf_profiler.dll,
causing Windows/Wine to load faf_profiler.dll at startup.
"""

import sys
import shutil
import os

try:
    import lief
except ImportError:
    print("ERROR: pip install lief")
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <SupremeCommander.exe>")
        sys.exit(1)

    exe_path = sys.argv[1]
    # optional: DLL name + init symbol (defaults preserve old faf_profiler behaviour)
    dll    = sys.argv[2] if len(sys.argv) > 2 else "faf_profiler.dll"
    symbol = sys.argv[3] if len(sys.argv) > 3 else "faf_profiler_init"
    out_path = exe_path.replace(".exe", "_patched.exe")

    print(f"Parsing {exe_path} ...")
    pe = lief.PE.parse(exe_path)
    if pe is None:
        print("ERROR: lief failed to parse PE")
        sys.exit(1)

    # Check if already patched
    for imp in pe.imports:
        if imp.name.lower() == dll.lower():
            print(f"Already patched — {dll} already imported")
            sys.exit(0)

    # Add new import (lief 0.15+ API)
    print(f"Adding import: {dll} -> {symbol}")
    library = pe.add_import(dll)
    library.add_entry(lief.PE.ImportEntry(symbol))

    # Build and write
    cfg = lief.PE.Builder.config_t()
    cfg.imports = True
    builder = lief.PE.Builder(pe, cfg)
    builder.build()
    builder.write(out_path)

    size_orig   = os.path.getsize(exe_path)
    size_patched = os.path.getsize(out_path)
    print(f"Written: {out_path}")
    print(f"  Original: {size_orig:,} bytes")
    print(f"  Patched:  {size_patched:,} bytes")
    print()
    print("Next steps:")
    print(f"  cp {out_path} <game/bin/SupremeCommander.exe>")
    print(f"  cp faf_profiler.dll <game/bin/>")

if __name__ == "__main__":
    main()
