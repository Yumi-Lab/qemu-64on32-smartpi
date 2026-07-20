/*
 * torn64-unaligned : variante NON ALIGNEE de torn64 (lot A5).
 *
 * Cible un u64 volontairement DESALIGNE (offset 4 dans un buffer aligne 64,
 * donc addr & 7 == 4 != 0). Le fast-path inline echoue le `tst addr,#7` pose
 * en A2/A3 (h->aa.align force a MO_64 quand h->aa.atom >= MO_64) et devie vers
 * le slow-path helper.
 *
 * Rappel semantique : un acces aarch64 64-bit ORDINAIRE porte MO_ATOM_IFALIGN,
 * l'atomicite n'est donc exigee QUE si l'adresse est alignee. Sur un acces non
 * aligne, une dechirure est architecturalement PERMISE (l'invite aarch64 reel
 * ne garantit rien non plus). L'exigence A5 pour ce cas est donc uniquement
 * "PAS DE CRASH", pas "pas de dechirure".
 *
 * On compte les dechirures a titre informatif mais on n'ABORTE JAMAIS dessus :
 * seul un crash de qemu (SIGSEGV/SIGBUS/abort -> le process meurt sur signal,
 * code de sortie non nul) fait echouer le run. Une fin normale renvoie 0.
 *
 * Multi-thread (N >= 2) : arme CF_PARALLEL (pthread_create -> CLONE_VM), sans
 * quoi l'acces mono-thread serait canonise MO_ATOM_NONE et ne solliciterait
 * pas le chemin d'atomicite (cf. constat A4).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

static unsigned char shared_buf[64] __attribute__((aligned(64)));
static volatile uint64_t *shared_ptr;   /* = shared_buf + 4, desaligne 64-bit */

static volatile uint64_t iterations = 0;
static volatile uint64_t torn_reads = 0;
static volatile int stop = 0;

#define PATTERN_A 0x1111111111111111ULL
#define PATTERN_B 0x2222222222222222ULL

static void *thread_func(void *arg)
{
    int thread_id = (intptr_t)arg;
    uint64_t pattern = (thread_id % 2 == 0) ? PATTERN_A : PATTERN_B;

    while (!stop) {
        *shared_ptr = pattern;
        uint64_t read_val = *shared_ptr;
        if (read_val != PATTERN_A && read_val != PATTERN_B) {
            /* dechirure toleree sur non-aligne : on compte, on ne stoppe pas */
            __atomic_add_fetch(&torn_reads, 1, __ATOMIC_RELAXED);
        }
        uint64_t it = __atomic_add_fetch(&iterations, 1, __ATOMIC_RELAXED);
        if (thread_id == 0 && it % 1000000 == 0) {
            fprintf(stdout, "Iterations: %lu (torn so far: %lu)\n",
                    (unsigned long)it,
                    (unsigned long)__atomic_load_n(&torn_reads, __ATOMIC_RELAXED));
            fflush(stdout);
        }
    }
    return NULL;
}

int main(int argc, char *argv[])
{
    int num_threads = 4;
    int duration = 0;
    uint64_t target_iterations = 0;

    if (argc > 1) {
        num_threads = atoi(argv[1]);
    }
    if (argc > 2) {
        duration = atoi(argv[2]);
    }
    if (argc > 3) {
        target_iterations = strtoull(argv[3], NULL, 10);
    }
    if (num_threads < 2) {
        num_threads = 2;   /* >= 2 pour armer CF_PARALLEL */
    }
    if (duration <= 0 && target_iterations == 0) {
        duration = 30;
    }

    shared_ptr = (volatile uint64_t *)(shared_buf + 4);

    printf("torn64-unaligned test: %d threads, duration %d sec, target %lu iterations\n",
           num_threads, duration, (unsigned long)target_iterations);
    printf("target offset in buffer: %ld, addr & 7 = %lu (attendu != 0, non aligne)\n",
           (long)((unsigned char *)shared_ptr - shared_buf),
           (unsigned long)((uintptr_t)shared_ptr & 7));
    fflush(stdout);

    pthread_t threads[num_threads];

    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, thread_func, (void *)(intptr_t)i);
    }

    if (target_iterations > 0) {
        while (!stop && __atomic_load_n(&iterations, __ATOMIC_RELAXED) < target_iterations) {
            usleep(100000);
        }
    } else {
        for (int elapsed = 0; !stop && elapsed < duration; elapsed++) {
            sleep(1);
        }
    }
    stop = 1;

    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }

    unsigned long final_it = (unsigned long)__atomic_load_n(&iterations, __ATOMIC_RELAXED);
    unsigned long final_torn = (unsigned long)__atomic_load_n(&torn_reads, __ATOMIC_RELAXED);
    printf("Final iterations: %lu, torn reads: %lu\n", final_it, final_torn);

    /* Succes A5 non-aligne = qemu n'a PAS crashe. La dechirure est toleree. */
    printf("SUCCESS: no crash after %lu iterations (%lu torn reads tolerated, unaligned)\n",
           final_it, final_torn);
    return 0;
}
