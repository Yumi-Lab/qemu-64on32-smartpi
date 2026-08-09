#!/bin/bash
# GATE Y5 : scaling `smc` (mtbench) a N=1 et N=2, AVANT (baseline pre-Y5) vs APRES
# (pageflags_lock dedie branche), meme jour, meme protocole, cellules >= 60 s, n>=3,
# medianes. Reprend la structure de run-qemu-ab.sh (ABAB, deploiement sha-verifie,
# garde thermique/idle de pad-lib.sh) pour le workload et la metrique de run-mtbench.sh
# (ops_per_sec, pas un temps mural).
#
# Usage :
#   test/run-y5-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]
#     qemuBefore/qemuAfter : noms de binaires dans build-out/
#     reps                 : repetitions ABAB par N (defaut 3)
#     seconds               : duree de cellule mtbench (defaut 60)
#
# Exemple (Y5, sous-lot 10 -> mesure) :
#   test/run-y5-gate.sh qemu-aarch64-y5-baseline qemu-aarch64 3 60
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BEFORE="${1:?usage: run-y5-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]}"
QEMU_AFTER="${2:?usage: run-y5-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]}"
REPS="${3:-3}"
CELL_SECONDS="${4:-60}"
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/y5-gate-$STAMP.txt"
PAD_FAIL_PREFIX="GATE Y5"
QEMU_BIN="qemu-y5-a qemu-y5-b"   # pour require_idle : ce gate deploie ET execute LES DEUX
# noms sur le pad (deploy_arm lignes 104-105, one_run lignes 125/132/134) ; pad_really_idle
# scinde QEMU_BIN sur les espaces (pad-lib.sh), donc une liste suffit. Un seul des deux noms
# ici avait laisse "qemu-y5-b" hors de l'exclusion mutuelle (revue 34) : plusieurs instances
# du gate pouvaient tourner en meme temps sans que require_idle ne le detecte.

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

median() {
    local n sorted
    sorted=$(printf '%s\n' "$@" | sort -n)
    n=$#
    if [ $((n % 2)) -eq 1 ]; then
        printf '%s' "$(printf '%s\n' "$sorted" | sed -n "$(((n + 1) / 2))p")"
    else
        local a b
        a=$(printf '%s\n' "$sorted" | sed -n "$((n / 2))p")
        b=$(printf '%s\n' "$sorted" | sed -n "$((n / 2 + 1))p")
        printf '%s' $(((a + b) / 2))
    fi
}

# Deploie un build local sous un nom distinct sur le pad, sha verifie DES DEUX COTES
# (meme fonction que run-qemu-ab.sh, dupliquee faute d'un point d'inclusion commun entre
# les deux scripts : pad-lib.sh est le seul partage, ces gates A/B restent independants).
deploy_arm() {
    local src="$1" name="$2" lsha psha
    [ -f "$BUILD_OUT/$src" ] || fail "$BUILD_OUT/$src absent"
    lsha=$(shasum -a 256 "$BUILD_OUT/$src" | cut -c1-16)
    psha=$(pad_capture "sha256sum $PAD_DIR/$name 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha $name)"
    if [ "$lsha" != "$psha" ]; then
        say "  deploiement $src -> $name (local=$lsha pad=${psha:-absent})..."
        pad_put "$BUILD_OUT/$src" "$PAD_DIR/$name" || fail "deploiement de $src echoue"
        $PAD_SSH "chmod +x $PAD_DIR/$name"
        psha=$(pad_capture "sha256sum $PAD_DIR/$name | cut -c1-16")
        [ "$lsha" = "$psha" ] || fail "$name : sha divergent apres deploiement"
    fi
    $PAD_SSH "chmod +x $PAD_DIR/$name" >/dev/null 2>&1
    printf '%s' "$lsha"
}

# Un run mtbench smc. $1 = nom du binaire qemu sur le pad, $2 = N (threads).
# Imprime ops_per_sec, ou rien si invalide (rc!=0, ligne RESULT absente).
one_run() {
    local qbin="$1" n="$2" tb out rc ops i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pad_really_idle && break
        say "    pad occupe (autre qemu ou transfert en cours), attente $i/10..."
        sleep 30
        [ "$i" = 10 ] && fail "le pad reste occupe par un autre processus : mesure abandonnee plutot que contaminee"
    done
    require_idle
    tb=$(wait_cool)
    out=$(pad_capture "cd $PAD_DIR && taskset -c 0,1 timeout $RUN_TIMEOUT \
          ./$qbin ./$GUEST $WORKLOAD $n $CELL_SECONDS 2>&1; echo RC=\$?") \
        || { say "    [$qbin N=$n] pad injoignable pendant le run"; return 1; }
    rc=$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)
    ops=$(printf '%s' "$out" | grep -oE 'ops_per_sec=[0-9]+' | tail -1 | cut -d= -f2)
    say "    [$qbin N=$n] rc=$rc ops_per_sec=${ops:-?} temp_before=$((tb / 1000))C"
    if [ "$(classify_qemu_rc "${rc:-1}")" = "BENCH_FAIL" ]; then
        fail "$qbin : rc=$rc -> ECHEC DE BANC (binaire non executable ou absent), PAS un echec du build teste. Rien a conclure sur l'emulateur."
    fi
    [ "$rc" = "0" ] || { say "    [$qbin N=$n] rc!=0 -> EXCLU de la mediane"; return 1; }
    [ -n "$ops" ] || { say "    [$qbin N=$n] ligne RESULT absente -> EXCLU"; return 1; }
    printf '%s' "$ops"
}

pad_alive || fail "pad injoignable (allume-le ; cette mesure exige une execution reelle)"

say "=== GATE Y5, mtbench $WORKLOAD, $REPS repetitions ABAB, cellules ${CELL_SECONDS}s, $STAMP ==="
say "AVANT (baseline pre-Y5) = $QEMU_BEFORE   APRES (pageflags_lock branche) = $QEMU_AFTER"

SHA_BEFORE=$(deploy_arm "$QEMU_BEFORE" "qemu-y5-a")
SHA_AFTER=$(deploy_arm "$QEMU_AFTER" "qemu-y5-b")
say "  AVANT=$QEMU_BEFORE sha=$SHA_BEFORE   APRES=$QEMU_AFTER sha=$SHA_AFTER"
[ "$SHA_BEFORE" != "$SHA_AFTER" ] || fail "les deux bras ont le MEME sha : il n'y a rien a comparer"

GSHA=$(pad_capture "sha256sum $PAD_DIR/$GUEST 2>/dev/null | cut -c1-16")
if [ -z "$GSHA" ]; then
    say "  invite $GUEST absent du pad, deploiement..."
    pad_put "$BUILD_OUT/$GUEST" "$PAD_DIR/$GUEST" || fail "deploiement de $GUEST echoue"
    $PAD_SSH "chmod +x $PAD_DIR/$GUEST"
    GSHA=$(pad_capture "sha256sum $PAD_DIR/$GUEST 2>/dev/null | cut -c1-16")
fi
say "  invite $GUEST sha=$GSHA"
say ""

# Bash associatif (declare -A) est bash>=4 : le bash systeme de macOS est 3.2
# (deja documente dans test-pad-lib.sh a propos de mapfile). Deux scalaires par
# N (avant/apres) plutot qu'un tableau associatif indexe par cle composee.
MEDIAN_BEFORE_1=""; MEDIAN_AFTER_1=""; MEDIAN_BEFORE_2=""; MEDIAN_AFTER_2=""
for n in 1 2; do
    say "--- N=$n : run de chauffe (JETE) ---"
    one_run "qemu-y5-a" "$n" >/dev/null
    sleep "$SETTLE"
    say ""

    BEFORE_OPS=(); AFTER_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, paire $i/$REPS ---"
        if r=$(one_run "qemu-y5-a" "$n"); then BEFORE_OPS+=("$r"); fi
        sleep "$SETTLE"
        if r=$(one_run "qemu-y5-b" "$n"); then AFTER_OPS+=("$r"); fi
        sleep "$SETTLE"
    done

    say ""
    say "N=$n AVANT (n=${#BEFORE_OPS[@]}) : ${BEFORE_OPS[*]:-aucun} ops/s"
    say "N=$n APRES (n=${#AFTER_OPS[@]}) : ${AFTER_OPS[*]:-aucun} ops/s"

    if [ "${#BEFORE_OPS[@]}" -lt 3 ] || [ "${#AFTER_OPS[@]}" -lt 3 ]; then
        say "N=$n : INCONCLUSIF, moins de 3 runs valides sur un bras."
        continue
    fi
    if [ "$n" = 1 ]; then
        MEDIAN_BEFORE_1=$(median "${BEFORE_OPS[@]}")
        MEDIAN_AFTER_1=$(median "${AFTER_OPS[@]}")
        say "N=$n mediane AVANT = ${MEDIAN_BEFORE_1} ops/s   mediane APRES = ${MEDIAN_AFTER_1} ops/s"
    else
        MEDIAN_BEFORE_2=$(median "${BEFORE_OPS[@]}")
        MEDIAN_AFTER_2=$(median "${AFTER_OPS[@]}")
        say "N=$n mediane AVANT = ${MEDIAN_BEFORE_2} ops/s   mediane APRES = ${MEDIAN_AFTER_2} ops/s"
    fi
    say ""
done

say "=== VERDICT ==="
if [ -z "$MEDIAN_BEFORE_1" ] || [ -z "$MEDIAN_BEFORE_2" ] || [ -z "$MEDIAN_AFTER_1" ] || [ -z "$MEDIAN_AFTER_2" ]; then
    say "GATE Y5 : INCONCLUSIF (au moins un N sans mediane valide, cf. ci-dessus)."
    say "Log : $LOG"
    exit 2
fi

SCALE_BEFORE=$(awk -v a="$MEDIAN_BEFORE_2" -v b="$MEDIAN_BEFORE_1" 'BEGIN{printf "%.3f", a/b}')
SCALE_AFTER=$(awk -v a="$MEDIAN_AFTER_2" -v b="$MEDIAN_AFTER_1" 'BEGIN{printf "%.3f", a/b}')
say "scaling AVANT (N=2/N=1) = ${SCALE_BEFORE}x  (${MEDIAN_BEFORE_1} -> ${MEDIAN_BEFORE_2} ops/s)"
say "scaling APRES (N=2/N=1) = ${SCALE_AFTER}x  (${MEDIAN_AFTER_1} -> ${MEDIAN_AFTER_2} ops/s)"
say ""
PASS=$(awk -v s="$SCALE_AFTER" 'BEGIN{print (s > 1.0) ? "OUI" : "NON"}')
say "GATE Y5 (scaling smc > 1,0x a N=2, APRES) : $PASS"
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GUEST sha=$GSHA, le pad dans son"
say "etat du jour. torn64/smc-alias restent a verifier separement (gate complet, pas ce script)."
say "Log : $LOG"
