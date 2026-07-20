# Reproduction: Torn 64-bit Reads in QEMU 9.2.4 User-Mode

## Summary

QEMU 9.2.4 user-mode (aarch64-linux-user on armv7 host) exhibits race-condition-induced memory corruption when multi-threaded binaries perform ordinary 64-bit load/store operations on aligned memory. The root cause: TCG lowers 64-bit accesses to TWO sequential 32-bit operations on the host, and without forced atomicity, threads can observe intermediate states (torn reads/writes).

## Environment

- **Host**: Allwinner H3 (armv7l, Cortex-A7, LPAE), 1GB RAM
- **OS**: Armbian (Linux 6.1.x)
- **QEMU baseline**: v9.2.4, cross-compiled armhf (32-bit), static
- **Test binary**: `torn64` (aarch64 static)

## Test Harness: torn64

Multi-threaded aarch64 test that:
1. Multiple threads write patterns (0x1111111111111111 or 0x2222222222222222) to a shared aligned u64
2. All threads read the value
3. ABORT if a read contains a value that is neither 0x1111... nor 0x2222... (indicates a torn intermediate state)
4. Counter: track cumulative iterations across all threads

Usage:
```bash
./torn64 <num_threads> <duration_sec> [target_iterations]
```

Examples:
- `./torn64 2 30`: 2 threads, 30 seconds
- `./torn64 4 0 1000000000`: 4 threads, run until 10^9 iterations

## Baseline Reproduction: Confirmed FAIL

Running `torn64` under QEMU v9.2.4 baseline (cross-compiled armhf static, `build-out/qemu-aarch64`)
reproduces a torn read within seconds, from the pad:

```bash
./test/run-pad.sh torn64 2 30
./test/run-pad.sh torn64 4 30
```

Result: **ABORT with torn read detected**, both with 2 and 4 threads:

```
ERROR: Torn read detected in thread 1: 0x1111111122222222
Final iterations: 41291
ABORTED: Torn read detected after 41291 iterations
```

The torn value `0x1111111122222222` is exactly a mix of the high half of PATTERN_A
(`0x11111111`) and the low half of PATTERN_B (`0x22222222`): direct evidence that TCG lowers
the guest's aligned 64-bit store into two separate 32-bit host stores, observable mid-write by
another thread. Confirms the root cause described in GOAL.md.

Log location: `test/logs/baseline/torn64-2threads-baseline.log`, `test/logs/baseline/torn64-4threads-baseline.log`

## Constraints (Pad Environment)

- Memory: 1GB, soft-capped at 600MB per test process
- CPU: 2 cores max (taskset -c 0,1)
- Temperature: throttle at 75°C, stop at 100°C
- Concurrency: Only one QEMU instance at a time (check pgrep qemu-aarch64)
- Deployment: docker build on macOS, SSH+SCP to pad for execution

## Success Criterion (Post-Fix)

After patches are applied, the same test must:
1. Run ≥30 minutes without torn reads (N=2)
2. Cumulative iterations ≥10^9 for N∈{2,4,8}
3. No memory corruption or segfaults

See `test/logs/fixa/` for post-fix logs.
