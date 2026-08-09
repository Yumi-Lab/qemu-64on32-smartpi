#!/bin/bash
# V4-2, A/B WALL-CLOCK de la dedup de TB en regime JIT-ACTIF (le seul juge).
#
# Protocole (cf. PROGRESS.md, case V4-2) : flag ON vs OFF, alternance ABAB, medianes sur
# >= 3 runs par bras. GATE : gain median >= 2 % sans regression de correctness => candidat
# merge ; sinon fermeture chiffree.
#
# POURQUOI `--help` PAR DEFAUT : le mode `-p` exige une authentification (le pad n'en a pas,
# c'est un gate humain). `--help` fait l'init CLI COMPLETE et un rendu, en JIT-actif, SANS
# reseau ni auth : c'est la charge JS reelle, mesurable en autonomie. Quand une cle sera
# disponible, rejouer avec MODE=prompt pour couvrir le tour agent.
#
# Discipline pad : deleguee a run-claude-pad.sh (un seul qemu a la fois, taskset, MemoryMax,
# timeout, garde thermique) + un palier inconditionnel entre deux runs (cf. le gel du
# 2026-07-31 : enchainer sans respirer met la carte par terre).
#
# ATTENTION SEUIL : ne JAMAIS juger contre une constante d'un autre banc. Le pad a perdu son
# overclock au reflash (1296 MHz max, 1200 MHz observe, contre 1368 MHz a l'epoque des
# calibrations). Ce script ne compare QUE ON vs OFF, mesures le meme jour, en alternance.
#
# Usage : test/run-v42-ab.sh [paires] [mode]
#   paires : nombre de couples ON/OFF (defaut 4 -> 4 mesures par bras)
#   mode   : help (defaut) | version | prompt (prompt exige une cle sur le pad)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$REPO_ROOT/test/logs/v42-ab"
PAIRS="${1:-4}"
MODE="${2:-help}"
SETTLE="${SETTLE:-45}"
RUN_TIMEOUT="${RUN_TIMEOUT:-1800}"

# JIT ACTIF : c'est tout l'objet de la case (la campagne close n'avait profile que le jitless).
COMMON_ENV="QEMU_TB_SIZE=256 BUN_JSC_useJIT=1 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/v42-ab-$STAMP.txt"
# IMPERATIF : `say` ecrit sur STDERR (pas stdout). `one_run` est capturee par $(...) et son
# SEUL stdout doit etre l'elapsed. Sans ca les traces se retrouvent DANS la valeur mesuree et
# les medianes sont du bruit. C'est le meme piege que celui corrige le 2026-08-01 dans
# run-v41g-gate.sh et diag-claude-sigtrap.sh -- il se retend a chaque fonction "qui affiche
# ET qui rend une valeur".
say() { echo "$@" | tee -a "$LOG" >&2; }

median() {  # medianes sur liste d'entiers passee en arguments
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

one_run() {  # $1 = ON|OFF -> imprime l'elapsed, ou rien si le run est invalide
    local arm="$1" extra out res rc elapsed
    extra="$COMMON_ENV"
    [ "$arm" = "ON" ] && extra="QEMU_TB_DEDUP=1 $extra"
    out=$(CLAUDE_CPUS=0,1 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$extra" \
          bash "$REPO_ROOT/test/run-claude-pad.sh" "$MODE" "$RUN_TIMEOUT" 2>&1)
    printf '%s\n' "$out" >>"$LOG"
    res=$(printf '%s' "$out" | grep -oE "RESULT=[A-Z_]+ exit_rc=[0-9]+ elapsed=[0-9]+ out_bytes=[0-9]+" | head -1)
    [ -n "$res" ] || { say "    [$arm] AUCUNE ligne RESULT -> run invalide"; return 1; }
    rc=$(printf '%s' "$res" | grep -oE "exit_rc=[0-9]+" | cut -d= -f2)
    elapsed=$(printf '%s' "$res" | grep -oE "elapsed=[0-9]+" | cut -d= -f2)
    say "    [$arm] $res"
    # Un run qui n'a pas boote proprement ne rentre PAS dans la mediane : on ne compare
    # que des runs comparables (sinon un echec rapide passerait pour un gain).
    case "$res" in
        RESULT=BOOTED*) ;;
        *) say "    [$arm] pas BOOTED -> exclu de la mediane"; return 1 ;;
    esac
    [ "$rc" = "0" ] || { say "    [$arm] exit_rc=$rc != 0 -> exclu de la mediane"; return 1; }
    printf '%s' "$elapsed"
}

say "=== V4-2, A/B wall-clock JIT-ACTIF, mode=$MODE, $PAIRS paires (ABAB), $STAMP ==="
say "env commun : $COMMON_ENV"
say "bras ON = QEMU_TB_DEDUP=1 ; bras OFF = flag absent"
say ""

# RUN DE CHAUFFE, JETE. Le binaire invite pese ~258 Mo : le premier run le lit depuis la carte
# SD a froid et paie aussi les caches internes de l'emulateur. Mesure du 2026-08-01 : un premier
# run --help a 286 s suivi d'un second a 60 s, MEME sortie (16036 octets). Sans chauffe, le
# premier bras de l'alternance est systematiquement penalise et l'A/B mesure l'ordre, pas le flag.
say "--- run de chauffe (JETE, amorce le cache) ---"
one_run OFF >/dev/null || say "    (chauffe non concluante, on continue : elle n'entre dans aucune mediane)"
sleep "$SETTLE"
say ""

ON_TIMES=(); OFF_TIMES=()
for i in $(seq 1 "$PAIRS"); do
    say "--- paire $i/$PAIRS ---"
    if t=$(one_run ON); then ON_TIMES+=("$t"); fi
    sleep "$SETTLE"
    if t=$(one_run OFF); then OFF_TIMES+=("$t"); fi
    sleep "$SETTLE"
done

say ""
say "=== RESULTATS ==="
say "ON  (n=${#ON_TIMES[@]}) : ${ON_TIMES[*]:-aucun}"
say "OFF (n=${#OFF_TIMES[@]}) : ${OFF_TIMES[*]:-aucun}"

if [ "${#ON_TIMES[@]}" -lt 3 ] || [ "${#OFF_TIMES[@]}" -lt 3 ]; then
    say "VERDICT : INCONCLUSIF, moins de 3 runs valides par bras (le protocole en exige >= 3)."
    say "Log : $LOG"
    exit 2
fi

MON=$(median "${ON_TIMES[@]}")
MOFF=$(median "${OFF_TIMES[@]}")
say "mediane ON  = ${MON}s"
say "mediane OFF = ${MOFF}s"

# gain en % = (OFF - ON) / OFF * 100, en centiemes pour eviter le flottant
GAIN_C=$(( (MOFF - MON) * 10000 / MOFF ))          # centiemes de %, pour la comparaison entiere
GAIN_PCT=$(awk -v a="$MOFF" -v b="$MON" 'BEGIN{printf "%+.2f", (a-b)/a*100}')
say "gain median = $GAIN_PCT % (positif = la dedup accelere)"
if [ "$GAIN_C" -ge 200 ]; then
    say "VERDICT : GAIN >= 2 % -> candidat merge, dossier a monter pour le gate humain."
else
    say "VERDICT : GAIN < 2 % -> FERMETURE CHIFFREE (la dedup marche mais ne rend pas)."
fi
say "Log : $LOG"
