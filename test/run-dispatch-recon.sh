#!/bin/bash
# X0, reconnaissance fine du bucket dispatch (levier 2 de la carte R1). Decompose le
# cout du dispatch de TB (helper_lookup_tb_ptr, tb_lookup, cpu_get_tb_cpu_state,
# qht_lookup) entre CHEMIN DE HIT et CHEMIN DE MISS du jump cache, pondere execution,
# sur le binaire DEJA DEPLOYE (aucun rebuild). Le compteur execution-weighted
# QEMU_TB_EXEC_PROFILE (phase S, present dans yumi-64on32) est natif du fork : il
# dumpe a l'exit (linux-user/exit.c -> tcg_tb_prof_dump) les compteurs JC_HIT /
# JC_MISS / helper calls / classes de fin, tous ponderes par le nombre reel
# d'executions. On les combine avec les poids par symbole de la carte R1
# (test/logs/perf-hotspots/) pour chiffrer HIT vs MISS en % des cycles totaux.
#
# Cadre : reutilise integralement run-claude-pad.sh (memes gardes pad : sha verifie,
# un seul qemu, taskset, timeout, MemoryMax, garde thermique). On ajoute juste
# QEMU_TB_EXEC_PROFILE=1 a l'env du combo standard (BASE_COMBO, aligne sur
# warm-recipe.sh). AUCUNE chirurgie TCG. Medianes de RUNS runs (defaut 3) par mode.
#
# NOTE : QEMU_TB_EXEC_PROFILE desactive le cache de traduction persistant (cf.
# tb-persist.c), donc chaque run est un boot A FROID complet : c'est le regime
# translation-bound (version) + execution-bound (help), representatif du dispatch nu.
#
# Usage : run-dispatch-recon.sh [RUNS] [TIMEOUT_s]
# Sortie : test/logs/dispatch-recon/{version,help}-run-N.tcg (bloc [tcg] complet),
#          test/logs/dispatch-recon/summary.txt (medianes + decomposition).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
# shellcheck disable=SC1091
source "$TEST_DIR/pad.env"

RUNS="${1:-3}"
TIMEOUT="${2:-360}"
# Combo produit standard, identique a warm-recipe.sh (une seule source de verite).
BASE_COMBO="QEMU_TB_SIZE=256 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"
CPUS="0,1"
MEMMAX="750M"

LOGDIR="$REPO_ROOT/test/logs/dispatch-recon"
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/summary.txt"
: >"$SUMMARY"

median() {
    sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit}
        if(NR%2==1) print a[(NR+1)/2]; else printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}'
}

# Un run : lance claude sous le fork avec le profil execution-weighted actif, puis
# rapatrie le bloc [tcg] complet depuis le fichier stderr du pad (le tail -30 de
# run-claude-pad.sh peut tronquer le dump, on lit donc le fichier .err en entier).
run_one() {
    local mode="$1" tag="$2" out errpath res secs tcgfile
    out=$(CLAUDE_CPUS="$CPUS" CLAUDE_MEMMAX="$MEMMAX" \
          CLAUDE_EXTRA_ENV="$BASE_COMBO QEMU_TB_EXEC_PROFILE=1" \
          bash "$REPO_ROOT/test/run-claude-pad.sh" "$mode" "$TIMEOUT" 2>&1)
    res=$(echo "$out" | grep -oE "RESULT=[A-Z_]+" | head -1)
    secs=$(echo "$out" | grep -oE "elapsed=[0-9]+" | head -1 | grep -oE "[0-9]+")
    errpath=$(echo "$out" | grep -oE "$PAD_DIR/claude-${mode}-[0-9-]+\.err" | head -1)
    tcgfile="$LOGDIR/${mode}-${tag}.tcg"
    if [ -n "$errpath" ]; then
        $PAD_SSH "grep '^\[tcg\]' '$errpath'" >"$tcgfile" 2>/dev/null || true
    fi
    echo "${res:-RESULT=NA} ${secs:-0} $tcgfile"
}

# Extrait un compteur nomme du bloc [tcg] (colonne valeur). $1=fichier, $2=motif.
ctr() {
    grep -F "$2" "$1" 2>/dev/null | grep -oE "[0-9]+" | tail -1
}

for mode in version help; do
    echo "############ mode=$mode ($RUNS runs, profil execution-weighted) ############" | tee -a "$SUMMARY"
    hit_vals=(); miss_vals=(); hcall_vals=(); hnull_vals=(); exec_vals=(); ok=0
    last_tcg=""
    for r in $(seq 1 "$RUNS"); do
        read -r res secs tcgf <<<"$(run_one "$mode" "run-$r")"
        echo "  run $r: $res elapsed=${secs}s -> $(basename "$tcgf")" | tee -a "$SUMMARY"
        [ "$res" != "RESULT=BOOTED" ] && continue
        [ -s "$tcgf" ] || { echo "    (pas de bloc [tcg] : profil absent)" | tee -a "$SUMMARY"; continue; }
        ok=$((ok + 1)); last_tcg="$tcgf"
        hit_vals+=("$(ctr "$tcgf" "jmp cache hits")")
        miss_vals+=("$(ctr "$tcgf" "jmp cache miss")")
        hcall_vals+=("$(ctr "$tcgf" "goto_ptr helper calls")")
        hnull_vals+=("$(ctr "$tcgf" "no TB (epilogue)")")
        exec_vals+=("$(grep -F 'tb executions:' "$tcgf" | grep -oE '[0-9]+' | head -1)")
    done
    if [ "$ok" -eq 0 ]; then
        echo "  AUCUN run exploitable pour $mode" | tee -a "$SUMMARY"; continue
    fi
    hit_med=$(printf '%s\n' "${hit_vals[@]}" | median)
    miss_med=$(printf '%s\n' "${miss_vals[@]}" | median)
    hcall_med=$(printf '%s\n' "${hcall_vals[@]}" | median)
    hnull_med=$(printf '%s\n' "${hnull_vals[@]}" | median)
    exec_med=$(printf '%s\n' "${exec_vals[@]}" | median)
    # Ratios de chemin : part de MISS parmi les lookups indirects (hit+miss).
    total_lu=$((hit_med + miss_med))
    miss_pct="NA"; hit_pct="NA"
    if [ "$total_lu" -gt 0 ]; then
        miss_pct=$(awk "BEGIN{printf \"%.3f\", 100.0*$miss_med/$total_lu}")
        hit_pct=$(awk "BEGIN{printf \"%.3f\", 100.0*$hit_med/$total_lu}")
    fi
    {
        echo "--- BILAN $mode (medianes n=$ok) ---"
        echo "tb executions (weighted)   : $exec_med"
        echo "goto_ptr helper calls      : $hcall_med"
        echo "  ... no TB (new translate): $hnull_med"
        echo "jmp cache HITS             : $hit_med"
        echo "jmp cache MISS (htable hit): $miss_med"
        echo "chemin HIT (% des lookups) : $hit_pct%"
        echo "chemin MISS (% des lookups): $miss_pct%"
        echo "bloc [tcg] de reference     : $(basename "$last_tcg")"
        echo ""
    } | tee -a "$SUMMARY"
done

echo "[dispatch-recon] resume: $SUMMARY"
