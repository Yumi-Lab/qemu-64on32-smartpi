/* Z1 sous-lot (b) : sonde minimale, confirme si MADV_HUGEPAGE est
 * accepte par le kernel hote. Compile et execute directement sur le pad
 * (gcc local, pas notre qemu) : ce n'est pas un test invite, juste une
 * reconnaissance de la disponibilite THP cote hote.
 * Usage: gcc -o madvise-hugepage-probe madvise-hugepage-probe.c && ./madvise-hugepage-probe
 */
#include <stdio.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

int main(void)
{
    size_t sz = 4096 * 10;
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    int rc = madvise(p, sz, MADV_HUGEPAGE);
    printf("madvise(MADV_HUGEPAGE) rc=%d errno=%s\n",
           rc, rc ? strerror(errno) : "-");
    return 0;
}
