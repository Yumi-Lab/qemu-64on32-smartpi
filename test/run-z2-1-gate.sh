#!/bin/bash
# GATE Z2-1 : rejoue X4 (`dmb ish` -> `dmb ishst` pour un pur store-store barrier guest,
# tcg/arm/tcg-target.c.inc:tcg_out_mb) sur le banc de reference phase Z2 (mtbench smc,
# PAD_CPUS=0-3, cf. docs/METHODOLOGY.md section 9), PAS sur claude --help (mono-thread,
# banc sur lequel X4 avait ete ferme le 2026-08-10 pour un gain juge marginal en COMPTE
# d'occurrences plutot qu'en COUT). Reprend la structure ABAB + medianes + garde thermique
# de run-y5-gate.sh, mais compare un GAIN DIRECT ops/s (pas un ratio de scaling N=2/N=1) a
# N=2 ET N=4, l'axe que Z2-1 doit trancher.
#
# Usage :
#   test/run-z2-1-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]
#     qemuBefore/qemuAfter : noms de binaires dans build-out/
#     reps                  : repetitions ABAB par N (defaut 3)
#     seconds               : duree de cellule mtbench (defaut 60)
#
# Exemple :
#   test/run-z2-1-gate.sh qemu-aarch64-z2-1-baseline qemu-aarch64 3 60
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BEFORE="${1:?usage: run-z2-1-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]}"
QEMU_AFTER="${2:?usage: run-z2-1-gate.sh <qemuBefore> <qemuAfter> [reps] [seconds]}"
REPS="${3:-3}"
CELL_SECONDS="${4:-60}"
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"
GATE_MIN_GAIN_N2="${GATE_MIN_GAIN_N2:-2.0}"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/z2-1-gate-$STAMP.txt"
PAD_FAIL_PREFIX="GATE Z2-1"
QEMU_BIN="qemu-z21-a qemu-z21-b"   # require_idle doit exclure les DEUX noms deployes

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
# (meme fonction que run-y5-gate.sh/run-qemu-ab.sh, dupliquee faute d'un point d'inclusion
# commun entre les gates A/B).
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
    out=$(pad_capture "cd $PAD_DIR && taskset -c 0-3 timeout $RUN_TIMEOUT \
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

say "=== GATE Z2-1, mtbench $WORKLOAD, N in {2,4}, $REPS repetitions ABAB, cellules ${CELL_SECONDS}s, PAD_CPUS=0-3, $STAMP ==="
say "AVANT (dmb ish, non patche) = $QEMU_BEFORE   APRES (dmb ishst sur ST_ST) = $QEMU_AFTER"

SHA_BEFORE=$(deploy_arm "$QEMU_BEFORE" "qemu-z21-a")
SHA_AFTER=$(deploy_arm "$QEMU_AFTER" "qemu-z21-b")
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

# Bash associatif (declare -A) est bash>=4 : le bash systeme de macOS est 3.2. Deux
# scalaires par N (avant/apres) plutot qu'un tableau associatif indexe par cle composee.
MEDIAN_BEFORE_2=""; MEDIAN_AFTER_2=""; MEDIAN_BEFORE_4=""; MEDIAN_AFTER_4=""
for n in 2 4; do
    say "--- N=$n : run de chauffe (JETE) ---"
    one_run "qemu-z21-a" "$n" >/dev/null
    sleep "$SETTLE"
    say ""

    BEFORE_OPS=(); AFTER_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, paire $i/$REPS ---"
        if r=$(one_run "qemu-z21-a" "$n"); then BEFORE_OPS+=("$r"); fi
        sleep "$SETTLE"
        if r=$(one_run "qemu-z21-b" "$n"); then AFTER_OPS+=("$r"); fi
        sleep "$SETTLE"
    done

    say ""
    say "N=$n AVANT (n=${#BEFORE_OPS[@]}) : ${BEFORE_OPS[*]:-aucun} ops/s"
    say "N=$n APRES (n=${#AFTER_OPS[@]}) : ${AFTER_OPS[*]:-aucun} ops/s"

    if [ "${#BEFORE_OPS[@]}" -lt 3 ] || [ "${#AFTER_OPS[@]}" -lt 3 ]; then
        say "N=$n : INCONCLUSIF, moins de 3 runs valides sur un bras."
        continue
    fi
    if [ "$n" = 2 ]; then
        MEDIAN_BEFORE_2=$(median "${BEFORE_OPS[@]}")
        MEDIAN_AFTER_2=$(median "${AFTER_OPS[@]}")
        say "N=$n mediane AVANT = ${MEDIAN_BEFORE_2} ops/s   mediane APRES = ${MEDIAN_AFTER_2} ops/s"
    else
        MEDIAN_BEFORE_4=$(median "${BEFORE_OPS[@]}")
        MEDIAN_AFTER_4=$(median "${AFTER_OPS[@]}")
        say "N=$n mediane AVANT = ${MEDIAN_BEFORE_4} ops/s   mediane APRES = ${MEDIAN_AFTER_4} ops/s"
    fi
    say ""
done

say "=== VERDICT ==="
if [ -z "$MEDIAN_BEFORE_2" ] || [ -z "$MEDIAN_AFTER_2" ]; then
    say "GATE Z2-1 : INCONCLUSIF a N=2 (moins de 3 runs valides sur un bras, cf. ci-dessus)."
    say "Log : $LOG"
    exit 2
fi

GAIN_N2=$(awk -v a="$MEDIAN_BEFORE_2" -v b="$MEDIAN_AFTER_2" 'BEGIN{printf "%.2f", (b-a)/a*100}')
say "gain N=2 (APRES vs AVANT) = ${GAIN_N2}%  (${MEDIAN_BEFORE_2} -> ${MEDIAN_AFTER_2} ops/s)"
if [ -n "$MEDIAN_BEFORE_4" ] && [ -n "$MEDIAN_AFTER_4" ]; then
    GAIN_N4=$(awk -v a="$MEDIAN_BEFORE_4" -v b="$MEDIAN_AFTER_4" 'BEGIN{printf "%.2f", (b-a)/a*100}')
    say "gain N=4 (APRES vs AVANT) = ${GAIN_N4}%  (${MEDIAN_BEFORE_4} -> ${MEDIAN_AFTER_4} ops/s)"
else
    say "gain N=4 : INCONCLUSIF (moins de 3 runs valides sur un bras)."
fi
say ""
PASS=$(awk -v g="$GAIN_N2" -v t="$GATE_MIN_GAIN_N2" 'BEGIN{print (g >= t) ? "OUI" : "NON"}')
say "GATE Z2-1 (gain smc N=2 >= ${GATE_MIN_GAIN_N2}%) : $PASS"
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GUEST sha=$GSHA, le pad dans son"
say "etat du jour. torn64/smc-alias restent a verifier separement (gate complet, pas ce script)."
say "Log : $LOG"
