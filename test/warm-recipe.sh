#!/bin/bash
# W1, recette warm officielle (levier 1 de la carte R1) : mesurer le combo produit
# standard AVEC cache de traduction persistant (QEMU_TB_CACHE + setarch -R, cf.
# P3/M1) contre le meme combo a froid, sur le binaire deja deploye. Pour chaque
# mode (version, help) : medianes de N runs COLD (sans cache), un run COLD-SAVE qui
# amorce le cache, puis medianes de N runs WARM (cache recharge). La preuve de
# CHARGEMENT du cache est extraite du log qemu ("reloaded N/N TBs") : un run "warm"
# qui affiche "stale or foreign" est REJETE (cache non charge => warm == cold par
# construction, cf. INDICE W1 orchestrateur).
#
# Regles pad respectees via run-claude-pad.sh (sha verifie, un seul qemu, taskset,
# systemd-run MemoryMax, timeout, garde thermique). setarch -R (CLAUDE_SETARCH=1)
# fige le guest_base, requis par la validation du cache.
#
# Usage: test/warm-recipe.sh [runs_per_config] [timeout_s]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-3}"
TIMEOUT="${2:-300}"
LOGDIR="$REPO_ROOT/test/logs/warm-recipe"
mkdir -p "$LOGDIR"

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad.env"

# Combo produit standard hors cache (fixe par P/M1 : tb-size 256 + GC calme), 2
# coeurs (recette init CLI M1). Le cache s'ajoute par QEMU_TB_CACHE + setarch.
BASE_COMBO="QEMU_TB_SIZE=256 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"
CPUS="0,1"
MEMMAX="750M"

median() {
    sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# Un run de run-claude-pad.sh. Args : mode, env_extra additionnel, setarch(0|1),
# tag (pour le nom de log). Ecrit le log complet, renvoie "RESULT=... <elapsed>".
run_one() {
    local mode="$1" env_extra="$2" setarch="$3" tag="$4" out res secs extra
    extra="$BASE_COMBO${env_extra:+ $env_extra}"
    out=$(CLAUDE_CPUS="$CPUS" CLAUDE_MEMMAX="$MEMMAX" CLAUDE_SETARCH="$setarch" \
          CLAUDE_EXTRA_ENV="$extra" \
          bash "$REPO_ROOT/test/run-claude-pad.sh" "$mode" "$TIMEOUT" 2>&1)
    echo "$out" >"$LOGDIR/${mode}-${tag}.log"
    res=$(echo "$out" | grep -oE "RESULT=[A-Z_]+" | head -1)
    secs=$(echo "$out" | grep -oE "elapsed=[0-9]+" | head -1 | grep -oE "[0-9]+")
    echo "${res:-RESULT=NA} ${secs:-0}"
}

# Etat de chargement du cache lu dans le dernier log warm : reloaded / stale / none.
cache_state() {
    local logf="$1"
    if grep -q "stale or foreign" "$logf"; then echo "STALE"; return; fi
    grep -oE "reloaded [0-9]+/[0-9]+ TBs" "$logf" | head -1 && return
    echo "NONE"
}

SUMMARY="$LOGDIR/summary.txt"
: >"$SUMMARY"

for mode in version help; do
    CACHE_PAD="$PAD_DIR/tbcache-${mode}.bin"
    echo "############ mode=$mode ############" | tee -a "$SUMMARY"

    # --- COLD : combo standard, aucun cache, N runs ---
    echo "=== COLD ($mode) : $RUNS runs, combo standard sans cache ===" | tee -a "$SUMMARY"
    cold_vals=(); cold_rc="?"; cold_bytes="?"
    for r in $(seq 1 "$RUNS"); do
        read -r res secs <<<"$(run_one "$mode" "" 0 "cold-$r")"
        echo "  cold run $r: $res elapsed=${secs}s"
        [ "$res" = "RESULT=BOOTED" ] && cold_vals+=("$secs")
    done
    cold_med="NA"; [ "${#cold_vals[@]}" -gt 0 ] && cold_med=$(printf '%s\n' "${cold_vals[@]}" | median)
    cold_bytes=$(grep -oE "out_bytes=[0-9]+" "$LOGDIR/${mode}-cold-1.log" | head -1)

    # --- COLD-SAVE : amorce le cache (supprime l'ancien d'abord) ---
    echo "=== COLD-SAVE ($mode) : amorce $CACHE_PAD ===" | tee -a "$SUMMARY"
    $PAD_SSH "rm -f '$CACHE_PAD'" 2>/dev/null || true
    read -r save_res save_secs <<<"$(run_one "$mode" "QEMU_TB_CACHE=$CACHE_PAD" 1 "coldsave")"
    save_line=$(grep -oE "saved [0-9]+ TBs[^\"]*" "$LOGDIR/${mode}-coldsave.log" | head -1)
    echo "  cold-save: $save_res elapsed=${save_secs}s ($save_line)"

    # --- WARM : combo standard + cache recharge + setarch, N runs ---
    echo "=== WARM ($mode) : $RUNS runs, cache recharge + setarch -R ===" | tee -a "$SUMMARY"
    warm_vals=(); warm_state="NONE"; warm_bytes="?"
    for r in $(seq 1 "$RUNS"); do
        read -r res secs <<<"$(run_one "$mode" "QEMU_TB_CACHE=$CACHE_PAD" 1 "warm-$r")"
        st=$(cache_state "$LOGDIR/${mode}-warm-$r.log")
        echo "  warm run $r: $res elapsed=${secs}s cache=[$st]"
        # Un run n'entre dans la mediane WARM que si le cache a VRAIMENT ete charge.
        if [ "$res" = "RESULT=BOOTED" ] && echo "$st" | grep -q "reloaded"; then
            warm_vals+=("$secs"); warm_state="$st"
        elif [ "$st" = "STALE" ]; then
            warm_state="STALE"
        fi
    done
    warm_med="NA"; [ "${#warm_vals[@]}" -gt 0 ] && warm_med=$(printf '%s\n' "${warm_vals[@]}" | median)
    warm_bytes=$(grep -oE "out_bytes=[0-9]+" "$LOGDIR/${mode}-warm-1.log" | head -1)

    # --- Delta ---
    delta="NA"
    if [ "$cold_med" != "NA" ] && [ "$warm_med" != "NA" ] && [ "$cold_med" -gt 0 ]; then
        delta=$(awk "BEGIN{printf \"%.1f\", ($warm_med-$cold_med)*100.0/$cold_med}")
    fi
    {
        echo "--- BILAN $mode ---"
        echo "cold mediane   : ${cold_med}s (n=${#cold_vals[@]}, $cold_bytes)"
        echo "warm mediane   : ${warm_med}s (n=${#warm_vals[@]}, $warm_bytes)"
        echo "cache warm     : $warm_state"
        echo "delta warm/cold: ${delta}%"
    } | tee -a "$SUMMARY"
done

echo
echo "=== RESUME W1 ==="
cat "$SUMMARY"
