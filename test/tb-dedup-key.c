/*
 * Host-native unit test for the tb-dedup content key helpers.
 *
 * These helpers are the single source of truth for the dedup key shared by the
 * recon profile and the (later) install index; if the two ever diverge the
 * index would install a template under a key that the measurement never saw.
 * This test pins the recipe: known vectors, the 0-sentinel guarantee, and
 * field sensitivity (a change in any identity field must move the net key).
 *
 * Builds and runs on the Mac with a plain host cc, no qemu, no docker.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "../qemu/include/exec/tb-dedup.h"

static int failures;

static void check(const char *what, int ok)
{
    printf("%-52s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) {
        failures++;
    }
}

/* Reference FNV-1a, computed independently of the header, over a fixed input. */
static uint64_t ref_src(const uint8_t *p, size_t n, uint32_t size)
{
    uint64_t h = 1469598103934665603ULL;
    size_t i;
    for (i = 0; i < n; i++) {
        h = (h ^ p[i]) * 1099511628211ULL;
    }
    h ^= (uint64_t)size << 1;
    return h ? h : 1;
}

int main(void)
{
    const uint8_t bytes[] = { 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
    size_t n = sizeof(bytes);

    /* 1. src key matches an independent reference implementation. */
    uint64_t src = tb_dedup_src_key(bytes, n, (uint32_t)n);
    check("src key matches reference FNV-1a", src == ref_src(bytes, n, n));

    /* 2. length is folded: same bytes, different declared size -> different. */
    check("src key folds the byte length",
          tb_dedup_src_key(bytes, n, (uint32_t)n) !=
          tb_dedup_src_key(bytes, n, (uint32_t)n + 1));

    /* 3. net key is sensitive to each identity field independently. */
    uint64_t net = tb_dedup_net_key(src, 0xaaaa, 0x10, 0);
    check("net differs when flags change",
          net != tb_dedup_net_key(src, 0xaaab, 0x10, 0));
    check("net differs when cflags change",
          net != tb_dedup_net_key(src, 0xaaaa, 0x11, 0));
    check("net differs when cs_base changes",
          net != tb_dedup_net_key(src, 0xaaaa, 0x10, 1));

    /* 4. netpc key is sensitive to the page offset. */
    uint64_t netpc = tb_dedup_netpc_key(net, 0x100);
    check("netpc differs when page offset changes",
          netpc != tb_dedup_netpc_key(net, 0x200));

    /* 5. the 0 sentinel is never returned, even from a 0 preimage. */
    check("src key never 0", tb_dedup_src_key((const uint8_t *)"", 0, 0) != 0);
    check("net key never 0", tb_dedup_net_key(0, 0, 0, 0) != 0);
    check("netpc key never 0", tb_dedup_netpc_key(0, 0) != 0);

    /* 6. identical inputs are deterministic (a hit must be reproducible). */
    check("keys are deterministic",
          tb_dedup_src_key(bytes, n, (uint32_t)n) == src &&
          tb_dedup_net_key(src, 1, 2, 3) == tb_dedup_net_key(src, 1, 2, 3));

    /*
     * 7. movw/movt imm16 codec matches the real armv7 encoding.  The two words
     * below are copied verbatim from a live host dump (movw r4,#0xc678 ;
     * movt r4,#0x194, baking guest PC 0x0194c678 in test/logs/dump-tb/
     * hot-tbs-llint.dump): the codec must read that value back and, once the
     * imm fields are stripped, must NOT alter any other bit of the instruction.
     */
    const uint32_t movw_dump = 0xe30c4678u; /* movw r4, #0xc678 */
    const uint32_t movt_dump = 0xe3404194u; /* movt r4, #0x194  */
    check("movw imm16 decode matches the dump",
          tb_dedup_movw_get_imm16(movw_dump) == 0xc678);
    check("movt imm16 decode matches the dump",
          tb_dedup_movw_get_imm16(movt_dump) == 0x194);
    check("imm16 set/get round trips the low half",
          tb_dedup_movw_get_imm16(tb_dedup_movw_set_imm16(movw_dump, 0xbeef))
          == 0xbeef);
    check("imm16 set leaves the non-imm bits untouched",
          (tb_dedup_movw_set_imm16(movw_dump, 0xbeef) & ~0x000f0fffu)
          == (movw_dump & ~0x000f0fffu));

    /*
     * 8. patch/read a full 32-bit baked value across the pair.  A hit installer
     * must be able to rewrite the template's guest PC / TB pointer in place and
     * read the exact value back, for every corner of the 32-bit range.
     */
    const uint32_t vals[] = { 0x0194c678u, 0x00000000u, 0xffffffffu,
                              0xa6ac3dc1u, 0x0000ffffu, 0xffff0000u };
    int pair_ok = 1;
    for (size_t i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
        uint32_t pair[2] = { movw_dump, movt_dump };
        tb_dedup_patch_pair(pair, vals[i]);
        if (tb_dedup_read_pair(pair) != vals[i]) {
            pair_ok = 0;
        }
        /* rd field ([15:12]) and opcode must survive the patch */
        if ((pair[0] & ~0x000f0fffu) != (movw_dump & ~0x000f0fffu) ||
            (pair[1] & ~0x000f0fffu) != (movt_dump & ~0x000f0fffu)) {
            pair_ok = 0;
        }
    }
    check("patch/read round trips the full 32-bit value", pair_ok);

    /*
     * 9. the FIXED-pair insn builders reproduce the real dump words bit for bit
     * (movw r4,#0xc678 / movt r4,#0x194), so the dedup emitter lays down exactly
     * the encoding tcg_out_movi32 would, and the recorded value reads back.
     */
    check("movw insn builder reproduces the dump word",
          tb_dedup_movw_insn(0xe, 4, 0xc678) == movw_dump);
    check("movt insn builder reproduces the dump word",
          tb_dedup_movt_insn(0xe, 4, 0x194) == movt_dump);
    int fixed_ok = 1;
    for (size_t i = 0; i < sizeof(vals) / sizeof(vals[0]); i++) {
        uint32_t pair[2] = {
            tb_dedup_movw_insn(0xe, 0, (uint16_t)vals[i]),
            tb_dedup_movt_insn(0xe, 0, (uint16_t)(vals[i] >> 16)),
        };
        if (tb_dedup_read_pair(pair) != vals[i]) {
            fixed_ok = 0;
        }
    }
    check("fixed pair bakes every 32-bit value read-backable", fixed_ok);

    /*
     * 10. install-side relocation apply: verify-then-rebase one pair in a
     * memcpy'd copy.  This is the exact operation the hit installer performs
     * per recorded reloc, so it is pinned here against the shared header.
     */
    {
        /* A template block: two movw/movt pairs plus filler, as a hit copy. */
        uint32_t tmpl_pc = 0x0194c678u;      /* baked guest PC low half   */
        uint32_t tmpl_tb = 0xa6ac3dc1u;      /* baked exit_tb TB pointer  */
        uint32_t block[6];
        block[0] = tb_dedup_movw_insn(0xe, 4, (uint16_t)tmpl_pc);
        block[1] = tb_dedup_movt_insn(0xe, 4, (uint16_t)(tmpl_pc >> 16));
        block[2] = 0xe1a00000u;              /* nop-ish filler (mov r0,r0) */
        block[3] = tb_dedup_movw_insn(0xe, 0, (uint16_t)tmpl_tb);
        block[4] = tb_dedup_movt_insn(0xe, 0, (uint16_t)(tmpl_tb >> 16));
        block[5] = 0xe1a00000u;

        TbDedupReloc r_pc = { 0, TB_RELOC_GUEST_PC, tmpl_pc, 0 };
        TbDedupReloc r_tb = { 3 * sizeof(uint32_t), TB_RELOC_EXIT_TB, tmpl_tb, 0 };

        uint32_t new_pc = 0x03210000u;
        uint32_t new_tb = 0xb7005dc1u;
        int apply_ok = 1;

        apply_ok &= tb_dedup_reloc_apply(block, &r_pc,
                                         (int64_t)new_pc - (int64_t)tmpl_pc);
        apply_ok &= tb_dedup_reloc_apply(block, &r_tb,
                                         (int64_t)new_tb - (int64_t)tmpl_tb);
        apply_ok &= (tb_dedup_read_pair(&block[0]) == new_pc);
        apply_ok &= (tb_dedup_read_pair(&block[3]) == new_tb);
        /* filler and rd/opcode bits must be untouched */
        apply_ok &= (block[2] == 0xe1a00000u && block[5] == 0xe1a00000u);
        apply_ok &= ((block[0] & ~0x000f0fffu) ==
                     (tb_dedup_movw_insn(0xe, 4, 0) & ~0x000f0fffu));
        check("reloc apply rebases both kinds in place", apply_ok);

        /*
         * zero delta on a FRESH copy (still holding the template value) is a
         * verified no-op: identical-address reuse patches nothing but must
         * still pass the byte-exact check.
         */
        uint32_t fresh[2] = {
            tb_dedup_movw_insn(0xe, 4, (uint16_t)tmpl_pc),
            tb_dedup_movt_insn(0xe, 4, (uint16_t)(tmpl_pc >> 16)),
        };
        check("reloc apply with zero delta keeps the value",
              tb_dedup_reloc_apply(fresh, &r_pc, 0) &&
              tb_dedup_read_pair(fresh) == tmpl_pc);
    }

    /*
     * 11. a stale/collided reloc (recorded value no longer in the copy) must be
     * rejected so the installer aborts the hit rather than patch wrong bytes.
     */
    {
        uint32_t pair[2] = {
            tb_dedup_movw_insn(0xe, 0, 0x1234),
            tb_dedup_movt_insn(0xe, 0, 0x5678),
        };
        TbDedupReloc wrong = { 0, TB_RELOC_EXIT_TB, 0xdeadbeefu, 0 };
        uint32_t before0 = pair[0], before1 = pair[1];
        check("reloc apply rejects a value mismatch",
              !tb_dedup_reloc_apply(pair, &wrong, 0x10));
        check("reloc apply leaves bytes untouched on mismatch",
              pair[0] == before0 && pair[1] == before1);
    }

    /*
     * 12. byte-exact source match, the zero-collision guard the index applies
     * before treating two same-net-key TBs as one template.  Equal bytes match;
     * any byte difference or length difference must NOT match, so a hash
     * collision can never install one template's host code for another's bytes.
     */
    {
        const uint8_t a[] = { 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02 };
        const uint8_t b[] = { 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02 };
        const uint8_t c[] = { 0xde, 0xad, 0xbe, 0xef, 0x01, 0x03 };
        check("src match: identical bytes match",
              tb_dedup_src_match(a, sizeof(a), b, sizeof(b)));
        check("src match: one byte differs -> no match",
              !tb_dedup_src_match(a, sizeof(a), c, sizeof(c)));
        check("src match: shorter length -> no match",
              !tb_dedup_src_match(a, sizeof(a), b, sizeof(b) - 1));
        check("src match: zero length matches zero length",
              tb_dedup_src_match(a, 0, c, 0));
    }

    /*
     * 13. per-kind delta selection: the installer derives ONE guest-PC delta
     * and ONE exit_tb delta per hit and lets tb_dedup_reloc_delta pick the
     * right one for each reloc.  A GUEST_PC reloc must take the PC delta, an
     * EXIT_TB reloc the TB-pointer delta, and any other kind zero.
     */
    {
        int64_t pc_d = 0x1000;
        int64_t tb_d = -0x40;
        TbDedupReloc r_pc  = { 0, TB_RELOC_GUEST_PC, 0, 0 };
        TbDedupReloc r_tb  = { 0, TB_RELOC_EXIT_TB,  0, 0 };
        TbDedupReloc r_bad = { 0, TB_RELOC_NONE,     0, 0 };
        check("reloc delta picks the guest-pc delta",
              tb_dedup_reloc_delta(&r_pc, pc_d, tb_d) == pc_d);
        check("reloc delta picks the exit-tb delta",
              tb_dedup_reloc_delta(&r_tb, pc_d, tb_d) == tb_d);
        check("reloc delta is zero for an unknown kind",
              tb_dedup_reloc_delta(&r_bad, pc_d, tb_d) == 0);
    }

    /*
     * 13b. an ADRP page base is a STEP function of the guest PC, so a
     * GUEST_PC_PAGE reloc must NOT take the plain PC delta.  It moves only when
     * its own site crosses a 4 KiB boundary, and by whole pages when it does --
     * this is exactly the case that produced the last two probe mismatches (a
     * template moved by -208 / +592 bytes INSIDE one page, where the correct
     * rebase is zero).
     */
    {
        uint32_t site = 0x410520u;              /* 0x410520 & ~0xfff == 0x410000 */
        TbDedupReloc r = { 0, TB_RELOC_GUEST_PC_PAGE, 0, site };

        check("page reloc does not move when the site stays in its page",
              tb_dedup_reloc_delta(&r, -208, 0) == 0);
        check("page reloc does not move for a forward intra-page shift",
              tb_dedup_reloc_delta(&r, 592, 0) == 0);
        check("page reloc moves by whole pages when the site crosses one",
              tb_dedup_reloc_delta(&r, 0x1000, 0) == 0x1000);
        check("page reloc rounds a crossing shift down to the page",
              tb_dedup_reloc_delta(&r, 0xae0 + 0x20, 0) == 0x1000);
        check("page reloc moves backwards when the site falls to a lower page",
              tb_dedup_reloc_delta(&r, -0x521, 0) == -0x1000);
    }

    /*
     * 14. full template rebase, the exact inner loop of the hit installer: a
     * template block holds a baked guest PC and a baked TB pointer at recorded
     * offsets.  A hit at a new guest PC and a new TB pointer memcpy's the block,
     * derives the two scalar deltas once, and applies tb_dedup_reloc_delta per
     * reloc.  Both baked words must land on the NEW values, filler untouched.
     */
    {
        uint32_t tmpl_pc = 0x0194c678u;
        uint32_t tmpl_tb = 0xa6ac3dc1u;
        uint32_t tmpl[6];
        tmpl[0] = tb_dedup_movw_insn(0xe, 4, (uint16_t)tmpl_pc);
        tmpl[1] = tb_dedup_movt_insn(0xe, 4, (uint16_t)(tmpl_pc >> 16));
        tmpl[2] = 0xe1a00000u;
        tmpl[3] = tb_dedup_movw_insn(0xe, 0, (uint16_t)tmpl_tb);
        tmpl[4] = tb_dedup_movt_insn(0xe, 0, (uint16_t)(tmpl_tb >> 16));
        tmpl[5] = 0xe1a00000u;

        TbDedupReloc relocs[2] = {
            { 0,                   TB_RELOC_GUEST_PC, tmpl_pc, 0 },
            { 3 * sizeof(uint32_t), TB_RELOC_EXIT_TB, tmpl_tb, 0 },
        };

        uint32_t new_pc = 0x03210000u;
        uint32_t new_tb = 0xb7005dc1u;

        /* the installer's steps: copy, derive deltas once, patch per reloc */
        uint32_t copy[6];
        memcpy(copy, tmpl, sizeof(tmpl));
        int64_t pc_delta = (int64_t)new_pc - (int64_t)tmpl_pc;
        int64_t tb_delta = (int64_t)new_tb - (int64_t)tmpl_tb;

        int install_ok = 1;
        for (size_t i = 0; i < 2; i++) {
            install_ok &= tb_dedup_reloc_apply(
                copy, &relocs[i],
                tb_dedup_reloc_delta(&relocs[i], pc_delta, tb_delta));
        }
        install_ok &= (tb_dedup_read_pair(&copy[0]) == new_pc);
        install_ok &= (tb_dedup_read_pair(&copy[3]) == new_tb);
        install_ok &= (copy[2] == 0xe1a00000u && copy[5] == 0xe1a00000u);
        check("installer loop rebases a full template copy", install_ok);

        /* the template itself must be untouched: a second hit reuses it */
        check("installer leaves the template untouched",
              memcmp(tmpl, copy, sizeof(tmpl)) != 0 &&
              tb_dedup_read_pair(&tmpl[0]) == tmpl_pc &&
              tb_dedup_read_pair(&tmpl[3]) == tmpl_tb);
    }

    /*
     * 15. the encapsulated installer core tb_dedup_install_relocs: the same
     * rebase as test 14 but through the one function the hot installer will
     * call, so the loop (delta-select + verify-apply) is pinned in one place.
     * A clean copy rebases and returns true; a template with a corrupted word
     * (a hash collision that slipped the byte-exact guard) must return false so
     * the caller discards the copy instead of running wrong bytes.
     */
    {
        uint32_t tmpl_pc = 0x0194c678u;
        uint32_t tmpl_tb = 0xa6ac3dc1u;
        uint32_t tmpl[5];
        tmpl[0] = tb_dedup_movw_insn(0xe, 4, (uint16_t)tmpl_pc);
        tmpl[1] = tb_dedup_movt_insn(0xe, 4, (uint16_t)(tmpl_pc >> 16));
        tmpl[2] = 0xe1a00000u;
        tmpl[3] = tb_dedup_movw_insn(0xe, 0, (uint16_t)tmpl_tb);
        tmpl[4] = tb_dedup_movt_insn(0xe, 0, (uint16_t)(tmpl_tb >> 16));

        TbDedupReloc relocs[2] = {
            { 0,                   TB_RELOC_GUEST_PC, tmpl_pc, 0 },
            { 3 * sizeof(uint32_t), TB_RELOC_EXIT_TB, tmpl_tb, 0 },
        };
        uint32_t new_pc = 0x03210000u;
        uint32_t new_tb = 0xb7005dc1u;
        int64_t pc_delta = (int64_t)new_pc - (int64_t)tmpl_pc;
        int64_t tb_delta = (int64_t)new_tb - (int64_t)tmpl_tb;

        uint32_t copy[5];
        memcpy(copy, tmpl, sizeof(tmpl));
        check("install_relocs rebases every reloc and reports success",
              tb_dedup_install_relocs(copy, relocs, 2, pc_delta, tb_delta) &&
              tb_dedup_read_pair(&copy[0]) == new_pc &&
              tb_dedup_read_pair(&copy[3]) == new_tb &&
              copy[2] == 0xe1a00000u);

        /* n == 0: a memcpy-only template patches nothing but still succeeds. */
        uint32_t none[1] = { 0xe1a00000u };
        check("install_relocs with no relocs succeeds untouched",
              tb_dedup_install_relocs(none, relocs, 0, pc_delta, tb_delta) &&
              none[0] == 0xe1a00000u);

        /* a corrupted first word fails the byte-exact guard -> abort. */
        uint32_t bad[5];
        memcpy(bad, tmpl, sizeof(tmpl));
        bad[0] = tb_dedup_movw_insn(0xe, 4, 0x0000);   /* wrong baked value */
        check("install_relocs aborts on a corrupted template word",
              !tb_dedup_install_relocs(bad, relocs, 2, pc_delta, tb_delta));
    }

    /*
     * 16. tb_dedup_install_copy: the pure copy+rebase core the hit installer
     * calls with the destination code buffer.  It memcpy's the whole template
     * block (host code THEN appended unwind bytes, one contiguous region) into a
     * fresh destination, rebases the code-region relocs, and reports success.
     * The unwind tail must be copied verbatim (block-relative offsets travel
     * unchanged), an undersized destination must abort before touching relocs,
     * and a corrupted template word must abort the whole install.
     */
    {
        uint32_t tmpl_pc = 0x0194c678u;
        uint32_t tmpl_tb = 0xa6ac3dc1u;
        /* 5 code words then 2 words standing in for the unwind stream tail. */
        uint32_t tmpl[7];
        tmpl[0] = tb_dedup_movw_insn(0xe, 4, (uint16_t)tmpl_pc);
        tmpl[1] = tb_dedup_movt_insn(0xe, 4, (uint16_t)(tmpl_pc >> 16));
        tmpl[2] = 0xe1a00000u;
        tmpl[3] = tb_dedup_movw_insn(0xe, 0, (uint16_t)tmpl_tb);
        tmpl[4] = tb_dedup_movt_insn(0xe, 0, (uint16_t)(tmpl_tb >> 16));
        tmpl[5] = 0xdead0001u;                 /* unwind tail, must be copied */
        tmpl[6] = 0xdead0002u;

        size_t total = sizeof(tmpl);           /* code + unwind tail */

        TbDedupReloc relocs[2] = {
            { 0,                   TB_RELOC_GUEST_PC, tmpl_pc, 0 },
            { 3 * sizeof(uint32_t), TB_RELOC_EXIT_TB, tmpl_tb, 0 },
        };
        uint32_t new_pc = 0x03210000u;
        uint32_t new_tb = 0xb7005dc1u;
        int64_t pc_delta = (int64_t)new_pc - (int64_t)tmpl_pc;
        int64_t tb_delta = (int64_t)new_tb - (int64_t)tmpl_tb;

        uint32_t dest[7];
        memset(dest, 0, sizeof(dest));
        check("install_copy copies block, rebases relocs, keeps unwind tail",
              tb_dedup_install_copy(dest, sizeof(dest), tmpl, total,
                                    relocs, 2, pc_delta, tb_delta) &&
              tb_dedup_read_pair(&dest[0]) == new_pc &&
              tb_dedup_read_pair(&dest[3]) == new_tb &&
              dest[2] == 0xe1a00000u &&
              dest[5] == 0xdead0001u && dest[6] == 0xdead0002u);

        /* destination too small: abort before writing anything usable. */
        uint32_t small[3];
        check("install_copy aborts when the destination is too small",
              !tb_dedup_install_copy(small, sizeof(small), tmpl, total,
                                     relocs, 2, pc_delta, tb_delta));

        /* corrupted template word: byte-exact guard aborts the install. */
        uint32_t bad_tmpl[7];
        memcpy(bad_tmpl, tmpl, sizeof(tmpl));
        bad_tmpl[0] = tb_dedup_movw_insn(0xe, 4, 0x0000);  /* wrong baked value */
        uint32_t bad_dest[7];
        check("install_copy aborts on a corrupted template word",
              !tb_dedup_install_copy(bad_dest, sizeof(bad_dest), bad_tmpl, total,
                                     relocs, 2, pc_delta, tb_delta));

        /* the template block itself is never mutated by an install. */
        check("install_copy leaves the template untouched",
              tb_dedup_read_pair(&tmpl[0]) == tmpl_pc &&
              tb_dedup_read_pair(&tmpl[3]) == tmpl_tb &&
              tmpl[5] == 0xdead0001u);
    }

    /*
     * 17. tb_dedup_prefix_key: the PRE-translation lookup key.  A hot install
     * has to pick its candidate before the frontend has decided where the block
     * ends, so this key may only depend on what tb_gen_code holds at entry: the
     * identity fields and the first guest instruction.  Pinned here is that
     * contract and its deliberate weakness: two blocks sharing a first
     * instruction MUST land in the same bucket (what makes a pre-translation
     * lookup possible at all), while every field the net key separates on must
     * still separate the prefix key.
     */
    {
        /* Same first instruction, divergent afterwards: same bucket. */
        const uint8_t short_blk[] = { 0x00, 0x00, 0x00, 0x90 };
        const uint8_t long_blk[]  = { 0x00, 0x00, 0x00, 0x90,
                                      0xc0, 0x03, 0x5f, 0xd6 };
        uint64_t pk = tb_dedup_prefix_key(short_blk, sizeof(short_blk),
                                          0xaaaa, 0x10, 0);

        check("prefix key ignores bytes past the first instruction",
              pk == tb_dedup_prefix_key(long_blk, sizeof(long_blk),
                                        0xaaaa, 0x10, 0));

        /*
         * The two blocks that share a bucket have DIFFERENT net keys: the
         * bucket is a hypothesis, the net key stays the authority.
         */
        check("same prefix bucket still yields different net keys",
              tb_dedup_net_key(tb_dedup_src_key(short_blk, sizeof(short_blk),
                                                sizeof(short_blk)),
                               0xaaaa, 0x10, 0) !=
              tb_dedup_net_key(tb_dedup_src_key(long_blk, sizeof(long_blk),
                                                sizeof(long_blk)),
                               0xaaaa, 0x10, 0));

        /* A different first instruction must not share the bucket. */
        const uint8_t other[] = { 0x01, 0x00, 0x00, 0x90 };
        check("prefix key differs when the first instruction differs",
              pk != tb_dedup_prefix_key(other, sizeof(other),
                                        0xaaaa, 0x10, 0));

        /*
         * A short read at a page edge folds its own count, so a truncated
         * prefix never selects candidates whose tail byte it never saw.
         */
        check("prefix key folds the readable byte count",
              pk != tb_dedup_prefix_key(short_blk, 3, 0xaaaa, 0x10, 0));

        /* Identity fields separate the buckets exactly as they do net keys. */
        check("prefix key differs when flags change",
              pk != tb_dedup_prefix_key(short_blk, sizeof(short_blk),
                                        0xaaab, 0x10, 0));
        check("prefix key differs when cflags change",
              pk != tb_dedup_prefix_key(short_blk, sizeof(short_blk),
                                        0xaaaa, 0x11, 0));
        check("prefix key differs when cs_base changes",
              pk != tb_dedup_prefix_key(short_blk, sizeof(short_blk),
                                        0xaaaa, 0x10, 1));

        /* Sentinel and determinism, the same guarantees as the other keys. */
        check("prefix key never 0",
              tb_dedup_prefix_key((const uint8_t *)"", 0, 0, 0, 0) != 0);
        check("prefix key is deterministic",
              pk == tb_dedup_prefix_key(short_blk, sizeof(short_blk),
                                        0xaaaa, 0x10, 0));
    }

    if (failures) {
        printf("\ntb-dedup-key: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("\ntb-dedup-key: all checks passed\n");
    return 0;
}
