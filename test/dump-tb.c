#include <stdint.h>
#include <pthread.h>

/*
 * Guest minimal isole a UNE fonction : un LDR x?,[x?] et un STR x?,[x?]
 * ordinaires (aarch64 AccType_NORMAL, ni exclusif ni atomique explicite) sur
 * un u64 aligne. Sert de cible a test/dump-tb.sh (-dfilter sur cette
 * fonction) pour prouver que le backend arm hote emet LDRD/STRD (Fix A2/A3),
 * pas 2x ld32/st32.
 *
 * Un thread compagnon est cree AVANT l'appel : QEMU ne requiert l'atomicite
 * MO_64 (CF_PARALLEL) qu'une fois l'invite effectivement multithreade
 * (linux-user/syscall.c, premier clone CLONE_VM). Mono-thread, cet acces
 * serait canonise en MO_ATOM_NONE (dechirure non observable par un seul
 * thread) et resterait sur le chemin 2x ld32/st32, non representatif du cas
 * reel (torn64) que ce lot doit prouver.
 */

volatile uint64_t g_val __attribute__((aligned(8))) = 0x1122334455667788ULL;

__attribute__((noinline, used))
uint64_t touch64(uint64_t v)
{
    uint64_t old = g_val;
    g_val = v;
    return old;
}

static void *idle_thread(void *arg)
{
    (void)arg;
    return NULL;
}

int main(void)
{
    pthread_t t;
    pthread_create(&t, NULL, idle_thread, NULL);
    pthread_join(t, NULL);

    uint64_t r = touch64(0xdeadbeefcafebabeULL);
    return (r == 0x1122334455667788ULL) ? 0 : 1;
}
