#!/bin/bash
# Z3-0, SOUS-LOT 4 (mesure decisive veneers-vs-brique) : isole la CONTRIBUTION DE LA PORTEE
# du chainage direct (la SEULE chose qu'un veneer peut recuperer) du reste du gain tb=32.
#
# Le gain tb=32-vs-tb=256 mesure par Z2-3 (+21,98 % N=2, +17,65 % N=4) melange DEUX causes :
#   (a) la PORTEE du chainage : `B` direct (previsible) contre le repli indirect load-to-PC
#       (vidage de pipeline sur coeur in-order A7) quand la cible sort de +-32 Mo. SEULE cette
#       part est recuperable par un veneer (ilot de saut en portee du `B`).
#   (b) la LOCALITE i-cache + la frequence de `tb_flush`, qu'AUCUN veneer ne recupere.
# Si (a) est petit, le PLAFOND d'un veneer est petit : brique quel que soit le soin
# d'implementation (et les problemes structurels 1-3 du design ne feraient que l'eroder).
#
# Le knob QEMU_NO_DIRECT_CHAIN (commit qemu 6a299ba, `tb_target_set_jmp_target`
# qemu/tcg/arm/tcg-target.c.inc) force TOUT `goto_tb` par le repli indirect meme quand le `B`
# direct serait en portee. Il ne change JAMAIS les resultats (il force le chemin indirect deja
# correct) : aucun gate correctness torn64/smc-alias n'est du par ce banc.
#
# A TB FIXE (defaut 32 Mio : tout le buffer tient dans la portee du `B`), la LOCALITE (a) est
# tenue IDENTIQUE entre les deux bras ; la SEULE difference est la portee (b) :
#   bras A = QEMU_TB_SIZE=$TBSIZE           (chainage direct en portee, reach + locality)
#   bras B = QEMU_TB_SIZE=$TBSIZE +knob     (chainage FORCE indirect, locality tenue, reach coupe)
# Contribution de la portee = A - B. C'est le PLAFOND absolu d'un veneer.
#
# CE QUE CA TRANCHE (gate Z3-0 : gain >= 5 % OU plages disjointes sur N=2 ET N=4) :
#   - A - B petit (plages recouvrantes ET < 5 % a N=2 et/ou N=4) : le plafond veneer est SOUS le
#     gate Z3-0 -> BRIQUE motivee par un chiffre (pas par le raisonnement du design).
#   - A - B grand (>= 5 % ou plages disjointes aux DEUX N) : les veneers ont de la marge sur le
#     plafond -> on prototype malgre les problemes structurels 1-3 du design (sous-lot 3).
#
# Structure ABAB + medianes + garde thermique + verrou anti-empilement reprise de
# run-z2-3-gate.sh, mais l'ENV qui varie est le KNOB a TB fixe, pas QEMU_TB_SIZE. UN SEUL
# binaire compare a lui-meme (le binaire porteur du knob, sous-lot 3).
#
# Usage :
#   test/run-z3-0-knob.sh <qemuBin> [reps] [seconds] [Ns] [tbSizeMiB]
#     qemuBin   : nom du binaire dans build-out/ (porteur du knob ; deploye une seule fois)
#     reps      : repetitions par N et par bras (defaut 3, minimum protocolaire)
#     seconds   : duree de cellule mtbench (defaut 60)
#     Ns        : liste des N a mesurer (defaut "2 4", cf. libelle Z3-0 : PAS N=1)
#     tbSizeMiB : QEMU_TB_SIZE FIXE des deux bras (defaut 32 : buffer entier en portee du `B`)
#
# Exemple :
#   test/run-z3-0-knob.sh qemu-aarch64 3 60 "2 4" 32
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BIN_LOCAL="${1:?usage: run-z3-0-knob.sh <qemuBin> [reps] [seconds] [Ns] [tbSizeMiB]}"
REPS="${2:-3}"
CELL_SECONDS="${3:-60}"
NS="${4:-2 4}"
TBSIZE="${5:-32}"
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/z3-0-knob-$STAMP.txt"
RAWFILE="$LOGDIR/z3-0-knob-$STAMP.raw"   # lignes "N ARM OPS" des runs valides, pour la mediane
PAD_FAIL_PREFIX="Z3-0 KNOB"
QEMU_BIN="qemu-z30k"   # pad_really_idle exclut ce nom via QEMU_BIN (deploye sous ce nom)

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# VERROU ANTI-EMPILEMENT (meme mecanique que run-z2-3-gate.sh/run-z3-0-tbsweep.sh : plusieurs
# instances lancees par des iterations successives de la boucle contamineraient la meme
# mesure). mkdir est atomique, portable (flock absent de macOS).
LOCKDIR="$REPO_ROOT/.monitor/.z3-0-knob.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OTHER_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        fail "une autre instance de run-z3-0-knob.sh tourne deja (pid $OTHER_PID, verrou $LOCKDIR) : ce banc exige une seule instance a la fois"
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
# fonction que run-z2-3-gate.sh/run-z3-0-tbsweep.sh ; dupliquee faute d'un point d'inclusion
# commun entre bancs, dette DRY pre-existante notee aux revues 80/85/88/95/96).
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

# Un run mtbench smc. $1 = N, $2 = bras ("a"=direct|"b"=indirect force). Imprime ops_per_sec
# sur stdout, ou rien pour un run invalide. FAIL immediat (pas exclusion silencieuse) si le
# marqueur SMC execute est perime : regression de correctness, independante du knob.
one_run() {
    local n="$1" arm="$2" knobenv out rc ops i tb
    # bras A = chainage direct ; bras B = repli indirect force (knob). TB tenu FIXE des deux cotes.
    [ "$arm" = "b" ] && knobenv="QEMU_NO_DIRECT_CHAIN=1" || knobenv=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pad_really_idle && break
        say "    pad occupe (autre qemu ou transfert en cours), attente $i/10..."
        sleep 30
        [ "$i" = 10 ] && fail "le pad reste occupe par un autre processus : mesure abandonnee plutot que contaminee"
    done
    tb=$(wait_cool)

    out=$(pad_capture "cd $PAD_DIR && taskset -c 0-3 timeout $RUN_TIMEOUT \
          env QEMU_TB_SIZE=$TBSIZE $knobenv ./$QEMU_BIN ./$GUEST $WORKLOAD $n $CELL_SECONDS 2>&1; echo RC=\$?") \
        || { say "    [arm=$arm N=$n] pad injoignable pendant le run"; return 1; }
    rc=$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)
    ops=$(printf '%s' "$out" | grep -oE 'ops_per_sec=[0-9]+' | tail -1 | cut -d= -f2)
    say "    [arm=$arm (tb=$TBSIZE${knobenv:+ $knobenv}) N=$n] rc=$rc ops_per_sec=${ops:-?} temp_before=$((tb / 1000))C"

    if printf '%s' "$out" | grep -q "code perime"; then
        fail "arm=$arm N=$n : mtbench a detecte du code JIT PERIME execute (regression de" \
             "correctness independante du knob, PAS un run a exclure). Sortie : " \
             "$(printf '%s' "$out" | grep 'code perime\|ERROR: thread')"
    fi

    if [ "$(classify_qemu_rc "${rc:-1}")" = "BENCH_FAIL" ]; then
        fail "$QEMU_BIN : rc=$rc -> ECHEC DE BANC (binaire non executable ou absent), PAS un echec du build teste. Rien a conclure sur l'emulateur."
    fi

    [ "$rc" = "0" ] || { say "    [arm=$arm N=$n] rc=$rc -> EXCLU de la mediane"; return 1; }
    [ -n "$ops" ] || { say "    [arm=$arm N=$n] ligne RESULT absente -> EXCLU"; return 1; }
    printf '%s' "$ops"
}

pad_alive || fail "pad injoignable (allume-le ; cette mesure exige une execution reelle)"

say "=== Z3-0 KNOB, mtbench $WORKLOAD, N in {$NS}, $REPS repetitions ABAB, cellules ${CELL_SECONDS}s, PAD_CPUS=0-3, tb=$TBSIZE fixe, $STAMP ==="
say "BINAIRE UNIQUE (compare a lui-meme, seul le knob QEMU_NO_DIRECT_CHAIN varie) : $QEMU_BIN_LOCAL"
say "bras A = QEMU_TB_SIZE=$TBSIZE               (chainage direct en portee : reach + locality)"
say "bras B = QEMU_TB_SIZE=$TBSIZE QEMU_NO_DIRECT_CHAIN=1  (chainage force indirect : locality tenue, reach coupe)"
say "A - B = contribution de la PORTEE = plafond absolu d'un veneer"

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
say "  hote pad : $(pad_capture 'uname -srm; nproc' | tr '\n' ' ')"
say ""

: >"$RAWFILE"

# Bash associatif (declare -A) est bash>=4 : le bash systeme de macOS est 3.2. Un scalaire
# par N pour chaque bras (meme convention que run-z2-3-gate.sh).
MEDIAN_A_2=""; MEDIAN_B_2=""
MEDIAN_A_4=""; MEDIAN_B_4=""
MINMAX_A_2=""; MINMAX_B_2=""
MINMAX_A_4=""; MINMAX_B_4=""

minmax() {
    # STDOUT = "min max" des valeurs passees (tri numerique).
    local sorted
    sorted=$(printf '%s\n' "$@" | sort -n)
    printf '%s %s' "$(printf '%s\n' "$sorted" | head -1)" "$(printf '%s\n' "$sorted" | tail -1)"
}

for n in $NS; do
    say "--- N=$n : run de chauffe (JETE, bras B) ---"
    one_run "$n" "b" >/dev/null
    sleep "$SETTLE"
    say ""

    A_OPS=(); B_OPS=()
    for i in $(seq 1 "$REPS"); do
        say "--- N=$n, paire $i/$REPS ---"
        if r=$(one_run "$n" "a"); then A_OPS+=("$r"); printf '%s a %s\n' "$n" "$r" >>"$RAWFILE"; fi
        sleep "$SETTLE"
        if r=$(one_run "$n" "b"); then B_OPS+=("$r"); printf '%s b %s\n' "$n" "$r" >>"$RAWFILE"; fi
        sleep "$SETTLE"
    done

    say ""
    say "N=$n A, direct   (n=${#A_OPS[@]}) : ${A_OPS[*]:-aucun} ops/s"
    say "N=$n B, indirect (n=${#B_OPS[@]}) : ${B_OPS[*]:-aucun} ops/s"

    if [ "${#A_OPS[@]}" -lt 3 ] || [ "${#B_OPS[@]}" -lt 3 ]; then
        say "N=$n : INCONCLUSIF, moins de 3 runs valides sur un bras."
        say ""
        continue
    fi
    MED_A=$(median "${A_OPS[@]}")
    MED_B=$(median "${B_OPS[@]}")
    say "N=$n mediane A (direct) = ${MED_A} ops/s   mediane B (indirect) = ${MED_B} ops/s"
    case "$n" in
        2) MEDIAN_A_2="$MED_A"; MEDIAN_B_2="$MED_B"; MINMAX_A_2="$(minmax "${A_OPS[@]}")"; MINMAX_B_2="$(minmax "${B_OPS[@]}")" ;;
        4) MEDIAN_A_4="$MED_A"; MEDIAN_B_4="$MED_B"; MINMAX_A_4="$(minmax "${A_OPS[@]}")"; MINMAX_B_4="$(minmax "${B_OPS[@]}")" ;;
    esac
    say ""
done

say "=== VERDICT (contribution de la portee A - B = plafond veneer) ==="
gain_of() {
    local a="$1" b="$2"
    { [ -z "$a" ] || [ -z "$b" ]; } && { printf 'NA'; return; }
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%+.2f", (a-b)/b*100}'
}
GAIN_N2=$(gain_of "$MEDIAN_A_2" "$MEDIAN_B_2")
GAIN_N4=$(gain_of "$MEDIAN_A_4" "$MEDIAN_B_4")
say "A - B, N=2 = ${GAIN_N2}%  (B/indirect ${MEDIAN_B_2:-NA} -> A/direct ${MEDIAN_A_2:-NA} ops/s ; plages A=[${MINMAX_A_2:-NA}] B=[${MINMAX_B_2:-NA}])"
say "A - B, N=4 = ${GAIN_N4}%  (B/indirect ${MEDIAN_B_4:-NA} -> A/direct ${MEDIAN_A_4:-NA} ops/s ; plages A=[${MINMAX_A_4:-NA}] B=[${MINMAX_B_4:-NA}])"
say ""

# Verdict par N : gate Z3-0 = gain >= 5 % OU plages disjointes (A min > B max). Le plafond
# veneer est A - B : s'il ne passe pas le gate ici, aucun veneer ne le passera (il ne peut que
# recuperer une PART de A - B, erodee par les problemes 1-3 du design).
verdict_of() {
    local ma="$1" mb="$2" mmA="$3" mmB="$4" n="$5" amin bmax disjoint pct
    if [ -z "$ma" ] || [ -z "$mb" ]; then
        say "GATE Z3-0 (plafond veneer) N=$n : INCONCLUSIF (moins de 3 runs valides sur un bras)."
        return
    fi
    amin=$(printf '%s' "$mmA" | awk '{print $1}')
    bmax=$(printf '%s' "$mmB" | awk '{print $2}')
    disjoint=0
    [ -n "$amin" ] && [ -n "$bmax" ] && [ "$amin" -gt "$bmax" ] && disjoint=1
    pct=$(awk -v a="$ma" -v b="$mb" 'BEGIN{d=(a-b)/b*100; printf "%.2f", (d<0?-d:d)}')
    if [ "$disjoint" -eq 1 ] || awk -v p="$pct" 'BEGIN{exit !(p>=5)}'; then
        say "GATE Z3-0 (plafond veneer) N=$n : A - B >= 5 % OU plages disjointes (ecart ${pct}%, disjoint=$disjoint) -> la portee du chainage direct PORTE un gain reel a ce N ; un veneer aurait de la MARGE sur ce plafond."
    else
        say "GATE Z3-0 (plafond veneer) N=$n : A - B < 5 % ET plages recouvrantes (ecart ${pct}%) -> la portee du chainage direct est SOUS le gate a ce N ; le plafond d'un veneer est deja sous le seuil, brique motivee par un chiffre."
    fi
}
verdict_of "$MEDIAN_A_2" "$MEDIAN_B_2" "$MINMAX_A_2" "$MINMAX_B_2" 2
verdict_of "$MEDIAN_A_4" "$MEDIAN_B_4" "$MINMAX_A_4" "$MINMAX_B_4" 4
say ""
say "CE QUE CA TRANCHE : le gate Z3-0 exige un gain >= 5 % OU plages disjointes sur N=2 ET N=4."
say "A - B est le PLAFOND ABSOLU d'un veneer (il ne recupere QUE la portee, jamais la locality)."
say "Si A - B ne passe pas le gate aux DEUX N, aucun veneer ne le passera -> BRIQUE. S'il le"
say "passe aux deux, les veneers ont de la marge sur le plafond -> prototypage malgre les"
say "problemes structurels 1-3 du design (allocation, pas de free, double-saut ; sous-lot 3)."
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GUEST sha=$GSHA, le binaire $QEMU_BIN_LOCAL"
say "sha=$SHA, le pad dans son etat du jour. Le knob ne force que le chemin indirect DEJA correct"
say "(no-op quand absent, cf. sous-lot 3) : torn64/smc-alias restent ceux deja verts sur ce"
say "binaire, pas re-testes ici. mtbench (empreinte code minuscule) modelise la PORTEE du"
say "chainage, PAS le compromis memoire d'un gros invite (grok/claude/JSC)."
say "Log : $LOG   (donnees brutes : $RAWFILE)"
