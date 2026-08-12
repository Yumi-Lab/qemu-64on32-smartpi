#!/bin/bash
# GATE Z2-2 : rejoue le cache de traduction persistant (-tb-cache, patch 0007) sur mtbench
# smc N=1/2/4 (banc de reference phase Z2, cf. docs/METHODOLOGY.md section 9), pour trancher
# l'argument invoque a sa fermeture mono-thread (0,0% de gain sur claude --help => "la
# traduction n'est pas le goulot"). En multi-thread, eviter une retraduction evite aussi une
# PRISE DE VERROU CONTENDUE (Y4 a mesure que la contention est le goulot de smc) : cet
# argument peut ne plus tenir. Structure ABAB + medianes + garde thermique de
# run-z2-1-gate.sh, mais UN SEUL binaire compare a lui-meme selon que QEMU_TB_CACHE est
# charge (WARM, + setarch -R pour figer guest_base) ou absent (COLD), pas deux binaires.
#
# La charge smc reecrit son code a CHAQUE tour (test/mtbench.c:smc_round, marqueur qui
# cycle) : un cache preleve au demarrage du run precedent ne peut couvrir que le code de
# demarrage (setup, pthread init), jamais les tours smc eux-memes, deja invalides avant la
# premiere execution du nouveau run. La mesure tranche ce mecanisme, elle ne le devine pas.
#
# CORRECTNESS : mtbench smc verifie lui-meme le code execute (marqueur attendu) et sort en
# echec ("code perime") si du code JIT perime tourne. Un run WARM qui echoue ainsi n'est PAS
# exclu de la mediane comme un run transitoire : c'est une regression de correctness du
# cache reapplique sur de la SMC, non negociable, le gate s'arrete (fail()).
#
# Usage :
#   test/run-z2-2-gate.sh <qemuBin> [reps] [seconds] [Ns]
#     qemuBin : nom du binaire dans build-out/ (deploye une seule fois, teste COLD et WARM)
#     reps    : repetitions par N et par mode (defaut 3)
#     seconds : duree de cellule mtbench (defaut 60)
#     Ns      : liste des N a mesurer (defaut "1 2 4")
#
# Exemple :
#   test/run-z2-2-gate.sh qemu-aarch64-z2-1-ishst 3 60
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BIN_LOCAL="${1:?usage: run-z2-2-gate.sh <qemuBin> [reps] [seconds] [Ns]}"
REPS="${2:-3}"
CELL_SECONDS="${3:-60}"
NS="${4:-1 2 4}"
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"
GATE_MIN_GAIN_N2="${GATE_MIN_GAIN_N2:-2.0}"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/z2-2-gate-$STAMP.txt"
PAD_FAIL_PREFIX="GATE Z2-2"
QEMU_BIN="qemu-z22"   # require_idle doit exclure ce nom

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# VERROU ANTI-EMPILEMENT (mkdir est atomique, portable : flock est absent de macOS ou
# tourne ce script). Reproduit en direct le 2026-08-11 : jusqu'a 5 instances simultanees
# lancees par des iterations successives de la boucle, chacune ignorant le run officiel
# deja en vol, se disputant le MEME fichier de cache pad ($CACHE_PATH) -> comparaison
# COLD/WARM contaminee, en plus de saturer le pad. Une verification manuelle `ps aux`
# faite avant le lancement ne survit pas au tour suivant (contexte neuf) : le verrou doit
# etre mecanique et vecu par le script lui-meme.
LOCKDIR="$REPO_ROOT/.monitor/.z2-2-gate.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OTHER_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        fail "une autre instance de run-z2-2-gate.sh tourne deja (pid $OTHER_PID, verrou $LOCKDIR) : ce gate exige une seule instance a la fois, sinon la mesure COLD/WARM est contaminee (meme fichier de cache pad)"
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

# Deploie un build local sous un nom distinct sur le pad, sha verifie DES DEUX COTES
# (meme fonction que run-z2-1-gate.sh/run-y5-gate.sh/run-qemu-ab.sh, dupliquee faute d'un
# point d'inclusion commun entre les gates A/B).
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

# Un run mtbench smc. $1 = N, $2 = mode ("cold"|"warm"|"primer"), $3 = chemin cache pad
# (warm/primer seulement). Imprime ops_per_sec sur stdout (rien pour "primer" ni un run
# invalide). FAIL immediat (pas une exclusion silencieuse) si le marqueur SMC execute est
# perime : c'est une regression de correctness du cache sur de la charge auto-modifiante.
one_run() {
    local n="$1" mode="$2" cache_path="${3:-}" out rc ops i env_assign sa
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pad_really_idle && break
        say "    pad occupe (autre qemu ou transfert en cours), attente $i/10..."
        sleep 30
        [ "$i" = 10 ] && fail "le pad reste occupe par un autre processus : mesure abandonnee plutot que contaminee"
    done
    # PAS de require_idle ici (divergence deliberee de run-z2-1-gate.sh/run-y5-gate.sh, qui
    # l'appellent juste apres cette meme boucle) : require_idle relance EXACTEMENT le meme
    # controle pad_really_idle que la boucle ci-dessus vient de faire reussir, un aller-retour
    # ssh de plus sans information nouvelle. Reproduit le 2026-08-11 (STAMP 20260811-112128) :
    # la boucle a fini par voir le pad idle (break), et ce second appel, sur le MEME pad dont
    # le sshd throttle deja les rafales (cf. GOAL.md), a lui-meme essuye un blip transitoire et
    # tue toute la campagne de 45-70 min via fail() -- exactement le defaut que la boucle existe
    # pour absorber.
    tb=$(wait_cool)

    env_assign=""
    sa=""
    if [ "$mode" != "cold" ]; then
        env_assign="QEMU_TB_CACHE=$cache_path"
        sa="setarch \$(uname -m) -R"
    fi
    out=$(pad_capture "cd $PAD_DIR && taskset -c 0-3 timeout $RUN_TIMEOUT \
          env $env_assign $sa ./$QEMU_BIN ./$GUEST $WORKLOAD $n $CELL_SECONDS 2>&1; echo RC=\$?") \
        || { say "    [$mode N=$n] pad injoignable pendant le run"; return 1; }
    rc=$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)
    ops=$(printf '%s' "$out" | grep -oE 'ops_per_sec=[0-9]+' | tail -1 | cut -d= -f2)
    say "    [$mode N=$n] rc=$rc ops_per_sec=${ops:-?} temp_before=$((tb / 1000))C"

    if printf '%s' "$out" | grep -q "code perime"; then
        fail "$mode N=$n : mtbench a detecte du code JIT PERIME execute (regression de" \
             "correctness du cache -tb-cache sur charge smc, PAS un run a exclure). Sortie : " \
             "$(printf '%s' "$out" | grep 'code perime\|ERROR: thread')"
    fi

    if [ "$mode" = "primer" ]; then
        if printf '%s' "$out" | grep -qE "saved [0-9]+ TBs"; then
            say "    [primer N=$n] $(printf '%s' "$out" | grep -oE 'saved [0-9]+ TBs[^\"]*' | head -1)"
        else
            say "    [primer N=$n] AUCUNE ligne 'saved N TBs' -> le cache n'a probablement pas ete ecrit"
        fi
        return 0
    fi

    if [ "$(classify_qemu_rc "${rc:-1}")" = "BENCH_FAIL" ]; then
        fail "$QEMU_BIN : rc=$rc -> ECHEC DE BANC (binaire non executable ou absent), PAS un echec du build teste. Rien a conclure sur l'emulateur."
    fi

    if [ "$mode" = "warm" ]; then
        if printf '%s' "$out" | grep -q "stale or foreign cache"; then
            say "    [$mode N=$n] cache STALE (guest_base/binaire/buffer divergent) -> run EXCLU (n'a pas reellement teste WARM)"
            return 1
        fi
        if ! printf '%s' "$out" | grep -qE "reloaded [1-9][0-9]*/[0-9]+ TBs"; then
            say "    [$mode N=$n] cache NON recharge (0 TB ou message absent) -> run EXCLU"
            return 1
        fi
    fi

    [ "$rc" = "0" ] || { say "    [$mode N=$n] rc=$rc -> EXCLU de la mediane"; return 1; }
    [ -n "$ops" ] || { say "    [$mode N=$n] ligne RESULT absente -> EXCLU"; return 1; }
    printf '%s' "$ops"
}

pad_alive || fail "pad injoignable (allume-le ; cette mesure exige une execution reelle)"

say "=== GATE Z2-2, mtbench $WORKLOAD, N in {$NS}, $REPS repetitions COLD/WARM, cellules ${CELL_SECONDS}s, PAD_CPUS=0-3, $STAMP ==="
say "BINAIRE UNIQUE (compare a lui-meme) : $QEMU_BIN_LOCAL"
say "COLD = sans QEMU_TB_CACHE.  WARM = QEMU_TB_CACHE=<cache pre-amorce> + setarch -R (guest_base fige)."

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
# par N pour chaque mode plutot qu'un tableau associatif indexe par cle composee (meme
# convention que run-z2-1-gate.sh).
MEDIAN_COLD_1=""; MEDIAN_WARM_1=""
MEDIAN_COLD_2=""; MEDIAN_WARM_2=""
MEDIAN_COLD_4=""; MEDIAN_WARM_4=""

for n in $NS; do
    CACHE_PATH="$PAD_DIR/tbcache-smc-N$n.bin"

    say "--- N=$n : run de chauffe (JETE, COLD) ---"
    one_run "$n" "cold" >/dev/null
    sleep "$SETTLE"
    say ""

    COLD_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, COLD $i/$REPS ---"
        if r=$(one_run "$n" "cold"); then COLD_OPS+=("$r"); fi
        sleep "$SETTLE"
    done

    say ""
    say "--- N=$n : amorce du cache (COLD-SAVE) -> $CACHE_PATH ---"
    $PAD_SSH "rm -f '$CACHE_PATH'" 2>/dev/null || true
    one_run "$n" "primer" "$CACHE_PATH" >/dev/null
    sleep "$SETTLE"
    say ""

    WARM_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, WARM $i/$REPS ---"
        if r=$(one_run "$n" "warm" "$CACHE_PATH"); then WARM_OPS+=("$r"); fi
        sleep "$SETTLE"
    done

    say ""
    say "N=$n COLD (n=${#COLD_OPS[@]}) : ${COLD_OPS[*]:-aucun} ops/s"
    say "N=$n WARM (n=${#WARM_OPS[@]}) : ${WARM_OPS[*]:-aucun} ops/s"

    if [ "${#COLD_OPS[@]}" -lt 3 ] || [ "${#WARM_OPS[@]}" -lt 3 ]; then
        say "N=$n : INCONCLUSIF, moins de 3 runs valides sur un bras."
        say ""
        continue
    fi
    MED_COLD=$(median "${COLD_OPS[@]}")
    MED_WARM=$(median "${WARM_OPS[@]}")
    say "N=$n mediane COLD = ${MED_COLD} ops/s   mediane WARM = ${MED_WARM} ops/s"
    case "$n" in
        1) MEDIAN_COLD_1="$MED_COLD"; MEDIAN_WARM_1="$MED_WARM" ;;
        2) MEDIAN_COLD_2="$MED_COLD"; MEDIAN_WARM_2="$MED_WARM" ;;
        4) MEDIAN_COLD_4="$MED_COLD"; MEDIAN_WARM_4="$MED_WARM" ;;
    esac
    say ""
done

say "=== VERDICT ==="
gain_of() {
    local a="$1" b="$2"
    [ -z "$a" ] || [ -z "$b" ] && { printf 'NA'; return; }
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (b-a)/a*100}'
}
GAIN_N1=$(gain_of "$MEDIAN_COLD_1" "$MEDIAN_WARM_1")
GAIN_N2=$(gain_of "$MEDIAN_COLD_2" "$MEDIAN_WARM_2")
GAIN_N4=$(gain_of "$MEDIAN_COLD_4" "$MEDIAN_WARM_4")
say "gain N=1 (WARM vs COLD) = ${GAIN_N1}%  (${MEDIAN_COLD_1:-NA} -> ${MEDIAN_WARM_1:-NA} ops/s)"
say "gain N=2 (WARM vs COLD) = ${GAIN_N2}%  (${MEDIAN_COLD_2:-NA} -> ${MEDIAN_WARM_2:-NA} ops/s)"
say "gain N=4 (WARM vs COLD) = ${GAIN_N4}%  (${MEDIAN_COLD_4:-NA} -> ${MEDIAN_WARM_4:-NA} ops/s)"
say ""
if [ "$GAIN_N2" = "NA" ]; then
    say "GATE Z2-2 : INCONCLUSIF a N=2 (moins de 3 runs valides sur un bras, cf. ci-dessus)."
else
    PASS=$(awk -v g="$GAIN_N2" -v t="$GATE_MIN_GAIN_N2" 'BEGIN{print (g >= t) ? "OUI" : "NON"}')
    say "GATE Z2-2 (gain smc N=2 >= ${GATE_MIN_GAIN_N2}%, meme convention que Z2-1) : $PASS"
fi
say ""
say "CE QUE CA TRANCHE : si le gain WARM est significatif (>= ${GATE_MIN_GAIN_N2}%) a un N quelconque,"
say "l'argument de fermeture mono-thread (\"la traduction n'est pas le goulot\") ne tient plus en"
say "multi-thread et la famille de pistes qu'il a fermee (Z2-2 le dit explicitement) doit etre rouverte."
say "Un gain nul ou negatif CONFIRME l'argument sous une charge qui reecrit son code a chaque tour :"
say "voir le commentaire d'en-tete (le cache ne peut couvrir que le code de demarrage, pas les tours smc)."
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GUEST sha=$GSHA, le binaire $QEMU_BIN_LOCAL"
say "sha=$SHA, le pad dans son etat du jour. torn64/smc-alias restent verifies separement (deja"
say "passes sur ce binaire) ; la correctness SMC-sous-cache est elle auto-verifiee par mtbench"
say "lui-meme a chaque run (voir CORRECTNESS en tete de script)."
say "Log : $LOG"
