# qemu-64on32-smartpi

**The last living 64-on-32 qemu-user, correct AND fast.**

A fork of QEMU **9.2.4** that runs **multithreaded aarch64-linux-user** binaries on an
**armv7l** host (Cortex-A7 LPAE, Allwinner H3 class boards: SmartPi One, SmartPad,
Orange Pi...). QEMU >= 10.0 removed "64-bit guest on 32-bit host" support entirely;
9.2.4 is the last working base, but its user mode was officially broken there ("in user
mode atomicity was simply broken") and pathologically slow. This fork fixes both.

Validated on real workloads on an H3 (1 GHz, 1 GB RAM): the native **Grok CLI** TUI
(static Rust, crashes within 2-5 minutes under qemu 7.2) runs stable, and the native
**Claude Code** binary (Bun/JavaScriptCore, 247 MB, the most brutal stress test the
author knows of) boots and completes a full agent turn (init, TLS, API call, response,
clean exit).

## Measured results (H3, single core unless noted)

| Benchmark (native Claude Code guest) | vanilla qemu 9.2.4 | this fork |
|---|---|---|
| `--version` (runtime boot) | never finishes (>4 h, tb_flush storm) | **10 s** (6 s with persistent cache) |
| `--help` (full CLI init) | never finishes | **61 s** |
| `-p` (full agent turn, network + TLS, 2 cores) | never reached | **151 s**, result success |
| torn64 (atomic throughput, 4 threads / 180 s) | 64-bit torn reads (corruption) | **1.3 G iterations, 0 torn reads** |
| Native Grok CLI TUI | crashes in 2-5 min (7.2/8.x/9.x) | **stable >30 min** |

## Why it was slow, and what was fixed

The gains come from measured root causes (an execution-weighted profiler is built into
the fork), not micro-optimisations:

1. **64-bit atomicity (correctness)**: guest 64-bit accesses were lowered to two 32-bit
   host accesses, torn between threads. On Cortex-A7 LPAE, aligned LDRD/STRD are
   single-copy atomic: guaranteed inline emission, atomic helper otherwise
   (patches 0001-0002).
2. **Translation cache hardwired to 32 MiB**: any large guest runtime entered perpetual
   retranslation. Made configurable: `-tb-size` / `QEMU_TB_SIZE` (patch 0005).
3. **FEAT_LSE2 in the default CPU model**: every 16-byte aligned LDP/STP (the prologue
   of every single function!) required 16-byte atomicity that a 32-bit host cannot
   provide, causing ~17 million stop-the-world exclusive steps per boot. Hidden by
   default in 32-bit-host user mode, `QEMU_KEEP_LSE2=1` restores it (patch 0011).
   Measured gain: 8x.
4. **FEAT_BTI and SVE/SME advertised**: a helper call per indirect branch, and vector
   routines emulated instruction-by-instruction, slower than the NEON paths they
   replace. Hidden by default, `QEMU_KEEP_BTI=1` / `QEMU_KEEP_SVE=1` restore them
   (patch 0013).
5. **Indirect branch dispatch**: an inline jump-cache probe validated against
   translation-time constants replaces a roughly 40-instruction helper call
   (patch 0012).
6. **Persistent translation cache** (`-tb-cache <file>` / `QEMU_TB_CACHE`): 100 %
   reload of translated code between runs of the same binary (patch 0007).

Also included: termios2/TCGETS2 backport (required by Rust TUIs), a SIMD dup2_vec
lowering fix, two upstream cherry-picks (self-linked TB unlink fix, TSTNE optimisation),
and built-in profiling tools (`QEMU_OP_HISTOGRAM`, `QEMU_TB_EXEC_PROFILE`).

## Installation

### Prebuilt binary

See [Releases](../../releases): a static `qemu-aarch64` for armv7l, no dependencies.

```bash
chmod +x qemu-aarch64
./qemu-aarch64 --version
```

### Building from source

Builds run in docker (static armhf cross build), never on the target:

```bash
bash build/mkimage.sh        # build docker image (once)
bash build.sh                # artifact: build-out/qemu-aarch64
```

Or apply the `patches/` series onto a pristine QEMU v9.2.4 tree: `git am patches/*.patch`.

## Usage recipes

```bash
# Light binary (Rust CLI, tools): nothing to tune
./qemu-aarch64 ./my-aarch64-binary

# Large guest JIT runtime (Bun/Node/JSC/V8): big translation cache
QEMU_TB_SIZE=256 ./qemu-aarch64 ./big-binary

# Frequent relaunches of the same binary: persistent cache (deterministic layout required)
setarch $(uname -m) -R env QEMU_TB_SIZE=256 QEMU_TB_CACHE=/path/cache.bin \
  ./qemu-aarch64 ./big-binary

# Short one-shot of a JSC runtime: interpreter only (boots faster than the JIT)
QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 ./qemu-aarch64 ./bun-binary --version
# Long agent session: keep the guest JIT active (1.55x measured on a full turn)
```

On 1 GB boards: bound runs with `systemd-run --scope -p MemoryMax=600M` and `timeout`,
and watch the SoC temperature on heatsink-less boards.

## Repository contents

- `patches/`: the full series (16 atomic patches on v9.2.4, `git am`-ready)
- `build/` + `build.sh`: reproducible docker build (static armhf)
- `test/`: validation guests (torn64, simd-dup2, smc-alias, tcgets2...), board harness,
  proof logs for the results above
- `docs/METHODOLOGY.md`: the full journey, from diagnosis to measurements
- `docs/REPRO.md`, `docs/AUDIT-ldst.md`, `docs/AUDIT-simd-movi.md`: reproduction and audits

## Known limitations

- 128-bit exclusives (LDXP/STXP, CASP) stay on a stop-the-world path: correct but slow.
  Rare in practice once LSE2 is hidden.
- The `-strace` tracer can segfault on heavily multithreaded guests (bounded by
  patch 0008, not fully fixed): a debug tool, not the execution path.
- Ultra-short one-shots (~1 s) can be slightly faster under qemu 7.2 (simpler
  translator); this fork wins as soon as execution dominates, and 7.2 crashes on
  multithreaded guests.

## License

GPL-2.0, like QEMU. Upstream cherry-picks keep their original author attribution.
