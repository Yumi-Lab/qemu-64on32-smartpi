/*
 * mtbench.c : banc de DEBIT multi-thread (lot Y2) — le harnais qui manquait.
 *
 * Tous les tests du projet mesurent la correctness (torn64 : 0 dechirure) ou un
 * proxy mono-thread (claude --help). La cible reelle est un runtime JS MULTI-THREAD.
 * Ce guest exerce N threads en parallele sur un travail REPRESENTATIF et rend un
 * CHIFFRE de debit (ops/s) + une ligne RESULT machine-parseable ; le script
 * test/run-mtbench.sh fait varier N (1, 2, 4) et rapporte le SCALING. Un emulateur
 * qui ne scale pas au-dela de 1 thread est le symptome cherche (serialisation).
 *
 * Quatre workloads (argument 1) :
 *   atomic : fetch_add relaxes + CAS sur un compteur u64 PARTAGE et contenu
 *            (LDXR/STXR 64-bit invites -> ldrexd/strexd hotes inline sur armv7,
 *            ou chemin exclusif si le backend bascule). Invariant embarque : le
 *            compteur partage final DOIT egaler la somme des increments comptes
 *            par thread (toute perte/race de l'emulation atomique = echec).
 *   alloc  : rafales malloc/free concurrentes (tailles LCG 16..512 o, octet touche)
 *            -> contention des arenas glibc, mmap lock, syscalls brk/mmap.
 *   smc    : code auto-modifiant SIMULTANE : chaque thread a son memfd dual-mappe
 *            W^X (alias W pour ecrire, alias X pour executer), reecrit une fonction
 *            a chaque tour, __builtin___clear_cache (= IC IVAU), execute et verifie
 *            le marqueur. Exerce l'invalidation de TB en parallele (cas JSC JIT).
 *   mixed  : chaque tour = 32 atomiques contendus + 8 paires malloc/free + 1 tour
 *            smc : la charge composite la plus proche d'un runtime JS.
 *
 * Comptage : chaque thread compte ses propres operations dans un compteur LOCAL
 * (ecrit par lui seul, lu par main apres join : pas de trafic atomique parasite
 * sur la mesure, contrairement a un compteur partage). Le debit = total_ops /
 * temps wall mesure par clock_gettime(CLOCK_MONOTONIC) autour de la section
 * parallele. L'arret est un drapeau volatile leve par main apres <seconds>.
 *
 * Usage : mtbench <atomic|alloc|smc|mixed> <nthreads> <seconds>
 * Sortie : lignes humaines + une ligne
 *   RESULT workload=<w> N=<n> seconds=<s> wall_ms=<ms> total_ops=<t> ops_per_sec=<d> per_thread=<c0,c1,...>
 * Exit 0 si OK, 1 erreur d'usage/setup, 2 invariant casse (atomic/mixed ou smc).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/mman.h>

#define MAX_THREADS 16

/* ---------------- etat partage ---------------- */

static volatile int stop = 0;
static volatile int setup_error = 0;

/* Compteur u64 PARTAGE, contenu par tous les threads (workloads atomic/mixed). */
static uint64_t shared_counter = 0;

typedef uint32_t (*smc_fn_t)(void);

typedef struct {
    uint64_t ops;         /* unites d'oeuvre du workload (cf. detail par workload) */
    uint64_t increments;  /* increments reellement emis sur shared_counter         */
    int      id;
    int      workload;    /* WK_*                                                  */
    /* etat smc : alias dual-mappes W^X, propres au thread */
    volatile uint32_t *w_alias;
    smc_fn_t x_fn;
    uint64_t lcg;         /* generateur pseudo-aleatoire local (tailles d'alloc)   */
} worker_t;

enum { WK_ATOMIC, WK_ALLOC, WK_SMC, WK_MIXED };

/* ---------------- workload atomic ----------------
 * Une "op" = un batch de 64 fetch_add relaxes + 1 CAS sur le compteur partage.
 * Le CAS tourne en boucle jusqu'a succes : il compte pour 1 quel que soit le
 * nombre de tentatives (sa contention est precisement ce qu'on veut peser).
 */
static uint64_t atomic_batch(worker_t *wk)
{
    for (int i = 0; i < 64; i++)
        __atomic_add_fetch(&shared_counter, 1, __ATOMIC_RELAXED);
    uint64_t cur = __atomic_load_n(&shared_counter, __ATOMIC_RELAXED);
    while (!__atomic_compare_exchange_n(&shared_counter, &cur, cur + 1,
                                        0 /* strong */, __ATOMIC_RELAXED,
                                        __ATOMIC_RELAXED))
        ;
    return 65; /* 64 add + 1 CAS, tous emis reellement sur shared_counter */
}

/* ---------------- workload alloc ----------------
 * Une "op" = une paire malloc/free (32 paires par rafale, tailles LCG 16..512).
 */
static uint64_t alloc_batch(worker_t *wk)
{
    void *ptrs[32];
    for (int i = 0; i < 32; i++) {
        wk->lcg = wk->lcg * 6364136223846793005ULL + 1442695040888963407ULL;
        size_t sz = 16 + (size_t)((wk->lcg >> 33) % 497);
        ptrs[i] = malloc(sz);
        if (ptrs[i])
            ((volatile char *)ptrs[i])[0] = (char)i; /* force la page */
    }
    for (int i = 0; i < 32; i++)
        free(ptrs[i]);
    return 32;
}

/* ---------------- workload smc ----------------
 * Une "op" = un tour complet ecrire-via-W / clear_cache / executer-via-X.
 * Ecrit `movz w0,#marker ; ret` (verifie a l'assembleur dans smc-alias.c).
 * Chaque thread a SON memfd dual-mappe : pas de fausse contention entre threads,
 * l'effet mesure est le cout de l'invalidation de TB en parallele.
 */
static int smc_setup(worker_t *wk)
{
    int fd = memfd_create("mtbench-smc", 0);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, 4096) != 0) {
        close(fd);
        return -1;
    }
    void *w = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    void *x = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    close(fd);
    if (w == MAP_FAILED || x == MAP_FAILED || w == x)
        return -1;
    wk->w_alias = (volatile uint32_t *)w;
    wk->x_fn = (smc_fn_t)x;
    return 0;
}

/* Renvoie 1 si le tour est correct (code frais execute), 0 sinon. */
static int smc_round(worker_t *wk, uint64_t round)
{
    uint32_t marker = (uint32_t)(0x1000u + (round & 0xFFu)); /* tient dans imm16 */
    wk->w_alias[0] = 0x52800000u | (marker << 5);            /* movz w0,#marker  */
    wk->w_alias[1] = 0xd65f03c0u;                            /* ret              */
    __builtin___clear_cache((char *)wk->x_fn, (char *)wk->x_fn + 8); /* IC IVAU */
    return wk->x_fn() == marker;
}

/* ---------------- boucle worker ---------------- */

static void *thread_func(void *arg)
{
    worker_t *wk = (worker_t *)arg;
    int needs_smc = (wk->workload == WK_SMC || wk->workload == WK_MIXED);

    if (needs_smc && smc_setup(wk) != 0) {
        fprintf(stderr, "ERROR: thread %d : setup smc (memfd/dual-map) impossible\n", wk->id);
        setup_error = 1;
        stop = 1;
        return NULL;
    }

    uint64_t smc_errors = 0;
    while (!stop) {
        switch (wk->workload) {
        case WK_ATOMIC:
            wk->increments += atomic_batch(wk);
            wk->ops++;
            break;
        case WK_ALLOC:
            wk->ops += alloc_batch(wk);
            break;
        case WK_SMC:
            if (!smc_round(wk, wk->ops))
                smc_errors++;
            wk->ops++;
            break;
        case WK_MIXED:
            wk->increments += atomic_batch(wk);
            wk->ops += alloc_batch(wk);   /* compte les paires malloc/free... */
            if (!smc_round(wk, wk->ops))
                smc_errors++;
            wk->ops++;                    /* ... + 1 pour le tour smc         */
            break;
        }
    }

    if (smc_errors > 0) {
        fprintf(stderr, "ERROR: thread %d : %lu tour(s) smc avec code perime/inattendu\n",
                wk->id, (unsigned long)smc_errors);
        setup_error = 1; /* reutilise comme drapeau d'echec global */
    }
    return NULL;
}

/* ---------------- main ---------------- */

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

int main(int argc, char *argv[])
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <atomic|alloc|smc|mixed> <nthreads> <seconds>\n", argv[0]);
        return 1;
    }

    const char *wname = argv[1];
    int workload;
    if      (strcmp(wname, "atomic") == 0) workload = WK_ATOMIC;
    else if (strcmp(wname, "alloc")  == 0) workload = WK_ALLOC;
    else if (strcmp(wname, "smc")    == 0) workload = WK_SMC;
    else if (strcmp(wname, "mixed")  == 0) workload = WK_MIXED;
    else {
        fprintf(stderr, "ERROR: workload inconnu '%s'\n", wname);
        return 1;
    }

    int num_threads = atoi(argv[2]);
    int seconds = atoi(argv[3]);
    if (num_threads < 1 || num_threads > MAX_THREADS || seconds < 1) {
        fprintf(stderr, "ERROR: nthreads in [1..%d], seconds >= 1\n", MAX_THREADS);
        return 1;
    }

    printf("mtbench: workload=%s threads=%d duration=%ds\n", wname, num_threads, seconds);
    fflush(stdout);

    static worker_t workers[MAX_THREADS];
    pthread_t threads[MAX_THREADS];

    uint64_t t0 = now_ms();
    for (int i = 0; i < num_threads; i++) {
        workers[i].ops = 0;
        workers[i].increments = 0;
        workers[i].id = i;
        workers[i].workload = workload;
        workers[i].lcg = 0x9e3779b97f4a7c15ULL ^ (uint64_t)(i + 1) * 0x2545F4914F6CDD1DULL;
        if (pthread_create(&threads[i], NULL, thread_func, &workers[i]) != 0) {
            fprintf(stderr, "ERROR: pthread_create thread %d\n", i);
            stop = 1;
            num_threads = i;
            break;
        }
    }

    for (int elapsed = 0; !stop && elapsed < seconds; elapsed++)
        sleep(1);
    stop = 1;

    for (int i = 0; i < num_threads; i++)
        pthread_join(threads[i], NULL);
    uint64_t wall_ms = now_ms() - t0;

    if (setup_error) {
        printf("FAILURE: erreur de setup ou de coherence smc (voir stderr)\n");
        return 1;
    }

    uint64_t total_ops = 0, total_increments = 0;
    char per_thread[512];
    int off = 0;
    for (int i = 0; i < num_threads; i++) {
        total_ops += workers[i].ops;
        total_increments += workers[i].increments;
        off += snprintf(per_thread + off, sizeof(per_thread) - (size_t)off,
                        "%s%lu", i ? "," : "", (unsigned long)workers[i].ops);
    }

    /* Invariant des workloads a compteur partage : le compteur final DOIT egaler
       la somme des increments emis. Toute perte = emulation atomique incorrecte. */
    if (workload == WK_ATOMIC || workload == WK_MIXED) {
        uint64_t final_counter = __atomic_load_n(&shared_counter, __ATOMIC_RELAXED);
        if (final_counter != total_increments) {
            printf("FAILURE: compteur partage=%lu != increments comptes=%lu "
                   "(emulation atomique incorrecte)\n",
                   (unsigned long)final_counter, (unsigned long)total_increments);
            return 2;
        }
        printf("CHECK OK: compteur partage=%lu == somme des increments\n",
               (unsigned long)final_counter);
    }

    uint64_t ops_per_sec = wall_ms ? total_ops * 1000 / wall_ms : 0;
    printf("RESULT workload=%s N=%d seconds=%d wall_ms=%lu total_ops=%lu ops_per_sec=%lu per_thread=%s\n",
           wname, num_threads, seconds, (unsigned long)wall_ms,
           (unsigned long)total_ops, (unsigned long)ops_per_sec, per_thread);
    printf("SUCCESS: %s N=%d -> %lu ops/s\n", wname, num_threads, (unsigned long)ops_per_sec);
    return 0;
}
