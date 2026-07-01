# PathTo determinism spike

Question: can a **C++ reimplementation** of FAF's `NavUtils.PathTo` A* reproduce FAF's
paths **bit-for-bit**? That's the gate for offloading pathfinding to worker threads
without desyncing lockstep (see `faf-analysis/parallelization-strategy.md`).

## Result: YES — 800 / 800 bit-identical

```
graph: 1355 sections, 800 queries
=== RESULT: match=800 mismatch=0 (found-status mismatch=0) skipped=0 ===
*** BIT-IDENTICAL: C++ A* reproduces FAF exactly ***
```

Every query (351 real paths + 449 no-path + degenerate cases) matches FAF's exact
`HeapFrom` chain. The float determinism and heap tie-breaking reproduce perfectly.

## Why it works

The A* is small and fully deterministic (`NavUtils.PathTo` + `NavDatastructures.NavHeap`):
- **cost/heuristic** = `sqrt(dx² + dz²)` on section centers — plain IEEE doubles;
  centers exported at `%.17g` (exact round-trip). Built with `-ffp-contract=off`.
- **heap** = textbook 1-based binary min-heap; tie-break is *pure cost comparison*
  with strict `<`/`>` (no secondary key) — a mechanical port reproduces it.
- **A\*** is *no-reopen* (a section is fixed on first insert) — even simpler to match.
- graph is small (**1355 sections** on Seton's) and static.

Compiled 64-bit SSE2 and it matched bit-for-bit, i.e. the game's Lua FP produces the
same doubles for these distances. (The real worker DLL is 32-bit; re-validate 32-bit
before shipping, but no divergence is expected for `sqrt(dx²+dz²)` at these magnitudes.)

## Bug found in FAF's PathTo

`PathTo`'s "no path found" guard is a Lua precedence bug:

```lua
if not destinationSection.HeapIdentifier == seenIdentifier then  -- (not X) == Y : always false
```

So `PathTo` returns `found=true` for **any same-label pair**, even when the section
graph doesn't actually connect them, yielding a **degenerate `[dest]` path**
(`SectionsToPositions` then draws a straight origin→dest line). Rare (2 of 800 random
pairs), and the terrain is same-label so it's usually harmless — but worth an upstream
report. The validator replicates it exactly (`found == same-label`; path = real trace
if the A* reached dest, else `[dest]`).

### Offload hazard: stale scratch

FAF reuses the per-section `HeapFrom` scratch across queries. For a same-label-but-
*unreachable* dest that a **prior** query had reached, FAF traces STALE `HeapFrom` →
a garbage path that depends on query history. A worker computing fresh can't reproduce
that. Didn't occur in this 800-query run (all degenerate cases had clean `[dest]`), but
the offload must handle it: **fall back to synchronous `PathTo` when the A* doesn't
reach dest** (cheap — it's the rare degenerate case), and offload only genuinely-
reachable paths (the vast majority), which ARE bit-identical.

## Files

- `validate.cpp` — the C++ A* port + comparator (ports `NavHeap` + `PathTo` exactly).
- `spike_data.txt` — exported fixture: 1355-section graph + 800 ground-truth queries.
- `export_snippet.lua` — the Lua exporter (paste into `custom-hook/lua/sim/NavUtils.lua`,
  inside the module scope, to regenerate on another map).
- `build.sh` — build 64-bit (and 32-bit if a multilib toolchain is present).

## Reproduce

```sh
bash build.sh
./validate spike_data.txt              # against the saved fixture
# to regenerate on another map: paste export_snippet.lua into the NavUtils schook,
# run a headless M28 game, then: grep SPIKE_ /tmp/.../game.log > spike_data.txt
```

## Conclusion / next steps

Determinism is **not** the blocker — the C++ A* is bit-identical. The PathTo → worker
offload is viable. Remaining pipeline (parallelization-strategy.md / pathfinding-offload.md):
1. export the section graph to the `faf_worker` DLL once after `NavGenerator.Generate()`;
2. `FAF_OffloadPath(layer, oId, dId)` → next-tick `FAF_PollPath`, reusing the queue/slot infra;
3. route `NavUtils.PathTo` through offload-with-sync-fallback (fallback also covers the
   degenerate/unreachable cases above);
4. throughput measurement + a `mismatch=0` A/B like the GTA offload.
