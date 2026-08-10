#!/bin/bash
# X2, A/B wall-clock de QEMU_TB_SIZE (32 Mio, tout le code invite tient dans la portee
# +-32 Mo du chainage direct, contre 256 Mio, la valeur en usage partout ailleurs dans
# le projet). MEME binaire deja deploye sur le pad (aucun scp ici, cf. ab-nzcv.sh) :
# seul l'ENV varie. Au-dela de +-32 Mo, `tb_target_set_jmp_target`
# (qemu/tcg/arm/tcg-target.c.inc) ecrit un NOP a la place du `B` direct et retombe
# silencieusement sur le chemin indirect (LDR PC via une constante proche). Regime
# JIT-ACTIF (BUN_JSC_useJIT=1), le seul juge retenu depuis la phase Z (cf. run-qemu-ab.sh).
#
# CE QUE CA TRANCHE (PROGRESS.md, case X2) : si A (32 Mio, tout en portee) egale ou
# depasse B (256 Mio) malgre un cache 8x plus petit (donc des flush plus frequents), la
# perte de chainage direct est reelle. Si B reste nettement plus rapide, le cout d'un
# cache reduit domine et X2 ferme sans piste de suite (les veneers ne sont pas motives).
#
# Usage : test/ab-tbsize.sh [runs_par_bras] [mode]
#   runs_par_bras : nombre de couples A/B (defaut 4, >= 3 exige par le protocole)
#   mode          : help (defaut) | version
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-4}"
MODE="${2:-help}"
LOGDIR="$REPO_ROOT/test/logs/x2-tbsize"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/ab-tbsize-$STAMP.txt"

TIMEOUT="${TBSIZE_TIMEOUT:-600}"
SETTLE="${SETTLE:-45}"
# JIT invite ACTIF (regime produit) : QEMU_TB_SIZE est LE PARAMETRE compare, jamais
# fixe dans ce combo commun.
COMMON_ENV="BUN_JSC_useJIT=1 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

say() { echo "$@" | tee -a "$LOG" >&2; }

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

# $1 = A|B -> imprime "elapsed:octets" sur stdout, ou rien si le run est invalide
# (narration sur stderr via `say`, cf. la regle d'entete de pad-lib.sh).
one_run() {
    local arm="$1" tbsize extra out res rc elapsed bytes
    [ "$arm" = "A" ] && tbsize=32 || tbsize=256
    extra="QEMU_TB_SIZE=$tbsize $COMMON_ENV"
    out=$(CLAUDE_CPUS=0,1 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$extra" \
          bash "$REPO_ROOT/test/run-claude-pad.sh" "$MODE" "$TIMEOUT" 2>&1)
    printf '%s\n' "$out" >>"$LOG"
    res=$(printf '%s' "$out" | grep -oE "RESULT=[A-Z_]+ exit_rc=[0-9]+ elapsed=[0-9]+ out_bytes=[0-9]+" | head -1)
    [ -n "$res" ] || { say "    [$arm tb=$tbsize] AUCUNE ligne RESULT -> run invalide"; return 1; }
    rc=$(printf '%s' "$res" | grep -oE "exit_rc=[0-9]+" | cut -d= -f2)
    elapsed=$(printf '%s' "$res" | grep -oE "elapsed=[0-9]+" | cut -d= -f2)
    bytes=$(printf '%s' "$res" | grep -oE "out_bytes=[0-9]+" | cut -d= -f2)
    say "    [$arm tb=$tbsize] $res"
    case "$res" in
        RESULT=BOOTED*) ;;
        *) say "    [$arm tb=$tbsize] pas BOOTED -> exclu de la mediane"; return 1 ;;
    esac
    [ "$rc" = "0" ] || { say "    [$arm tb=$tbsize] exit_rc=$rc != 0 -> exclu de la mediane"; return 1; }
    printf '%s:%s' "$elapsed" "$bytes"
}

say "=== X2, A/B wall-clock QEMU_TB_SIZE, mode=$MODE, $RUNS paires (ABAB), $STAMP ==="
say "env commun : $COMMON_ENV"
say "bras A = QEMU_TB_SIZE=32  (tout le code invite dans la portee +-32 Mo)"
say "bras B = QEMU_TB_SIZE=256 (valeur en usage partout ailleurs dans le projet)"
say ""

say "--- run de chauffe (JETE, amorce le cache) ---"
one_run B >/dev/null || say "    (chauffe non concluante, on continue : elle n'entre dans aucune mediane)"
sleep "$SETTLE"
say ""

A_T=(); B_T=(); A_BYTES=""; B_BYTES=""
for i in $(seq 1 "$RUNS"); do
    say "--- paire $i/$RUNS ---"
    if r=$(one_run A); then A_T+=("${r%%:*}"); A_BYTES="${r##*:}"; fi
    sleep "$SETTLE"
    if r=$(one_run B); then B_T+=("${r%%:*}"); B_BYTES="${r##*:}"; fi
    sleep "$SETTLE"
done

say ""
say "=== RESULTATS ==="
say "A (tb=32,  n=${#A_T[@]}) : ${A_T[*]:-aucun}"
say "B (tb=256, n=${#B_T[@]}) : ${B_T[*]:-aucun}"
say "octets rendus : A=${A_BYTES:-?} B=${B_BYTES:-?}"
[ "${A_BYTES:-0}" = "${B_BYTES:-1}" ] \
    || say "ATTENTION : les deux bras ne rendent PAS la meme taille de sortie, la comparaison n'a pas de sens tant que ce n'est pas explique."

if [ "${#A_T[@]}" -lt 3 ] || [ "${#B_T[@]}" -lt 3 ]; then
    say "VERDICT : INCONCLUSIF, moins de 3 runs valides par bras."
    say "Log : $LOG"
    exit 2
fi

MA=$(median "${A_T[@]}"); MB=$(median "${B_T[@]}")
say "mediane A (tb=32) = ${MA}s   mediane B (tb=256) = ${MB}s"
GAIN=$(awk -v a="$MB" -v b="$MA" 'BEGIN{printf "%+.2f", (a-b)/a*100}')
say "A vs B : $GAIN %  (positif = A, cache 32 Mio, est PLUS RAPIDE que B, cache 256 Mio)"
say ""
if [ "$MA" -le "$MB" ]; then
    say "VERDICT : A egale ou depasse B malgre un cache 8x plus petit -> la perte de chainage direct au-dela de +-32 Mo est REELLE."
else
    say "VERDICT : B (cache 256 Mio) reste plus rapide -> le cout d'un cache reduit domine, X2 FERME sans gain demontre a ce protocole."
fi
say "RAPPEL DE PORTEE : ce chiffre vaut pour la charge '$MODE', l'invite deploye, le pad dans son etat du jour. Il ne dit RIEN d'une autre charge."
say "Log : $LOG"
