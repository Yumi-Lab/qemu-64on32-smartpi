/*
 * Host-native unit + concurrency test for the pageflags_lock primitive.
 *
 * include/exec/pageflags-lock.h is a dedicated lock for pageflags_root
 * (accel/tcg/user-exec.c), needed once page_protect()/page_unprotect() move
 * off mmap_lock onto the Y5 page-range stripe lock (design (c), PROGRESS.md
 * Y5 sous-lot 6/7): a thread holding only mmap_lock would no longer exclude
 * a concurrent stripe-holding writer of pageflags_root, so pageflags_root
 * needs its own lock, independent of both mmap_lock and the stripes.
 *
 * accel/tcg/pageflags-lock.c needs a full qemu build (qemu/osdep.h) to
 * compile, so this test drives its own independent mutex + reentrance
 * counter through the SAME technique (a clone of linux-user/mmap.c's
 * mmap_lock/mmap_lock_count) -- the same "independent reference" approach
 * as test/page-range-lock.c and test/tb-dedup-key.c.
 *
 * NOT wired into pageflags_root's six mutator functions yet (Y5 sous-lot 9):
 * this only proves the primitive itself -- mutual exclusion and per-thread
 * reentrance -- in isolation.
 *
 * Builds and runs on the Mac with a plain host cc + pthreads, no qemu, no
 * docker.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

static int failures;

static void check(const char *what, int ok)
{
    printf("%-58s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) {
        failures++;
    }
}

/*
 * Mirrors accel/tcg/pageflags-lock.c exactly: one process-wide mutex, a
 * per-thread reentrance counter (same trick as mmap_lock_count), no escape
 * hatch (unlike page-range-lock.c's stripes, pageflags_lock is never held
 * across a call that could bail out via siglongjmp -- PROGRESS.md's
 * PROBLEME 8/9 raffinement always releases it before the TB invalidation
 * call, within the same instruction sequence).
 */
static pthread_mutex_t local_mutex = PTHREAD_MUTEX_INITIALIZER;
static __thread int local_lock_count;

static void local_lock(void)
{
    if (local_lock_count++ == 0) {
        pthread_mutex_lock(&local_mutex);
    }
}

static void local_unlock(void)
{
    if (--local_lock_count == 0) {
        pthread_mutex_unlock(&local_mutex);
    }
}

static volatile int critical_users;
static volatile int max_critical_users;

static void *worker(void *arg)
{
    int hold_ms = *(int *)arg;
    int n, prev_max;

    local_lock();

    n = __sync_add_and_fetch(&critical_users, 1);
    do {
        prev_max = max_critical_users;
        if (n <= prev_max) {
            break;
        }
    } while (!__sync_bool_compare_and_swap(&max_critical_users, prev_max, n));

    usleep(hold_ms * 1000);
    __sync_sub_and_fetch(&critical_users, 1);

    local_unlock();
    return NULL;
}

static void check_mutual_exclusion(void)
{
    pthread_t t1, t2;
    int hold_ms = 80;

    critical_users = 0;
    max_critical_users = 0;
    pthread_create(&t1, NULL, worker, &hold_ms);
    usleep(10000); /* let the first worker take the lock first */
    pthread_create(&t2, NULL, worker, &hold_ms);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    check("mutual exclusion held (never 2 threads in the critical section)",
          max_critical_users == 1);
}

struct waiter_arg {
    volatile int *entered;
};

static void *waiter(void *arg)
{
    struct waiter_arg *w = arg;

    local_lock();
    __sync_fetch_and_add(w->entered, 1);
    local_unlock();
    return NULL;
}

static void check_reentrance(void)
{
    volatile int entered = 0;
    pthread_t t;
    struct waiter_arg w = { .entered = &entered };

    local_lock(); /* depth 1 */
    local_lock(); /* depth 2: nested acquire, same thread, must not deadlock */

    pthread_create(&t, NULL, waiter, &w);
    usleep(30000);
    check("reentrant hold (depth 2): another thread is still blocked",
          entered == 0);

    local_unlock(); /* depth 2 -> 1: still held */
    usleep(30000);
    check("partial release (depth 2->1) does not free the lock",
          entered == 0);

    local_unlock(); /* depth 1 -> 0: now released */
    pthread_join(t, NULL);
    check("full release (depth 1->0) lets the other thread in", entered == 1);
}

int main(void)
{
    check_mutual_exclusion();
    check_reentrance();

    if (failures) {
        printf("pageflags-lock: %d check(s) FAILED\n", failures);
        return 1;
    }
    printf("pageflags-lock: all checks passed\n");
    return 0;
}
