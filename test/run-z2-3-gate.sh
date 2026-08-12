#!/bin/bash
# GATE Z2-3 : rejoue X2 (chainage direct TCG perdu au-dela de +-32 Mo, QEMU_TB_SIZE) sur
# mtbench smc N=2/4 (banc de reference phase Z2, cf. docs/METHODOLOGY.md section 9), PAS sur
# claude --help (mono-thread, banc sur lequel X2 avait ete ferme le 2026-08-10 : B, cache
# 256 Mio, restait 50% plus rapide que A, cache 32 Mio, aucun gain demontre au chainage
# direct). Un saut indirect (LDR PC) vide le pipeline sur un coeur in-order, et la pression
# sur le cache d'instructions L1 (32 Ko sur A7) change avec 4 threads actifs partageant les
# memes ports memoire : le mecanisme INTERAGIT avec les threads, contrairement a X3/NZCV/
# dedup (cf. le CRITERE DE TRI de la phase Z2, PROGRESS.md).
# Structure ABAB + medianes + garde thermique + verrou anti-empilement de
# run-z2-2-gate.sh, mais UN SEUL binaire compare a lui-meme selon QEMU_TB_SIZE (32 contre
# 256), sans deploiement de cache (contrairement a Z2-2 : ici seul l'ENV varie, comme X2).
#
# CE QUE CA TRANCHE : si A (tb=32, tout le code invite en portee du chainage direct) egale
# ou depasse B (tb=256) malgre un cache 8x plus petit, la perte de chainage direct au-dela
# de +-32 Mo est REELLE en multi-thread (contrairement au verdict mono-thread de X2). Si B
# reste nettement plus rapide, le cout d'un cache reduit domine encore et X2 reste ferme.
#
# Usage :
#   test/run-z2-3-gate.sh <qemuBin> [reps] [seconds] [Ns]
#     qemuBin : nom du binaire dans build-out/ (deploye une seule fois, teste tb=32 et tb=256)
#     reps    : repetitions par N et par bras (defaut 3)
#     seconds : duree de cellule mtbench (defaut 60)
#     Ns      : liste des N a mesurer (defaut "2 4", cf. libelle Z2-3 : PAS N=1)
#
# Exemple :
#   test/run-z2-3-gate.sh qemu-aarch64 3 60
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BIN_LOCAL="${1:?usage: run-z2-3-gate.sh <qemuBin> [reps] [seconds] [Ns]}"
REPS="${2:-3}"
CELL_SECONDS="${3:-60}"
NS="${4:-2 4}"
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/z2-3-gate-$STAMP.txt"
PAD_FAIL_PREFIX="GATE Z2-3"
QEMU_BIN="qemu-z23"   # require_idle doit exclure ce nom

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# VERROU ANTI-EMPILEMENT (meme defaut reproduit et corrige en Z2-2, cf. son entete : jusqu'a
# 5 instances simultanees lancees par des iterations successives de la boucle contaminaient
# la meme mesure). mkdir est atomique, portable (flock absent de macOS).
LOCKDIR="$REPO_ROOT/.monitor/.z2-3-gate.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OTHER_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        fail "une autre instance de run-z2-3-gate.sh tourne deja (pid $OTHER_PID, verrou $LOCKDIR) : ce gate exige une seule instance a la fois"
    fi
    say "verrou $LOCKDIR laisse par le pid ${OTHER_PID:-?} (mort) : verrou perime, reprise"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || fail "impossible de reprendre le verrou perime $LOCKDIR"
fi
echo "$$" >"$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

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

# Deploie un build local sous un nom distinct sur le pad, sha verifie DES DEUX COTES (meme
# fonction que run-z2-1-gate.sh/run-z2-2-gate.sh, dupliquee faute d'un point d'inclusion
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

# Un run mtbench smc. $1 = N, $2 = bras ("a"=tb32|"b"=tb256). Imprime ops_per_sec sur
# stdout, ou rien pour un run invalide. FAIL immediat (pas une exclusion silencieuse) si le
# marqueur SMC execute est perime : regression de correctness, pas une histoire de vitesse.
one_run() {
    local n="$1" arm="$2" tbsize out rc ops i tb
    [ "$arm" = "a" ] && tbsize=32 || tbsize=256
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pad_really_idle && break
        say "    pad occupe (autre qemu ou transfert en cours), attente $i/10..."
        sleep 30
        [ "$i" = 10 ] && fail "le pad reste occupe par un autre processus : mesure abandonnee plutot que contaminee"
    done
    tb=$(wait_cool)

    out=$(pad_capture "cd $PAD_DIR && taskset -c 0-3 timeout $RUN_TIMEOUT \
          env QEMU_TB_SIZE=$tbsize ./$QEMU_BIN ./$GUEST $WORKLOAD $n $CELL_SECONDS 2>&1; echo RC=\$?") \
        || { say "    [tb=$tbsize N=$n] pad injoignable pendant le run"; return 1; }
    rc=$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)
    ops=$(printf '%s' "$out" | grep -oE 'ops_per_sec=[0-9]+' | tail -1 | cut -d= -f2)
    say "    [tb=$tbsize N=$n] rc=$rc ops_per_sec=${ops:-?} temp_before=$((tb / 1000))C"

    if printf '%s' "$out" | grep -q "code perime"; then
        fail "tb=$tbsize N=$n : mtbench a detecte du code JIT PERIME execute (regression de" \
             "correctness independante de QEMU_TB_SIZE, PAS un run a exclure). Sortie : " \
             "$(printf '%s' "$out" | grep 'code perime\|ERROR: thread')"
    fi

    if [ "$(classify_qemu_rc "${rc:-1}")" = "BENCH_FAIL" ]; then
        fail "$QEMU_BIN : rc=$rc -> ECHEC DE BANC (binaire non executable ou absent), PAS un echec du build teste. Rien a conclure sur l'emulateur."
    fi

    [ "$rc" = "0" ] || { say "    [tb=$tbsize N=$n] rc=$rc -> EXCLU de la mediane"; return 1; }
    [ -n "$ops" ] || { say "    [tb=$tbsize N=$n] ligne RESULT absente -> EXCLU"; return 1; }
    printf '%s' "$ops"
}

pad_alive || fail "pad injoignable (allume-le ; cette mesure exige une execution reelle)"

say "=== GATE Z2-3, mtbench $WORKLOAD, N in {$NS}, $REPS repetitions ABAB, cellules ${CELL_SECONDS}s, PAD_CPUS=0-3, $STAMP ==="
say "BINAIRE UNIQUE (compare a lui-meme) : $QEMU_BIN_LOCAL"
say "bras A = QEMU_TB_SIZE=32  (tout le code invite dans la portee +-32 Mo du chainage direct)"
say "bras B = QEMU_TB_SIZE=256 (valeur en usage partout ailleurs dans le projet)"

SHA=$(deploy_arm "$QEMU_BIN_LOCAL" "$QEMU_BIN")
say "  $QEMU_BIN_LOCAL sha=$SHA"

GSHA=$(pad_capture "sha256sum $PAD_DIR/$GUEST 2>/dev/null | cut -c1-16")
if [ -z "$GSHA" ]; then
    say "  invite $GUEST absent du pad, deploiement..."
    pad_put "$BUILD_OUT/$GUEST" "$PAD_DIR/$GUEST" || fail "deploiement de $GUEST echoue"
    $PAD_SSH "chmod +x $PAD_DIR/$GUEST"
    GSHA=$(pad_capture "sha256sum $PAD_DIR/$GUEST 2>/dev/null | cut -c1-16")
fi
say "  invite $GUEST sha=$GSHA"
say ""

# Bash associatif (declare -A) est bash>=4 : le bash systeme de macOS est 3.2. Un scalaire
# par N pour chaque bras (meme convention que run-z2-1-gate.sh/run-z2-2-gate.sh).
MEDIAN_A_2=""; MEDIAN_B_2=""
MEDIAN_A_4=""; MEDIAN_B_4=""

for n in $NS; do
    say "--- N=$n : run de chauffe (JETE, bras B) ---"
    one_run "$n" "b" >/dev/null
    sleep "$SETTLE"
    say ""

    A_OPS=(); B_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, paire $i/$REPS ---"
        if r=$(one_run "$n" "a"); then A_OPS+=("$r"); fi
        sleep "$SETTLE"
        if r=$(one_run "$n" "b"); then B_OPS+=("$r"); fi
        sleep "$SETTLE"
    done

    say ""
    say "N=$n A, tb=32  (n=${#A_OPS[@]}) : ${A_OPS[*]:-aucun} ops/s"
    say "N=$n B, tb=256 (n=${#B_OPS[@]}) : ${B_OPS[*]:-aucun} ops/s"

    if [ "${#A_OPS[@]}" -lt 3 ] || [ "${#B_OPS[@]}" -lt 3 ]; then
        say "N=$n : INCONCLUSIF, moins de 3 runs valides sur un bras."
        say ""
        continue
    fi
    MED_A=$(median "${A_OPS[@]}")
    MED_B=$(median "${B_OPS[@]}")
    say "N=$n mediane A (tb=32) = ${MED_A} ops/s   mediane B (tb=256) = ${MED_B} ops/s"
    case "$n" in
        2) MEDIAN_A_2="$MED_A"; MEDIAN_B_2="$MED_B" ;;
        4) MEDIAN_A_4="$MED_A"; MEDIAN_B_4="$MED_B" ;;
    esac
    say ""
done

say "=== VERDICT ==="
gain_of() {
    local a="$1" b="$2"
    [ -z "$a" ] || [ -z "$b" ] && { printf 'NA'; return; }
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%+.2f", (a-b)/b*100}'
}
GAIN_N2=$(gain_of "$MEDIAN_A_2" "$MEDIAN_B_2")
GAIN_N4=$(gain_of "$MEDIAN_A_4" "$MEDIAN_B_4")
say "A vs B, N=2 = ${GAIN_N2}%  (${MEDIAN_B_2:-NA} -> ${MEDIAN_A_2:-NA} ops/s, positif = A/tb32 plus rapide que B/tb256)"
say "A vs B, N=4 = ${GAIN_N4}%  (${MEDIAN_B_4:-NA} -> ${MEDIAN_A_4:-NA} ops/s, positif = A/tb32 plus rapide que B/tb256)"
say ""

verdict_of() {
    local ma="$1" mb="$2" n="$3"
    if [ -z "$ma" ] || [ -z "$mb" ]; then
        say "GATE Z2-3 N=$n : INCONCLUSIF (moins de 3 runs valides sur un bras, cf. ci-dessus)."
        return
    fi
    if [ "$ma" -ge "$mb" ]; then
        say "GATE Z2-3 N=$n : A (tb=32) egale ou depasse B (tb=256) malgre un cache 8x plus petit -> la perte de chainage direct au-dela de +-32 Mo est REELLE en multi-thread."
    else
        say "GATE Z2-3 N=$n : B (tb=256) reste plus rapide -> le cout d'un cache reduit domine encore, X2 reste ferme a ce N."
    fi
}
verdict_of "$MEDIAN_A_2" "$MEDIAN_B_2" 2
verdict_of "$MEDIAN_A_4" "$MEDIAN_B_4" 4
say ""
say "CE QUE CA TRANCHE : le verdict mono-thread de X2 (B toujours plus rapide, chainage"
say "direct ferme sans gain demontre) ne tient QUE si B reste plus rapide aux DEUX N ci-dessus."
say "Si A egale ou depasse B a N=2 ET/OU N=4, le mecanisme interagit bien avec les threads"
say "(cf. le CRITERE DE TRI de la phase Z2) et la piste doit etre rouverte pour ce N."
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GUEST sha=$GSHA, le binaire $QEMU_BIN_LOCAL"
say "sha=$SHA, le pad dans son etat du jour. Aucun patch n'est introduit ici (seul l'ENV varie,"
say "comme X2) : torn64/smc-alias restent ceux deja verifies sur ce binaire, pas re-testes."
say "Log : $LOG"
