#!/usr/bin/env python3
# perf_symbolize.py — map perf self-time addresses in ForgedAlliance(_base).exe to
# named engine functions using faf-fa-patches/Info.txt.
#
# ForgedAlliance.exe is ASLR-off at base 0x400000, and perf reports DSO-relative
# offsets, so VA = perf_offset + 0x400000. Info.txt has "HHHHHHHH Name" lines.
# We bisect each VA to the nearest function entry <= VA and sum self-% per function.
#
# Usage:
#   perf report -i perf.data --stdio -g none --no-children \
#       --dsos=ForgedAlliance_base.exe --sort=symbol 2>/dev/null \
#     | python3 faf-shim/perf_symbolize.py faf-fa-patches/Info.txt
import sys, re, bisect

info_path = sys.argv[1] if len(sys.argv) > 1 else "faf-fa-patches/Info.txt"
BASE = 0x400000

syms = []  # (va, name)
with open(info_path, errors="ignore") as f:
    for line in f:
        m = re.match(r"^\s*([0-9A-Fa-f]{8})\s+(\S.*?)\s*$", line)
        if m:
            syms.append((int(m.group(1), 16), m.group(2)))
syms.sort()
addrs = [s[0] for s in syms]

agg = {}   # name -> [pct, nearest_va, min_delta]
unknown = 0.0
line_re = re.compile(r"([0-9]+\.[0-9]+)%.*?0x([0-9a-fA-F]+)")
for line in sys.stdin:
    m = line_re.search(line)
    if not m:
        continue
    pct = float(m.group(1))
    va = int(m.group(2), 16) + BASE
    i = bisect.bisect_right(addrs, va) - 1
    if i < 0:
        unknown += pct
        continue
    fva, name = syms[i]
    delta = va - fva
    # If the nearest named entry is implausibly far below (>64KB), call it unknown.
    if delta > 0x10000:
        unknown += pct
        key = "?unnamed@0x%X" % va
        agg.setdefault(key, [0.0, va, 0])
        agg[key][0] += pct
        continue
    e = agg.setdefault(name, [0.0, fva, delta])
    e[0] += pct
    if delta < e[2]:
        e[2] = delta

rows = sorted(agg.items(), key=lambda kv: -kv[1][0])
print("%-7s  %-30s  %-10s  %s" % ("self%", "function", "entry_VA", "near"))
for name, (pct, va, delta) in rows[:30]:
    print("%6.2f%%  %-30s  0x%08X  +0x%X" % (pct, name, va, delta))
print("---")
print("unmapped/unnamed total: %.2f%%" % unknown)
