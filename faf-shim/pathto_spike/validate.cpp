// Determinism spike: does a C++ port of FAF's NavUtils.PathTo A* reproduce FAF's
// paths bit-for-bit? Reads SPIKE_SECTION / SPIKE_QUERY lines exported from a live
// game (see custom-hook/lua/sim/NavUtils.lua spike block), replays the A*, and
// compares the dest->origin HeapFrom chain against FAF's for every query.
//
// Ports FAF's NavHeap (NavDatastructures.lua) and PathTo (NavUtils.lua) exactly:
//   cost  g = parent.g + dist(parent, nb);  f = g + dist(dest, nb)
//   dist  = sqrt(dx*dx + dz*dz)   (double; centers parsed at %.17g -> exact)
//   heap  1-based binary min-heap by f, tie-break = FAF's strict </> swap logic
//   A*    no-reopen (a section is fixed on first insert)
//
// build: g++ -O2 -ffp-contract=off -o validate validate.cpp   (see build.sh for -m32)
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <unordered_map>
#include <string>
using namespace std;

struct Section { double cx, cz; int label; vector<int> nb; }; // nb = neighbor identifiers

static vector<Section> S;                 // indexed 0..n-1
static unordered_map<long,int> id2idx;    // identifier -> index

// per-query scratch (no-reopen A*)
static vector<int>    seen;   // == qid when discovered this query
static vector<int>    from;   // predecessor identifier (-1 = none)
static vector<double> g, f;   // HeapAcquiredCosts, HeapTotalCosts

static inline double dist(int a, int b) {
    double dx = S[a].cx - S[b].cx;
    double dz = S[a].cz - S[b].cz;
    return sqrt(dx*dx + dz*dz);
}

// ---- NavHeap port (1-based array of section indices; compare via f[idx]) --------
static vector<int> heap; // heap[1..heapSize]
static int heapSize = 0;
static inline void heapClear(){ heapSize = 0; }
static inline void rootify(){
    int index = heapSize;
    int parent = index / 2;
    while (parent >= 1){
        if (f[heap[parent]] < f[heap[index]]) return;   // strict <
        int tmp = heap[parent]; heap[parent] = heap[index]; heap[index] = tmp;
        index = parent; parent = parent / 2;
    }
}
static inline void heapInsert(int idx){
    heapSize++;
    if ((int)heap.size() <= heapSize) heap.resize(heapSize + 1);
    heap[heapSize] = idx;
    rootify();
}
static inline void heapify(){
    int index = 1, left = 2, right = 3;
    while (left <= heapSize){
        int mn = left;
        if (right <= heapSize && f[heap[right]] < f[heap[left]]) mn = right; // strict <
        if (f[heap[mn]] > f[heap[index]]) return;                            // strict >
        int tmp = heap[mn]; heap[mn] = heap[index]; heap[index] = tmp;
        index = mn; left = 2*index; right = 2*index + 1;
    }
}
static inline int heapExtractMin(){
    if (heapSize == 0) return -1;
    int v = heap[1];
    heap[1] = heap[heapSize];
    heapSize--;
    heapify();
    return v;
}

// ---- PathTo A*, returns dest->origin chain of identifiers (matching the Lua walk) --
static int qid = 0;
static bool astar(int oIdx, int dIdx, vector<long>& outSeq){
    // Replicate FAF's PathTo EXACTLY, bug included:
    //  1. CanPathTo pre-filter: no path unless origin/dest share a label.
    //  2. A* search (below).
    //  3. FAF's "no path found" guard `if not dest.HeapId == seenId` is a precedence
    //     bug (parses as (not X)==Y, always false), so PathTo returns found=true for
    //     ANY same-label pair. The path is TraceSections(dest): the real chain if the
    //     A* reached dest, else the degenerate [dest] (dest.HeapFrom untouched = nil,
    //     for clean scratch). So: found == same-label; path == trace-or-[dest].
    if (S[oIdx].label != S[dIdx].label) return false;
    qid++;
    heapClear();
    // originSection
    seen[oIdx] = qid; from[oIdx] = -1; g[oIdx] = 0.0; f[oIdx] = dist(oIdx, dIdx);
    heapInsert(oIdx);
    // destinationSection: HeapIdentifier=0 sentinel (not seen), f=0
    // (we simply leave seen[dIdx] != qid; it gets set when first reached)
    while (heapSize > 0){
        int sec = heapExtractMin();
        if (sec == dIdx) break;
        const vector<int>& nbs = S[sec].nb;               // neighbor identifiers, in array order
        for (size_t k = 0; k < nbs.size(); ++k){
            auto it = id2idx.find(nbs[k]);
            if (it == id2idx.end()) continue;             // neighbor id not in graph (shouldn't happen)
            int nb = it->second;
            if (S[nb].label > 0 && seen[nb] != qid){
                seen[nb] = qid;
                from[nb] = sec;                           // predecessor INDEX (-> identifier at trace)
                g[nb] = g[sec] + dist(sec, nb);
                f[nb] = g[nb] + dist(dIdx, nb);
                heapInsert(nb);
            }
        }
    }
    // FAF's bugged guard never returns nil -> found=true for any same-label pair.
    // Trace dest->origin via HeapFrom (only fresh, this-query pointers; a dest that the
    // A* did not reach has seen[dest]!=qid -> degenerate [dest], matching FAF for clean
    // scratch). NOTE: if a PRIOR query had reached dest, FAF would trace STALE HeapFrom;
    // that cross-query-stateful case is a real offload hazard (see writeup).
    int cur = dIdx, guard = 0;
    while (cur >= 0 && guard < 1000000){
        outSeq.push_back(cur);
        int pr = (seen[cur] == qid) ? from[cur] : -1;
        if (pr < 0) break;
        cur = pr; guard++;
    }
    return true;
}

int main(int argc, char** argv){
    if (argc < 2){ fprintf(stderr, "usage: validate <spike.log>\n"); return 2; }
    FILE* fp = fopen(argv[1], "r");
    if (!fp){ perror("open"); return 2; }

    // first pass: sections
    char* line = nullptr; size_t cap = 0; ssize_t len;
    vector<long> identOf; // index -> identifier
    // temp store to build after we know indices
    struct RawSec { long id; double cx, cz; int label; vector<long> nb; };
    vector<RawSec> raw;
    // queries
    struct Q { long o, d; int found; vector<long> seq; };
    vector<Q> queries;

    while ((len = getline(&line, &cap, fp)) != -1){
        char* p = strstr(line, "SPIKE_SECTION ");
        if (p){
            RawSec r; r.id=0; r.cx=r.cz=0; r.label=0;
            // format: SPIKE_SECTION <id> <cx> <cz> <label> N <n1,n2,...>
            char nbbuf[8192] = {0};
            int got = sscanf(p, "SPIKE_SECTION %ld %lf %lf %d N %8191[^\n]",
                             &r.id, &r.cx, &r.cz, &r.label, nbbuf);
            if (got >= 4){
                if (got == 5){
                    char* t = strtok(nbbuf, ",");
                    while (t){ r.nb.push_back(atol(t)); t = strtok(nullptr, ","); }
                }
                raw.push_back(r);
            }
            continue;
        }
        p = strstr(line, "SPIKE_QUERY ");
        if (p){
            Q q; q.o=q.d=0; q.found=0;
            int qn; char fnd[16] = {0}; char seqbuf[65536] = {0};
            // SPIKE_QUERY <q> o=<id> d=<id> found=<bool> seq=<a,b,...>
            int got = sscanf(p, "SPIKE_QUERY %d o=%ld d=%ld found=%15s seq=%65535[^\n]",
                             &qn, &q.o, &q.d, fnd, seqbuf);
            if (got >= 4){
                q.found = (strncmp(fnd, "true", 4) == 0) ? 1 : 0;
                if (got == 5 && q.found){
                    char* t = strtok(seqbuf, ",");
                    while (t){ q.seq.push_back(atol(t)); t = strtok(nullptr, ","); }
                }
                queries.push_back(q);
            }
            continue;
        }
    }
    fclose(fp);
    free(line);

    // build graph
    S.resize(raw.size());
    identOf.resize(raw.size());
    for (size_t i = 0; i < raw.size(); ++i){ id2idx[raw[i].id] = (int)i; identOf[i] = raw[i].id; }
    for (size_t i = 0; i < raw.size(); ++i){
        S[i].cx = raw[i].cx; S[i].cz = raw[i].cz; S[i].label = raw[i].label;
        S[i].nb = vector<int>(raw[i].nb.begin(), raw[i].nb.end()); // store identifiers
    }
    int n = (int)S.size();
    seen.assign(n, 0); from.assign(n, -1); g.assign(n, 0); f.assign(n, 0);
    heap.assign(n + 2, 0);

    printf("graph: %d sections, %zu queries\n", n, queries.size());

    long match = 0, mismatch = 0, foundMismatch = 0, skipped = 0;
    for (auto& q : queries){
        auto io = id2idx.find(q.o), id = id2idx.find(q.d);
        if (io == id2idx.end() || id == id2idx.end()){ skipped++; continue; }
        vector<long> seqIdx;
        bool found = astar(io->second, id->second, seqIdx);
        // convert seqIdx (indices) to identifiers
        vector<long> mySeq;
        for (long ix : seqIdx) mySeq.push_back(identOf[ix]);
        if (found != (bool)q.found){
            foundMismatch++; mismatch++;
            if (foundMismatch <= 12){
                int oi = io->second, di = id->second;
                printf("FOUND-MISMATCH o=%ld(lbl %d) d=%ld(lbl %d): faf=%d cpp=%d  cppPathLen=%zu\n",
                       q.o, S[oi].label, q.d, S[di].label, q.found, (int)found, mySeq.size());
            }
            continue;
        }
        if (!found) { match++; continue; }
        if (mySeq == q.seq) match++;
        else {
            mismatch++;
            if (mismatch <= 5){
                printf("MISMATCH q(o=%ld,d=%ld): faf=[", q.o, q.d);
                for (size_t i=0;i<q.seq.size();++i) printf("%s%ld", i?",":"", q.seq[i]);
                printf("] cpp=[");
                for (size_t i=0;i<mySeq.size();++i) printf("%s%ld", i?",":"", mySeq[i]);
                printf("]\n");
            }
        }
    }
    printf("\n=== RESULT: match=%ld mismatch=%ld (found-status mismatch=%ld) skipped=%ld ===\n",
           match, mismatch, foundMismatch, skipped);
    printf("%s\n", mismatch==0 ? "*** BIT-IDENTICAL: C++ A* reproduces FAF exactly ***"
                               : "!!! divergence — see mismatches above !!!");
    return mismatch==0 ? 0 : 1;
}
