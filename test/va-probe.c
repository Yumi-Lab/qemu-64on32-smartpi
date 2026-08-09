/* va-probe : mesure les limites REELLES de VA d'un process 32-bit sur l'hote.
 * Metrique cle pour comparer les kernels du pad (6.18.24 vs 6.18.40 ...) :
 *   - le plus grand mmap ANONYME contigu obtenable (ce que le gigacage/heap JSC exige)
 *   - la somme totale mappable (sanity vs le plafond user VA)
 * Ne reserve pas de RAM (PROT_NONE + MAP_NORESERVE), donc sur sans risque OOM.
 * Compile armhf : arm-linux-gnueabihf-gcc -O2 -static -o build-out/va-probe test/va-probe.c
 */
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>

#define MB (1UL << 20)

/* plus grand mmap contigu unique, par recherche dichotomique (granularite 1 Mo) */
static unsigned long biggest_single(void) {
    unsigned long lo = MB, hi = 3072UL * MB, best = 0;
    while (lo <= hi) {
        unsigned long mid = lo + (hi - lo) / 2;
        mid &= ~(MB - 1);
        if (mid == 0) break;
        void *p = mmap(NULL, mid, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (p != MAP_FAILED) { munmap(p, mid); best = mid; lo = mid + MB; }
        else { if (mid < MB) break; hi = mid - MB; }
    }
    return best >> 20;
}

/* somme totale mappable en blocs de 16 Mo (jusqu'a epuisement) */
static unsigned long total_mappable(void) {
    unsigned long total = 0;
    const unsigned long chunk = 16UL * MB;
    for (int i = 0; i < 4096; i++) {
        void *p = mmap(NULL, chunk, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
        if (p == MAP_FAILED) break;
        total += chunk;              /* laisse mappe : on veut la somme atteignable */
    }
    return total >> 20;
}

int main(void) {
    printf("max_contiguous_mmap_MB=%lu\n", biggest_single());
    printf("total_mappable_MB=%lu\n", total_mappable());
    return 0;
}
