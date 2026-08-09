#!/usr/bin/env python3
# R1, classement des symboles perf en buckets d'attribution ponderes execution.
# Lit un rapport `perf report --stdio -F overhead,dso,symbol --percent-limit 0` et
# somme le temps (% ponderes execution) par bucket, pour la table de docs/PROFILE-HOTSPOTS.md.
#
# Buckets (mappent les categories exigees par R1 + le split translator/dispatch qui
# est le constat) :
#   translated  = code invite traduit (JIT), DSO [JIT]
#   translator  = TCG codegen (traduction : liveness/optimize/regalloc/emit/frontend)
#   dispatch    = coeur boucle d'execution + lookup de TB (cpu_exec/tb_lookup/...)
#   helpers     = helpers d'instruction invite (helper_* semantiques, softmmu ld/st/atomic)
#   runtime     = libc/alloc/glib + I/O du perfmap (memset/vfprintf/malloc/...)
#   kernel      = [kernel.kallsyms]
#   other       = ld-linux, [unknown], vdso
#
# Usage : bucket-perf.py <rapport.symfull> [--top N]
import re, sys

LINE = re.compile(r'^\s*([\d.]+)%\s+(.+?)\s+\[[.kgu]\]\s+(.+?)\s*$')

# Prefixes/noms explicites du TRADUCTEUR TCG (invoques par tb_gen_code).
TRANSLATOR_PREFIX = (
    'liveness_pass', 'la_', 'tcg_gen_code', 'tcg_optimize', 'tcg_reg_alloc',
    'tcg_out_', 'tcg_op_alloc', 'tcg_emit_op', 'tcg_temp', 'temp_load',
    'temp_free', 'temp_sync', 'temp_save', 'temp_dead', 'init_ts_info',
    'finish_folding', 'fold_', 'disas_a64', 'aarch64_tr_', 'translator_',
    'tb_gen_code', 'trans_', 'gen_', 'tcg_gen_', 'tcg_func_start',
    'tcg_region_', 'process_op_defs', 'tcg_out_movi', 'tcgv_', 'arg_temp',
    'reachable_code_pass', 'tcg_gen_op', 'tcg_op_remove', 'tcg_op_insert',
    'sextract', 'deposit', 'tcg_constant_internal', 'tcg_out_label',
)
TRANSLATOR_EXACT = {
    'tcg_gen_code', 'tcg_optimize', 'liveness_pass_0', 'liveness_pass_1',
    'la_cross_call', 'la_bb_end', 'init_ts_info', 'finish_folding',
    'disas_a64', 'aarch64_tr_translate_insn', 'tcg_reg_alloc',
    'tcg_reg_alloc_op', 'temp_load', 'temp_free_or_dead', 'tcg_op_alloc',
    'tcg_emit_op', 'tcg_temp_new_internal', 'tcg_out_op', 'tcg_out_movi32',
    'tcg_out_movi32.constprop.0', 'tcg_reg_alloc_bb_end.constprop.0',
}
# Coeur de la boucle d'execution + lookup de TB.
DISPATCH_EXACT = {
    'cpu_exec', 'cpu_exec_loop', 'cpu_tb_exec', 'tcg_qemu_tb_exec',
    'tb_lookup', 'helper_lookup_tb_ptr', 'tb_htable_lookup',
    'cpu_get_tb_cpu_state', 'tb_jmp_cache_hash', 'qht_lookup',
    'qht_lookup_custom', 'tb_lookup_cmp', 'cpu_exec_setjmp',
}
DISPATCH_PREFIX = ('tb_htable', 'tb_jmp_cache', 'cpu_get_tb_cpu_state')

def classify(dso, sym):
    if dso.startswith('[JIT]'):
        return 'translated'
    if dso == '[kernel.kallsyms]':
        return 'kernel'
    if dso.startswith('[') or 'ld-linux' in dso or 'ld-musl' in dso or dso == '[unknown]':
        return 'other'
    # A partir d'ici : DSO = qemu-aarch64 (code C du fork).
    if sym in DISPATCH_EXACT or any(sym.startswith(p) for p in DISPATCH_PREFIX):
        return 'dispatch'
    if sym in TRANSLATOR_EXACT or any(sym.startswith(p) for p in TRANSLATOR_PREFIX):
        return 'translator'
    if sym.startswith('helper_') or 'mmu_lookup' in sym or sym in ('load_helper', 'store_helper', 'mulu64'):
        return 'helpers'
    # libc / glib / alloc / I/O (dont l'ecriture du perfmap : vfprintf, _IO_, memset...).
    return 'runtime'

def main():
    path = sys.argv[1]
    topn = 20
    if '--top' in sys.argv:
        topn = int(sys.argv[sys.argv.index('--top') + 1])
    buckets = {}
    rows = []
    total = 0.0
    with open(path) as f:
        for ln in f:
            m = LINE.match(ln)
            if not m:
                continue
            pct = float(m.group(1))
            dso = m.group(2).rstrip()
            sym = m.group(3).strip()
            b = classify(dso, sym)
            buckets[b] = buckets.get(b, 0.0) + pct
            rows.append((pct, dso, sym, b))
            total += pct
    order = ['translated', 'translator', 'dispatch', 'helpers', 'runtime', 'kernel', 'other']
    print(f"# {path}")
    print(f"# total accounted: {total:.2f}%  ({len(rows)} symbols)")
    print("## BUCKETS (execution-weighted % of host cycles)")
    for b in order:
        if b in buckets:
            print(f"  {b:11s} {buckets[b]:6.2f}%")
    print(f"## TOP {topn} SYMBOLS")
    for pct, dso, sym, b in sorted(rows, reverse=True)[:topn]:
        dtag = 'JIT' if dso.startswith('[JIT]') else ('kernel' if 'kallsyms' in dso else dso)
        print(f"  {pct:6.2f}%  [{b:10s}] {sym}   ({dtag})")

if __name__ == '__main__':
    main()
