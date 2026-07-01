CC      = i686-w64-mingw32-gcc
CFLAGS  = -m32 -O2 -Wall -Wextra -shared -DWIN32 -D_WIN32_WINNT=0x0501
LDFLAGS = -m32 -shared -Wl,--subsystem,windows -lpsapi

TARGETS = faf_profiler.dll faf_worker.dll faf_path.dll

all: $(TARGETS)

faf_profiler.dll: faf_profiler.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

faf_worker.dll: faf_worker.c
	$(CC) $(CFLAGS) -msse2 -fno-omit-frame-pointer -o $@ $< $(LDFLAGS)

# -mfpmath=sse: force SSE2 double math so the A* is bit-identical to the spike's
# validated result (not x87 80-bit intermediates). See faf-shim/pathto_spike.
faf_path.dll: faf_path.c
	$(CC) $(CFLAGS) -msse2 -mfpmath=sse -fno-omit-frame-pointer -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGETS)

.PHONY: all clean
