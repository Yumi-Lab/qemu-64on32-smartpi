/*
 * torn64-load : isole la DECHIRURE COTE LOAD (lot A2).
 *
 * Un SEUL thread ecrivain met a jour un u64 aligne par un store-release
 * (STLR). Sous un CPU invite pre-LSE2 (lancer qemu avec -cpu cortex-a53),
 * le frontend aarch64 force MO_ALIGN sur le store-release, donc meme le
 * qemu BASELINE l'abaisse en STRD atomique : la memoire ne contient jamais
 * une valeur partielle du fait de l'ecrivain.
 *
 * N threads lecteurs lisent le meme u64 par un load ORDINAIRE (relaxed ->
 * LDR simple, sans MO_ALIGN). En baseline ce load est abaisse en DEUX ld32
 * hote : un lecteur peut capturer la moitie basse d'une generation et la
 * moitie haute d'une autre -> DECHIRURE cote load. Le fix A2 (LDRD garanti)
 * doit supprimer cette dechirure.
 *
 * Attendu :
 *   - qemu baseline  : dechirure detectee (le load ordinaire dechire).
 *   - qemu fork A2   : aucune dechirure (le load ordinaire devient LDRD).
 *
 * Le store etant deja atomique dans les deux cas, toute dechirure observee
 * ici provient exclusivement du chemin de LOAD, ce qui isole le lot A2.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

static volatile uint64_t test_value = 0;
static volatile uint64_t reads = 0;
static volatile int torn_detected = 0;
static volatile int stop = 0;

#define PATTERN_A 0x1111111111111111ULL
#define PATTERN_B 0x2222222222222222ULL

/* Ecrivain : store-release (STLR), atomique en baseline sous CPU pre-LSE2. */
static void *writer_func(void *arg)
{
    (void)arg;
    uint64_t pattern = PATTERN_A;
    while (!stop) {
        __atomic_store_n(&test_value, pattern, __ATOMIC_RELEASE);
        pattern = (pattern == PATTERN_A) ? PATTERN_B : PATTERN_A;
    }
    return NULL;
}

/* Lecteur : load ordinaire (relaxed -> LDR simple, abaisse en 2x ld32 baseline). */
static void *reader_func(void *arg)
{
    int reader_id = (intptr_t)arg;
    while (!stop) {
        uint64_t v = __atomic_load_n(&test_value, __ATOMIC_RELAXED);
        if (v != PATTERN_A && v != PATTERN_B) {
            fprintf(stderr, "ERROR: Torn read detected in reader %d: 0x%016lx\n",
                    reader_id, (unsigned long)v);
            torn_detected = 1;
            stop = 1;
            return NULL;
        }
        uint64_t r = __atomic_add_fetch(&reads, 1, __ATOMIC_RELAXED);
        if (reader_id == 0 && r % 10000000 == 0) {
            fprintf(stdout, "Reads: %lu\n", (unsigned long)r);
            fflush(stdout);
        }
    }
    return NULL;
}

int main(int argc, char *argv[])
{
    int num_readers = 3;
    int duration = 30;

    if (argc > 1) {
        num_readers = atoi(argv[1]);
    }
    if (argc > 2) {
        duration = atoi(argv[2]);
    }
    if (num_readers < 1) {
        num_readers = 1;
    }
    if (duration <= 0) {
        duration = 30;
    }

    printf("torn64-load test: 1 writer (STLR), %d readers (LDR ordinaire), duration %d sec\n",
           num_readers, duration);
    fflush(stdout);

    pthread_t writer;
    pthread_t readers[num_readers];

    pthread_create(&writer, NULL, writer_func, NULL);
    for (int i = 0; i < num_readers; i++) {
        pthread_create(&readers[i], NULL, reader_func, (void *)(intptr_t)i);
    }

    for (int elapsed = 0; !stop && elapsed < duration; elapsed++) {
        sleep(1);
    }
    stop = 1;

    pthread_join(writer, NULL);
    for (int i = 0; i < num_readers; i++) {
        pthread_join(readers[i], NULL);
    }

    unsigned long total = (unsigned long)__atomic_load_n(&reads, __ATOMIC_RELAXED);
    printf("Final reads: %lu\n", total);

    if (torn_detected) {
        printf("ABORTED: Torn read detected after %lu reads\n", total);
        return 1;
    }

    printf("SUCCESS: No torn reads detected after %lu reads\n", total);
    return 0;
}
