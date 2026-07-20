# Methodology: making 64-on-32 user-mode atomically correct on armv7

This document records the method, the measures and the honest limits of the fork. It is the
delivery companion to the patch series in `patches/`. For the raw baseline reproduction see
`docs/REPRO.md`; for the two deep audits see `docs/AUDIT-ldst.md` (64-bit atomicity) and
`docs/AUDIT-simd-movi.md` (the SIMD lowering crash).

## 1. Scope and target

QEMU 9.2.4 is the last upstream release that still carries the 64-on-32 path (aarch64 guest on
a 32-bit host). QEMU 10.0 removed 1160 lines of it and 11.0 dropped the whole `tcg/arm`
backend, so 9.2.4 is the only sound base. The host is an Allwinner H3 (armv7l, Cortex-A7,
LPAE, 1 GB RAM). The validation targets are heavily threaded JIT runtimes: the grok TUI
binary (JavaScriptCore) and the native Claude Code binary (linux-arm64-musl, Bun/JSC).

The first goal was correctness; speed was explicitly out of scope for that phase. A later
batch then attacked boot speed specifically, once correctness was settled: see section 8.

## 2. Root cause analysis

Four independent problems were isolated. Each has its own reproducer and its own patch, and
each was proven separately (a fix for one does not mask the others).

1. Torn 64-bit guest accesses (the core subject). In user mode QEMU maps one guest thread to
   one real host thread; the round-robin scheduler is not compiled in. TCG lowers an ordinary
   aligned 64-bit guest load or store into two sequential 32-bit host accesses. A second
   thread can observe the intermediate state: a torn read. Upstream documents this as "in user
   mode atomicity was simply broken" (removed-features, commit acce728cbc6c). The hardware
   lever that makes a fix possible: on Cortex-A7 with LPAE, an aligned LDRD/STRD is
   single-copy-atomic (ARM ARM A3.5.3), and QEMU already has CONFIG_ATOMIC64 (ldrexd/strexd)
   on armv7. The primitive existed; the fast inline path just did not use it reliably.

2. SIMD lowering crash (exposed by the real workload, not by torn64). A `dup2_vec` TCG op with
   exactly one constant half (a common JIT pattern, for example broadcasting a 64-bit value
   whose high word is a constant) is neither folded by the optimizer (`fold_dup2` needs both
   halves constant) nor caught by the two fast paths of `tcg_reg_alloc_dup2`. It falls through
   to the generic path whose constraint `C_O1_I2(w, w, w)` is vector-only, so the whole
   constant is forced into a Q register and `tcg_out_movi(I32, Qreg)` aborts on the assertion
   `ret < TCG_REG_Q0`. This is 100 percent upstream 9.2.4 code and is independent of the
   atomicity fix. See `docs/AUDIT-simd-movi.md`.

3. Missing TCGETS2 ioctl (needed by the grok terminal). The termios2 ioctl family
   (TCGETS2/TCSETS2/TCSETSW2/TCSETSF2) only lands upstream in QEMU 11.0
   (commit e9a8a10e84c1, January 2026). On 9.2.4 the guest ioctl returns ENOTTY, which breaks
   terminal setup. Pure ioctl emulation, zero TCG surgery.

4. Self-modifying code through a dual W^X alias (the JSC / V8 / Bun trap). A JIT writes code
   through a writable alias of a page and executes it through a separate executable alias
   (memfd dual-map, to get around W^X). QEMU's SMC detection can miss writes made through the
   other virtual page. Investigation (batch B1) established that 9.2.4 already fixes this:
   `ic_ivau_write` (target/arm/helper.c) invalidates the translation blocks over the affected
   range via `tb_invalidate_phys_range`, and `CTR_EL0.DIC` is cleared (target/arm/cpu.c) to
   force JITs to emit IC IVAU. So a correct JIT is already safe on this base; no patch was
   needed, only characterization (a JIT that omits IC IVAU is unsafe, one that emits it is
   safe).

## 3. The patch series

`patches/` is `git format-patch v9.2.4..yumi-64on32`, six atomic commits, one subject each:

- `0001-tcg-arm-emit-LDRD-...`  guarantee a single LDRD for an aligned MO_64 guest load; force
  alignment 8 via `h->aa` so the unaligned case branches to the atomic slow-path helper
  (CONFIG_ATOMIC64).
- `0002-tcg-arm-emit-STRD-...`  same guarantee for an aligned MO_64 guest store.
- `0003-linux-user-backport-termios2-...`  backport of the termios2 ioctl family, adapted from
  upstream e9a8a10e84c1 to the 9.2.4 linux-user tree (ioctls.h, syscall.c conversion, strace
  print, syscall_types.h, user-internals.h).
- `0004-tcg-arm-lower-dup2_vec-...`  fix the one-half-constant `dup2_vec` case by changing the
  fallback constraint to `C_O1_I2(w, r, r)` and lowering through a core-register to
  doubleword `VMOV`, so the fallback path is correct instead of aborting. The two existing
  fast paths of `tcg_reg_alloc_dup2` are untouched.
- `0005-linux-user-make-the-translation-cache-size-configura...`  wire a `-tb-size` option and
  the `QEMU_TB_SIZE` environment variable (MiB) to the existing tb-size accel property, and
  let the static-buffer allocator serve larger requests with a dedicated anonymous mapping.
  Boot-speed batch, see section 8. Default behaviour unchanged.
- `0006-accel-tcg-report-tb_flush-on-stderr...`  one stderr line per tb_flush when
  `QEMU_TB_FLUSH_LOG` is set (the counter is otherwise only reachable from the system-mode
  monitor). Diagnostic for sizing the translation cache.

The series applies cleanly and in order on a pristine v9.2.4 checkout; see section 6.

## 4. Build methodology

The build never runs on the pad (1 GB RAM). It runs in Docker (via colima) on the Mac:

- Image `qemu64on32-build` (`build/Dockerfile`): base `arm64v8/debian:bookworm`, armhf
  multiarch, cross toolchain (`crossbuild-essential-armhf`), static glib for armhf, meson,
  ninja, and `gcc-aarch64-linux-gnu` for the aarch64 test guests.
- `build.sh` configures QEMU with `--cross-prefix=arm-linux-gnueabihf- --static
  --target-list=aarch64-linux-user --disable-docs --disable-tools --disable-werror`, builds,
  and copies the artifact to `build-out/qemu-aarch64` (ELF 32-bit ARM, static).
- macOS cannot run the produced Linux ELF, so every execution test happens on the pad.

## 5. Test methodology and measures

Tests run on the pad under strict limits: `taskset -c 0,1` (2 cores), `systemd-run --scope -p
MemoryMax=600M`, a `timeout`, temperature read before and after each run (throttle at 75C,
freeze near 100C), and one QEMU at a time (`pgrep -x qemu-aarch64`). `test/run-pad.sh` centralizes
this; the pad address and credentials live only in `test/pad.env`.

Isolated reproducers, each red on baseline then green on the fork:

- `torn64` (Fix A). Baseline v9.2.4: torn read within seconds, at 41291 iterations (N=2), value
  `0x1111111122222222` (high half of one pattern mixed with the low half of the other): direct
  proof of the two-32-bit-store lowering. Fork stress (batch A5): N in {2,4,8}, each 600 s, 30
  minutes cumulative, about 549.7 M iterations total (187.9 M + 177.2 M + 184.5 M), 0 torn
  reads, no crash. Non-regression re-runs on the final binary: 62.98 M iterations in 180 s and
  55.97 M in 180 s, 0 torn. An unaligned variant does not crash (the requirement for unaligned
  is no crash, not no tearing: real aarch64 guarantees nothing for an unaligned 64-bit access).
  Logs: `test/logs/baseline/`, `test/logs/fixa/`.
- `simd-dup2` (patch 0004). Baseline v9.2.4 and pre-fix fork: SIGABRT
  `tcg_out_movi: Assertion 'ret < TCG_REG_Q0'`. Post-fix: green, and the test checks the
  computed value (both lanes equal `(seed<<32)|0xff`), not merely the absence of a crash, so a
  wrong VMOV encoding would be caught. Logs: `test/logs/simd/`.
- `tcgets2` (patch 0003). Without the patch the guest ioctl returns ENOTTY; with the patch it
  returns 0 (the strict criterion, ENOTTY is not ENOSYS, so a loose "not ENOSYS" test would
  have passed even unpatched and proven nothing).
- `smc-alias` (Fix B characterization). Mode `nosync` (JIT omits IC IVAU): red, stale code
  executed. Mode `sync` (JIT emits IC IVAU, the correct behavior): green, fresh code every
  round. Logs: `test/logs/smc/`.

Real-workload validation:

- grok under the fork: 20 minutes (1207 s) of real JIT with no SIMD assertion and no SIGABRT
  (before patch 0004 the same load aborted in 2 to 5 minutes). This validates patch 0004 on the
  actual workload, not just the micro-reproducer. The run then stalled without producing agent
  output; see the limits below.

## 6. Applying the series (delivery check)

On a pristine v9.2.4 checkout the four patches apply cleanly and in order, and the result is
byte-identical to the `yumi-64on32` branch:

```
git clone --branch v9.2.4 https://gitlab.com/qemu-project/qemu.git
cd qemu
git apply --check ../patches/*.patch     # dry-run, exit 0
git am ../patches/*.patch                # applies all four, exit 0
```

Because patches 0001, 0002 and 0004 all touch `tcg/arm/tcg-target.c.inc`, apply them in order
(the `0001..0004` numbering is the order). `git am` applies them sequentially and is the
definitive check.

## 7. Honest limits

- Raw emulation speed remains 8x to 20x slower than native and the pad throttles at 75C.
  The boot-speed batch (section 8) removed the pathological part (translation cache
  thrashing and guest JIT churn), not the structural interpretation cost.
- V1 (grok, 30 minutes of real content) is not closed. Two blockers remain, both outside the
  code: a stall (indeterminate between structural emulation slowness, which the GOAL rules out
  of scope, and a post-init block to be settled by a longer or `-strace` run), and an external
  one, the Grok Build account balance is exhausted (HTTP 402), which is a human gate. The SIMD
  crash that used to end the run is fixed and validated on 20 minutes of real workload.
- V2 (native Claude Code boot under the fork) is pending; it benefits from patch 0004 and is
  the real JSC/Bun target.
- Unaligned 64-bit guest accesses are handled for correctness only (no crash), routed to the
  atomic slow-path helper, not optimized.
- 128-bit STXP/LDXP (emitted by JSC) take the stop-the-world exclusive path on armv7
  (HAVE_CMPXCHG128 is false). Correct but slow, deliberately untouched.

## 8. Boot acceleration (translation cache and guest JIT)

Once correctness was settled, a dedicated batch attacked the boot time of the native Claude
Code binary (Bun/JSC, 247 MB) under the fork. The observed slowdown was pathological, not
linear: a native arm64 boot takes 1 to 3 seconds, yet under the fork `--version` never
completed and a `-p` run stayed silent for 4 hours. Two compounding root causes:

1. Translation cache far too small. On a 32-bit host in user mode the code generation buffer
   is a builtin static array of 32 MiB (`tcg/region.c`, `USE_STATIC_CODE_GEN_BUFFER`), a
   single region, bump allocation, no reclamation before a full `tb_flush`. With an 8x to 15x
   TCG expansion factor the boot working set overflows 32 MiB many times over: every overflow
   throws away every translation and the whole working set is retranslated, in a loop.
   Nothing in qemu-user exposed the existing tb-size accel property, and the static buffer
   clamped any request anyway.
2. Guest JIT churn. The JSC JIT emits guest code continuously. Self-modifying guest code
   means IC IVAU, TB invalidation and retranslation, and the fresh code fills the small
   buffer even faster (invalidated TB space is never reused before a full flush).

The fix is patches 0005 and 0006 host-side (see section 3) plus environment-only guest-side
configuration: `BUN_JSC_useJIT=0` (bun-compiled binaries read `BUN_JSC_*`; this is the JSC
master switch: LLInt interpreter only, wasm through the IPInt interpreter, no executable
guest pages at all, hence zero self-modifying guest code), with `BUN_JSC_useConcurrentGC=0`
and `BUN_JSC_numberOfGCMarkers=1` to quiet the GC threads. `BUN_JSC_dumpOptions=1` proves the
options landed (the run prints `useJIT=false`). The official binary is built with
`--bytecode`, so parsing was already prepaid; the JIT was the last large guest-side cost.

Measured on the pad (single core, `MemoryMax=750M`, cold start, `test/run-claude-pad.sh`):

| Configuration | `claude --version` |
|---|---|
| baseline (32 MiB cache, JIT on) | never completed (360 s timeout; `-p` silent after 4 h on 4 cores) |
| `QEMU_TB_SIZE=256` + `BUN_JSC_useJIT=0` + quiet GC | BOOTED, rc=0, 513 s, one tb_flush in total, peak 43C |

Recommended invocation on the pad:

```
QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1 \
  ./qemu-aarch64 -L sysroot ./claude-native ...
```

The harness exposes this as `CLAUDE_EXTRA_ENV` (space-separated NAME=VAL pairs appended to
the qemu environment). A `-p` agent turn runs a much longer code path than boot and is
measured separately; see the PROGRESS journal for the current numbers.
