#!/bin/bash
# R2, balayage fin des seuils JIT invite (levier invite du handoff, zero risque,
# independant de R1 : aucun patch qemu/, uniquement des variables d'env invite).
# Mesure claude --help (init CLI complete, proxy le plus proche du travail agent
# reel parmi les workloads one-shot deja gates) sur le binaire deja deploye, pour
# 6 configs : les 2 references (LLInt pur, JIT defaut sans seuil force) plus 4
# seuils BUN_JSC_thresholdForJITAfterWarmUp (5000/20000/50000/200000) en JIT actif.
# Mediane de N runs chauds par config (defaut 3), refroidissement entre runs via
# la garde thermique deja integree a run-claude-pad.sh (attente si >80C avant
# chaque lancement). Portable bash 3.2 (macOS) : tableaux indexes paralleles,
# pas de tableaux associatifs.
#
# Usage: test/sweep-jit-threshold.sh [runs_per_config] [timeout_s]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-3}"
TIMEOUT="${2:-300}"
LOGDIR="$REPO_ROOT/test/logs/jit-threshold-sweep"
mkdir -p "$LOGDIR"

# Combo standard hors useJIT (fixe par les lots P/M1 : tb-size + GC calme), le
# statut JIT/seuil est ajoute par config ci-dessous.
BASE_COMBO="QEMU_TB_SIZE=256 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

median() {
    sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# configs : tableaux indexes paralleles (nom / env additionnel), meme index i.
CONFIG_NAMES=(llint jit-default jit-5000 jit-20000 jit-50000 jit-200000)
CONFIG_ENVS=(
    "BUN_JSC_useJIT=0"
    "BUN_JSC_useJIT=1"
    "BUN_JSC_useJIT=1 BUN_JSC_thresholdForJITAfterWarmUp=5000"
    "BUN_JSC_useJIT=1 BUN_JSC_thresholdForJITAfterWarmUp=20000"
    "BUN_JSC_useJIT=1 BUN_JSC_thresholdForJITAfterWarmUp=50000"
    "BUN_JSC_useJIT=1 BUN_JSC_thresholdForJITAfterWarmUp=200000"
)

run_one() {
    local name="$1" env_extra="$2" idx="$3" extra out res secs
    extra="$BASE_COMBO $env_extra"
    out=$(CLAUDE_CPUS=0,1 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$extra" bash "$REPO_ROOT/test/run-claude-pad.sh" help "$TIMEOUT" 2>&1)
    echo "$out" > "$LOGDIR/help-${name}-$idx.log"
    res=$(echo "$out" | grep -oE "RESULT=[A-Z]+" | head -1)
    secs=$(echo "$out" | grep -oE "elapsed=[0-9]+" | head -1 | grep -oE "[0-9]+")
    echo "${res:-RESULT=NA} ${secs:-0}"
}

MEDIAN_NAMES=()
MEDIAN_VALS=()
for i in "${!CONFIG_NAMES[@]}"; do
    name="${CONFIG_NAMES[$i]}"
    env_extra="${CONFIG_ENVS[$i]}"
    echo "=== config $name ($env_extra) : $RUNS runs ==="
    vals=()
    ok=0
    for r in $(seq 1 "$RUNS"); do
        read -r res secs <<<"$(run_one "$name" "$env_extra" "$r")"
        echo "  run $r: result=${res:-FAIL} elapsed=${secs:-NA}s"
        if [ "$res" = "RESULT=BOOTED" ]; then
            vals+=("${secs:-0}")
            ok=$((ok + 1))
        fi
    done
    if [ "$ok" -gt 0 ]; then
        med=$(printf '%s\n' "${vals[@]}" | median)
    else
        med="NA"
    fi
    MEDIAN_NAMES+=("$name")
    MEDIAN_VALS+=("$med")
    echo "  mediane $name: ${med}s ($ok/$RUNS runs BOOTED)"
done

{
    echo "=== R2, balayage seuils JIT invite (--help, $RUNS runs/config) ==="
    for i in "${!MEDIAN_NAMES[@]}"; do
        echo "${MEDIAN_NAMES[$i]}: mediane=${MEDIAN_VALS[$i]}s"
    done
} | tee "$LOGDIR/summary.txt"
