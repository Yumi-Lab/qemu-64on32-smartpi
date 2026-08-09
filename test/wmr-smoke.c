/*
 * Smoke test for walk_memory_regions() callers, exercised through a real
 * aarch64 guest rather than assumed correct from reading the source.
 *
 * Two distinct paths, both go through accel/tcg/user-exec.c's
 * walk_memory_regions(): reading /proc/self/maps (linux-user/syscall.c's
 * open_self_maps_2/open_self_maps_3), and a coredump triggered by an
 * unhandled fatal signal (linux-user/elfload.c's elf_core_dump(), which
 * calls walk_memory_regions() four times, the first of which used to call
 * page_unprotect() from inside the callback -- PROBLEME 10, PROGRESS.md).
 *
 * Deliberately crashes at the end: run with the HOST's RLIMIT_CORE raised
 * (elf_core_dump() reads the emulator's own rlimit, not the guest's) to
 * also exercise the coredump path, or without it to exercise only the
 * /proc/self/maps path.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void)
{
    void *anon = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (anon == MAP_FAILED) {
        fprintf(stderr, "mmap failed\n");
        return 1;
    }
    memset(anon, 0x42, 4096);

    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) {
        fprintf(stderr, "open /proc/self/maps failed\n");
        return 1;
    }
    char line[256];
    long lines = 0, bytes = 0;
    while (fgets(line, sizeof(line), maps)) {
        lines++;
        bytes += (long)strlen(line);
    }
    fclose(maps);
    printf("proc-self-maps: %ld lines, %ld bytes\n", lines, bytes);
    fflush(stdout);

    printf("about to crash (SIGSEGV, no handler)\n");
    fflush(stdout);

    volatile int *null_ptr = NULL;
    *null_ptr = 1;

    return 0; /* unreachable */
}
