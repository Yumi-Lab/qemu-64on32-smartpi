#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

volatile uint64_t test_value = 0;
volatile uint64_t iterations = 0;
volatile int torn_detected = 0;
volatile int stop = 0;

#define PATTERN_A 0x1111111111111111ULL
#define PATTERN_B 0x2222222222222222ULL

void *thread_func(void *arg) {
    int thread_id = (intptr_t)arg;
    uint64_t pattern = (thread_id % 2 == 0) ? PATTERN_A : PATTERN_B;

    while (!stop) {
        test_value = pattern;
        uint64_t read_val = test_value;
        if (read_val != PATTERN_A && read_val != PATTERN_B) {
            fprintf(stderr, "ERROR: Torn read detected in thread %d: 0x%016lx\n", thread_id, read_val);
            torn_detected = 1;
            stop = 1;
            return NULL;
        }

        uint64_t it = __atomic_add_fetch(&iterations, 1, __ATOMIC_RELAXED);
        if (thread_id == 0 && it % 1000000 == 0) {
            fprintf(stdout, "Iterations: %lu\n", it);
            fflush(stdout);
        }
    }

    return NULL;
}

int main(int argc, char *argv[]) {
    int num_threads = 2;
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
    if (duration <= 0 && target_iterations == 0) {
        duration = 30;
    }

    printf("torn64 test: %d threads, duration %d sec, target %lu iterations\n",
           num_threads, duration, target_iterations);
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

    printf("Final iterations: %lu\n", __atomic_load_n(&iterations, __ATOMIC_RELAXED));

    if (torn_detected) {
        printf("ABORTED: Torn read detected after %lu iterations\n",
               __atomic_load_n(&iterations, __ATOMIC_RELAXED));
        return 1;
    }

    printf("SUCCESS: No torn reads detected after %lu iterations\n",
           __atomic_load_n(&iterations, __ATOMIC_RELAXED));
    return 0;
}
