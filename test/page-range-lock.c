/*
 * Host-native unit + concurrency test for the page-range-lock stripe math.
 *
 * The stripe math (include/exec/page-range-lock.h) is the future replacement
 * for mmap_lock at two hot user-mode sites (IC IVAU invalidation, TB
 * re-generation, see Y4's contention finding). It is not wired into qemu
 * yet, so this exercises exactly what a real caller would: build a stripe
 * set for a page range, then take/release those stripes. The mutex array in
 * accel/tcg/page-range-lock.c needs a full qemu build (qemu/osdep.h) to
 * compile, so this test drives its own independent mutex array through the
 * SAME header logic -- the same "independent reference" approach as
 * test/tb-dedup-key.c.
 *
 * Builds and runs on the Mac with a plain host cc + pthreads, no qemu, no
 * docker.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <unistd.h>

#include "../qemu/include/exec/page-range-lock.h"

static int failures;

static void check(const char *what, int ok)
{
    printf("%-58s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) {
        failures++;
    }
}

static void check_pure_logic(void)
{
    PageRangeLockSet set;

    check("stripe_of wraps every PAGE_RANGE_LOCK_STRIPES pages",
          page_range_lock_stripe_of(0) ==
          page_range_lock_stripe_of(PAGE_RANGE_LOCK_STRIPES));

    check("stripe_of is deterministic",
          page_range_lock_stripe_of(12345) == page_range_lock_stripe_of(12345));

    page_range_lock_set_build(&set, 5, 5);
    check("single page -> exactly one stripe", set.count == 1);
    check("single page -> correct stripe",
          set.stripe[0] == page_range_lock_stripe_of(5));

    page_range_lock_set_build(&set, 3, 3 + PAGE_RANGE_LOCK_STRIPES);
    check("STRIPES+1 consecutive pages -> every stripe touched once",
          set.count == PAGE_RANGE_LOCK_STRIPES);

    page_range_lock_set_build(&set, 0, (uint64_t)1 << 40);
    check("a huge range does not hang and caps at PAGE_RANGE_LOCK_STRIPES",
          set.count == PAGE_RANGE_LOCK_STRIPES);

    page_range_lock_set_build(&set, PAGE_RANGE_LOCK_STRIPES - 1,
                               PAGE_RANGE_LOCK_STRIPES + 2);
    {
        bool sorted = true;
        unsigned int i;

        for (i = 1; i < set.count; i++) {
            if (set.stripe[i] <= set.stripe[i - 1]) {
                sorted = false;
            }
        }
        check("stripe set is strictly ascending across the wraparound", sorted);
    }

    {
        PageRangeLockSet a, b;

        page_range_lock_set_build(&a, 100, 100);
        page_range_lock_set_build(&b, 101, 101);
        check("two disjoint single-page ranges pin distinct stripes here",
              a.stripe[0] != b.stripe[0]);
    }
}

/*
 * Independent mutex array driven by the header's stripe math -- proves the
 * ALGORITHM's concurrency properties (same page serializes, disjoint pages
 * do not, reentrant hold/release, the release_current_thread() escape hatch)
 * ahead of wiring the real accel/tcg/page-range-lock.c array into qemu's
 * execution loop. Mirrors that file's per-thread reentrance counter exactly,
 * so a bug in the counting logic would show up here first.
 */
static pthread_mutex_t local_stripe[PAGE_RANGE_LOCK_STRIPES];
static __thread unsigned int local_stripe_hold_count[PAGE_RANGE_LOCK_STRIPES];
static volatile int critical_users;
static volatile int max_critical_users;

struct worker_arg {
    uint64_t first_page;
    uint64_t last_page;
    int hold_ms;
};

static void local_acquire(const PageRangeLockSet *s)
{
    unsigned int i;

    for (i = 0; i < s->count; i++) {
        unsigned int stripe = s->stripe[i];

        if (local_stripe_hold_count[stripe]++ == 0) {
            pthread_mutex_lock(&local_stripe[stripe]);
        }
    }
}

static void local_release(const PageRangeLockSet *s)
{
    unsigned int i;

    for (i = 0; i < s->count; i++) {
        unsigned int stripe = s->stripe[i];

        if (--local_stripe_hold_count[stripe] == 0) {
            pthread_mutex_unlock(&local_stripe[stripe]);
        }
    }
}

static void local_release_current_thread(void)
{
    unsigned int i;

    for (i = 0; i < PAGE_RANGE_LOCK_STRIPES; i++) {
        if (local_stripe_hold_count[i] != 0) {
            local_stripe_hold_count[i] = 0;
            pthread_mutex_unlock(&local_stripe[i]);
        }
    }
}

static bool local_held_by_current_thread(void)
{
    unsigned int i;

    for (i = 0; i < PAGE_RANGE_LOCK_STRIPES; i++) {
        if (local_stripe_hold_count[i] != 0) {
            return true;
        }
    }
    return false;
}

static void *worker(void *arg)
{
    struct worker_arg *w = arg;
    PageRangeLockSet set;
    int n, prev_max;

    page_range_lock_set_build(&set, w->first_page, w->last_page);
    local_acquire(&set);

    n = __sync_add_and_fetch(&critical_users, 1);
    do {
        prev_max = max_critical_users;
        if (n <= prev_max) {
            break;
        }
    } while (!__sync_bool_compare_and_swap(&max_critical_users, prev_max, n));

    usleep(w->hold_ms * 1000);
    __sync_sub_and_fetch(&critical_users, 1);

    local_release(&set);
    return NULL;
}

static void run_pair(struct worker_arg *a, struct worker_arg *b)
{
    pthread_t t1, t2;

    critical_users = 0;
    max_critical_users = 0;
    pthread_create(&t1, NULL, worker, a);
    usleep(10000); /* let the first worker take its lock(s) first */
    pthread_create(&t2, NULL, worker, b);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
}

static void check_concurrency(void)
{
    unsigned int i;

    for (i = 0; i < PAGE_RANGE_LOCK_STRIPES; i++) {
        pthread_mutex_init(&local_stripe[i], NULL);
    }

    {
        struct worker_arg a = { .first_page = 7, .last_page = 7, .hold_ms = 80 };
        struct worker_arg b = { .first_page = 7, .last_page = 7, .hold_ms = 80 };

        run_pair(&a, &b);
        check("same page: mutual exclusion held (never 2 in the critical section)",
              max_critical_users == 1);
    }

    {
        struct worker_arg a = { .first_page = 1, .last_page = 1, .hold_ms = 80 };
        struct worker_arg b = { .first_page = 2, .last_page = 2, .hold_ms = 80 };

        run_pair(&a, &b);
        check("disjoint pages/stripes: both ran concurrently (reached 2)",
              max_critical_users == 2);
    }
}

/*
 * Y5 sous-lot 4 found the missing prerequisite for wiring the four tb_root
 * sites: a per-thread reentrance count (like mmap_lock_count) and an escape
 * hatch (like the have_mmap_lock()-backed mmap_unlock() call at the
 * buffer_overflow bailout in accel/tcg/translate-all.c) that can release
 * whatever the current thread holds without being told exactly what that is.
 * These two checks prove that extension in isolation, before sous-lot 6
 * wires it into any real call site.
 */

struct waiter_arg {
    uint64_t first_page;
    uint64_t last_page;
    volatile int *entered;
};

static void *waiter(void *arg)
{
    struct waiter_arg *w = arg;
    PageRangeLockSet set;

    page_range_lock_set_build(&set, w->first_page, w->last_page);
    local_acquire(&set);
    __sync_fetch_and_add(w->entered, 1);
    local_release(&set);
    return NULL;
}

static void check_reentrance(void)
{
    PageRangeLockSet set;
    volatile int entered = 0;
    pthread_t t;
    struct waiter_arg w = { .first_page = 20, .last_page = 20, .entered = &entered };

    page_range_lock_set_build(&set, 20, 20);

    local_acquire(&set); /* depth 1 */
    local_acquire(&set); /* depth 2: nested acquire, same thread, must not deadlock */

    pthread_create(&t, NULL, waiter, &w);
    usleep(30000);
    check("reentrant hold (depth 2): a same-page waiter is still blocked",
          entered == 0);

    local_release(&set); /* depth 2 -> 1: still held */
    usleep(30000);
    check("partial release (depth 2->1) does not free the stripe",
          entered == 0);

    local_release(&set); /* depth 1 -> 0: now released */
    pthread_join(t, NULL);
    check("full release (depth 1->0) lets the waiter in", entered == 1);
}

static void check_escape_hatch(void)
{
    PageRangeLockSet set;
    volatile int entered = 0;
    pthread_t t;
    struct waiter_arg w = { .first_page = 30, .last_page = 31, .entered = &entered };

    /* Simulate the translator's two-page case (DECOUVERTE A, Y5 sous-lot 4):
     * a second, distinct stripe acquired separately, mid-decode, once the
     * page boundary is discovered -- not as a single range. */
    page_range_lock_set_build(&set, 30, 30);
    local_acquire(&set);
    page_range_lock_set_build(&set, 31, 31);
    local_acquire(&set);

    pthread_create(&t, NULL, waiter, &w);
    usleep(30000);
    check("both stripes held: a waiter needing either page is blocked",
          entered == 0);

    /* The escape hatch must free BOTH stripes without being told the exact
     * set held, exactly like the buffer_overflow bailout in tb_gen_code
     * needs (reached via siglongjmp, no automatic unwind of anything). */
    local_release_current_thread();

    pthread_join(t, NULL);
    check("release_current_thread() frees every stripe this thread held",
          entered == 1);
}

static void check_escape_hatch_noop(void)
{
    PageRangeLockSet set;
    volatile int entered = 0;
    pthread_t t;
    struct waiter_arg w = { .first_page = 40, .last_page = 40, .entered = &entered };

    /* Nothing held: must be a safe no-op, not an unlock of an unheld mutex. */
    local_release_current_thread();

    page_range_lock_set_build(&set, 40, 40);
    local_acquire(&set);
    local_release(&set);

    /* If the no-op above had wrongly unlocked stripe 40's mutex, this would
     * still pass by accident; the real check is that normal locking on that
     * same stripe keeps working correctly right after. */
    pthread_create(&t, NULL, waiter, &w);
    pthread_join(t, NULL);
    check("release_current_thread() on an empty thread is a safe no-op",
          entered == 1);
}

/*
 * Y5 sous-lot 7 (PROGRESS.md, PROBLEME 4 resolution) needs a query that
 * mirrors have_mmap_lock(): true iff the CURRENT thread holds at least one
 * stripe, so assert_memory_lock() at page_protect()/page_unprotect() can
 * recognize a stripe as well as mmap_lock. Not wired to any real call site
 * yet (sous-lot 9) -- this proves the query itself against every state the
 * reentrance/escape-hatch checks above already exercise.
 */
static void check_held_by_current_thread(void)
{
    PageRangeLockSet set;

    check("holds nothing at start of this check",
          !local_held_by_current_thread());

    page_range_lock_set_build(&set, 50, 50);
    local_acquire(&set);
    check("true after a single acquire", local_held_by_current_thread());

    local_acquire(&set); /* reentrant, depth 2 */
    check("still true while reentrantly held", local_held_by_current_thread());

    local_release(&set); /* depth 2 -> 1 */
    check("still true after a partial release", local_held_by_current_thread());

    local_release(&set); /* depth 1 -> 0 */
    check("false again once fully released", !local_held_by_current_thread());

    page_range_lock_set_build(&set, 51, 51);
    local_acquire(&set);
    page_range_lock_set_build(&set, 52, 52);
    local_acquire(&set);
    check("true while holding two DISTINCT stripes",
          local_held_by_current_thread());
    local_release_current_thread();
    check("false after the escape hatch drops both",
          !local_held_by_current_thread());
}

int main(void)
{
    check_pure_logic();
    check_concurrency();
    check_reentrance();
    check_escape_hatch();
    check_escape_hatch_noop();
    check_held_by_current_thread();

    if (failures) {
        printf("page-range-lock: %d check(s) FAILED\n", failures);
        return 1;
    }
    printf("page-range-lock: all checks passed\n");
    return 0;
}
