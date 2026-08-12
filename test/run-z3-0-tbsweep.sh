#!/bin/bash
# Z3-0, ETAPE 1 (l'alternative "a evaluer en premier si plus simple" de la case Z3-0) :
# BALAYER QEMU_TB_SIZE sur plusieurs tailles de cache, pas seulement 32 contre 256, pour
# repondre a la question de conception AVANT de coder des veneers : la perte de chainage
# direct au-dela de +-32 Mo (mesuree par Z2-3 : +21,98 % a N=2, +17,65 % a N=4 pour tb=32
# vs tb=256) est-elle une FALAISE a ~32 Mo (auquel cas aucune taille de cache realiste ne la
# recupere pour un invite qui brasse plus de 32 Mo de code, donc SEULS des veneers la
# corrigent) ou une PENTE (auquel cas une taille de compromis, ex. 64/128 Mo, en recupere une
# part sans le facteur 8 de perte de cache du tb=32, ce qui rendrait les veneers non motives) ?
#
# La portee `B` de l'hote armv7 est +-32 Mo (ARM ARM). Au-dela, `tb_target_set_jmp_target`
# (qemu/tcg/arm/tcg-target.c.inc:1821) ecrit un NOP a la place du `B` direct et le TB retombe
# sur le chemin indirect (LDR PC via constante proche, cf. tcg_out_goto_tb:1790) : un vidage
# de pipeline sur coeur in-order. Sur mtbench smc (empreinte code minuscule), la SEULE chose
# que change QEMU_TB_SIZE est la DERIVE du pointeur de bump sous le brassage SMC : plus le
# buffer est grand, plus les TB reforges s'eloignent des anciens et sortent de portee du `B`.
# Le defaut publie sur hote 32 bits est deja 32 Mio (tcg/region.c:467) ; le projet surcharge a
# 256 Mio partout (aide les gros invites grok/claude a ne pas thrasher le cache). Ce banc
# n'introduit AUCUN patch : seul l'ENV QEMU_TB_SIZE varie, sur le binaire de PRODUCTION publie.
# torn64/smc-alias restent ceux deja verifies sur ce binaire (correctness inchangee).
#
# Structure (medianes + garde thermique + verrou anti-empilement + exclusion "un seul qemu")
# reprise telle quelle de run-z2-3-gate.sh, mais un BALAYAGE de N tailles au lieu du couple
# A/B, en interleaving (chaque repetition parcourt toutes les tailles) pour que la derive
# thermique/temporelle frappe egalement chaque taille.
#
# Usage :
#   test/run-z3-0-tbsweep.sh <qemuBin> [reps] [seconds] [Ns] [sizesMiB]
#     qemuBin  : nom du binaire dans build-out/ (deploye une seule fois, teste a chaque taille)
#     reps     : repetitions par (N, taille) (defaut 3, minimum protocolaire)
#     seconds  : duree de cellule mtbench (defaut 60)
#     Ns       : liste des N a mesurer (defaut "2 4", cf. libelle Z3-0 : PAS N=1)
#     sizesMiB : liste des QEMU_TB_SIZE a balayer (defaut "32 64 128 256", 256 = baseline publie)
#
# Exemple :
#   test/run-z3-0-tbsweep.sh qemu-aarch64 3 60 "2 4" "32 64 128 256"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/mtbench"

QEMU_BIN_LOCAL="${1:?usage: run-z3-0-tbsweep.sh <qemuBin> [reps] [seconds] [Ns] [sizesMiB]}"
REPS="${2:-3}"
CELL_SECONDS="${3:-60}"
NS="${4:-2 4}"
SIZES="${5:-32 64 128 256}"
BASELINE_SIZE="${BASELINE_SIZE:-256}"   # taille de reference (chemin publie) pour le calcul de gain
SETTLE="${SETTLE:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
GUEST="mtbench"
WORKLOAD="smc"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/z3-0-tbsweep-$STAMP.txt"
RAWFILE="$LOGDIR/z3-0-tbsweep-$STAMP.raw"   # lignes "N SIZE OPS" des runs valides, pour la mediane
PAD_FAIL_PREFIX="Z3-0 TBSWEEP"
QEMU_BIN="qemu-z30"   # pad_really_idle doit exclure ce nom (deploye sous ce nom, cf. deploy)

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# VERROU ANTI-EMPILEMENT (meme mecanique que run-z2-3-gate.sh : jusqu'a 5 instances lancees
# par des iterations successives de la boucle contaminaient la meme mesure). mkdir est
# atomique, portable (flock absent de macOS).
LOCKDIR="$REPO_ROOT/.monitor/.z3-0-tbsweep.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OTHER_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        fail "une autre instance de run-z3-0-tbsweep.sh tourne deja (pid $OTHER_PID, verrou $LOCKDIR) : ce banc exige une seule instance a la fois"
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
# fonction que run-z2-3-gate.sh ; dupliquee faute d'un point d'inclusion commun entre bancs).
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

# Un run mtbench smc. $1 = N, $2 = QEMU_TB_SIZE (MiB). Imprime ops_per_sec sur stdout, ou
# rien pour un run invalide. FAIL immediat (pas exclusion silencieuse) si le marqueur SMC
# execute est perime : regression de correctness, independante de QEMU_TB_SIZE.
one_run() {
    local n="$1" tbsize="$2" out rc ops i tb
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

say "=== Z3-0 TBSWEEP, mtbench $WORKLOAD, N in {$NS}, tailles {$SIZES} MiB, $REPS repetitions interleaved, cellules ${CELL_SECONDS}s, PAD_CPUS=0-3, $STAMP ==="
say "BINAIRE UNIQUE (compare a lui-meme, seul QEMU_TB_SIZE varie) : $QEMU_BIN_LOCAL"
say "baseline (chemin publie) = QEMU_TB_SIZE=$BASELINE_SIZE MiB"

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

for n in $NS; do
    say "--- N=$n : run de chauffe (JETE, tb=$BASELINE_SIZE) ---"
    one_run "$n" "$BASELINE_SIZE" >/dev/null
    sleep "$SETTLE"
    say ""

    for rep in $(seq 1 "$REPS"); do
        say "--- N=$n, repetition $rep/$REPS (balayage de toutes les tailles) ---"
        for size in $SIZES; do
            if r=$(one_run "$n" "$size"); then
                printf '%s %s %s\n' "$n" "$size" "$r" >>"$RAWFILE"
            fi
            sleep "$SETTLE"
        done
    done
    say ""
done

say "=== VERDICT (mediane par taille, gain vs baseline tb=$BASELINE_SIZE) ==="
gain_of() {
    local a="$1" b="$2"
    { [ -z "$a" ] || [ -z "$b" ]; } && { printf 'NA'; return; }
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%+.2f", (a-b)/b*100}'
}

for n in $NS; do
    say "N=$n :"
    base_vals=$(awk -v n="$n" -v s="$BASELINE_SIZE" '$1==n && $2==s {print $3}' "$RAWFILE")
    # shellcheck disable=SC2086
    base_cnt=$(printf '%s\n' $base_vals | grep -c . || true)
    if [ "${base_cnt:-0}" -lt 3 ]; then
        say "  baseline tb=$BASELINE_SIZE : moins de 3 runs valides ($base_cnt) -> N=$n INCONCLUSIF"
        say ""
        continue
    fi
    # shellcheck disable=SC2086
    base_med=$(median $base_vals)
    for size in $SIZES; do
        vals=$(awk -v n="$n" -v s="$size" '$1==n && $2==s {print $3}' "$RAWFILE")
        # shellcheck disable=SC2086
        cnt=$(printf '%s\n' $vals | grep -c . || true)
        if [ "${cnt:-0}" -lt 3 ]; then
            say "  tb=$size MiB : mediane NA (moins de 3 runs valides : $cnt)"
            continue
        fi
        # shellcheck disable=SC2086
        med=$(median $vals)
        g=$(gain_of "$med" "$base_med")
        say "  tb=$size MiB (n=$cnt) : mediane $med ops/s   gain vs tb=$BASELINE_SIZE = $g %"
    done
    say ""
done

say "CE QUE CA TRANCHE : si le gain de tb=32 vs tb=$BASELINE_SIZE se retrouve deja aux tailles"
say "intermediaires (64/128 MiB), une taille de COMPROMIS recupere le chainage sans le facteur 8"
say "de perte de cache du tb=32, et les veneers ne sont pas motives (option simple retenue)."
say "Si au contraire seul tb=32 est rapide et que 64/128/256 sont proches (FALAISE a ~32 Mo),"
say "aucune taille realiste ne recupere le chainage pour un invite qui brasse plus de 32 Mo de"
say "code : SEULS des veneers (ilot de saut en portee du B) le peuvent -> conception veneers."
say ""
say "RAPPEL DE PORTEE : ces chiffres valent pour l'invite $GUEST sha=$GSHA, le binaire"
say "$QEMU_BIN_LOCAL sha=$SHA, le pad dans son etat du jour. Aucun patch n'est introduit ici"
say "(seul l'ENV QEMU_TB_SIZE varie) : torn64/smc-alias restent ceux deja verifies sur ce"
say "binaire, pas re-testes. mtbench (empreinte code minuscule) ne modelise PAS la pression de"
say "cache d'un vrai invite : ce banc mesure la PORTEE DU CHAINAGE, pas le compromis memoire"
say "complet d'un gros invite (cette part relevera de la conception, pas de ce balayage)."
say "Log : $LOG   (donnees brutes : $RAWFILE)"
