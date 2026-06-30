CC      = i686-w64-mingw32-gcc
CFLAGS  = -m32 -O2 -Wall -Wextra -shared -DWIN32 -D_WIN32_WINNT=0x0501
LDFLAGS = -m32 -shared -Wl,--subsystem,windows -lpsapi

TARGETS = faf_profiler.dll faf_worker.dll

all: $(TARGETS)

faf_profiler.dll: faf_profiler.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

faf_worker.dll: faf_worker.c
	$(CC) $(CFLAGS) -msse2 -fno-omit-frame-pointer -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGETS)

.PHONY: all clean
