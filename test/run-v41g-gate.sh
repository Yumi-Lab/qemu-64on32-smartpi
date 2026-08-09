#!/bin/bash
# V4-1G, gate de CORRECTNESS sur le pad pour la dedup de TB (QEMU_TB_DEDUP=1).
# Un seul point d'entree pour toute la checklist de la case V4-1G, afin que le run
# soit UNE commande le jour ou le pad est joignable (il ne l'etait pas au moment
# ou ce script a ete ecrit, cf. .gate-handoff).
#
# Checklist executee, dans cet ordre (un echec fait echouer le gate) :
#   1. torn64 N=4 180 s, flag OFF : non-regression du chemin publie, et reference du jour
#   2. torn64 N=4 180 s, flag ON  : 0 dechirure ET \>= TORN_ON_MIN_PCT % du bras OFF
#   3. simd-dup2, flag ON         : "OK: dup2_vec correct"
#   4. smc-alias sync, flag ON    : "SUCCESS: code frais execute a chaque tour"
#   5. claude --version, flag ON  : RESULT=BOOTED, rc=0
#   6. claude -p JIT-actif, ON    : rend une sortie (result success)
#
# Les items 1 a 4 tournent ici (guests statiques, deployes par ce script). Les
# items 5 et 6 sont delegues a test/run-claude-pad.sh, qui porte deja la garde
# thermique fine, le scope systemd et la verification de deploiement du binaire
# natif de 247 Mo (que ce script ne pousse donc PAS).
#
# Regles pad GOAL.md respectees : sha verifie des deux cotes avant tout run (piege
# du sha), un seul qemu a la fois, taskset 2 coeurs, timeout dur, temperature lue
# avant et apres chaque run, refus au-dela de PAD_MAX_TEMP.
#
# Usage : test/run-v41g-gate.sh [duree_torn64_s]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/v4-dedup"
QEMU_BIN="${QEMU_BIN:-qemu-aarch64}"
export QEMU_BIN  # items 5/6 delegues a run-claude-pad.sh doivent tester le MEME binaire que 1-4

TORN_DUR="${1:-180}"
TORN_N="${TORN_N:-4}"
# Le debit de torn64 mesure l'HORLOGE du pad autant que la dedup. L'ancien plancher
# absolu (1,25 G / 180 s) venait d'un banc overclocke a 1368 MHz disparu au reflash :
# le pad plafonne a 1296 MHz et le chemin PUBLIE (flag OFF) rate lui aussi cette
# constante, donc elle ne mesurait plus rien de ce que ce gate juge. Le bras OFF du
# MEME run sert desormais de reference du jour, et le bras ON est juge relativement.
TORN_ON_MIN_PCT="${TORN_ON_MIN_PCT:-90}"
# Garde-fou d'ordre de grandeur sur la reference elle-meme : attrape un banc effondre
# (guest qui rampe tout en imprimant SUCCESS), sans pretendre juger la frequence.
TORN_SANITY_ITERS="${TORN_SANITY_ITERS:-$((100000000 / 180 * TORN_DUR))}"
# Budget de l'item 6 (session -p JIT-active). Parametrable : sous dedup ce bras
# avorte vers 380 s, immobiliser le pad 5 h pour le reconstater ne prouve rien de plus.
PROMPT_BUDGET="${PROMPT_BUDGET:-1800}"
GUESTS="torn64 simd-dup2 smc-alias"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/v41g-gate-$STAMP.txt"

PAD_FAIL_PREFIX="GATE V4-1G"
# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# Un run de guest sous notre qemu. Args : tag, env_qemu, binaire, args_guest.
# Ecrit la sortie complete au log et la renvoie sur stdout.
run_guest() {
    local tag="$1" qenv="$2" bin="$3"; shift 3
    local tb ta out

    require_idle
    tb=$(wait_cool)
    # STDOUT N'EST QUE LA VALEUR DE RETOUR : l'appelant capture cette fonction par
    # $(...), et toute narration ajoutee ici se retrouverait DANS la mesure. Voir
    # l'entete de pad-lib.sh pour les deux defauts qui en sont nes.
    say "--- $tag (env: ${qenv:-aucun}) temp_before=$((tb / 1000))C ---"
    out=$($PAD_SSH "cd $PAD_DIR && taskset -c 0,1 timeout $((TORN_DUR + 120)) \
          env $qenv ./$QEMU_BIN ./$bin $* 2>&1; echo RC=\$?")
    ta=$(temp_now)
    printf '%s\n' "$out" >>"$LOG"
    say "    temp_after=$((ta / 1000))C"
    printf '%s' "$out"
}

say "=== GATE V4-1G, correctness pad de la dedup de TB, $STAMP ==="
say "pad=$PAD_USER@$PAD_HOST dir=$PAD_DIR torn64: N=$TORN_N duree=${TORN_DUR}s bras ON juge a >= $TORN_ON_MIN_PCT % du bras OFF du meme run"

# Preflight de joignabilite AVANT tout retry : $PAD_SSH n'impose pas de
# ConnectTimeout, un pad eteint ferait donc trainer chaque retry sur le timeout
# TCP par defaut (plusieurs minutes pour rien).
pad_alive || fail "pad $PAD_HOST injoignable (allume-le, ce gate ne peut PAS se substituer autrement)"

# --- Deploiement + piege du sha ---------------------------------------------------
say ""
say "=== Deploiement (le piege du sha : on verifie les DEUX cotes) ==="
pad_capture "mkdir -p $PAD_DIR" >/dev/null || fail "pad injoignable (mkdir $PAD_DIR)"
for f in "$QEMU_BIN" $GUESTS; do
    [ -f "$BUILD_OUT/$f" ] || fail "$BUILD_OUT/$f absent (lancer build.sh et test/build-guests.sh)"
    pad_put "$BUILD_OUT/$f" "$PAD_DIR/$f" || fail "transfert de $f echoue"
done
pad_capture "chmod +x $PAD_DIR/$QEMU_BIN $(for f in $GUESTS; do printf '%s ' "$PAD_DIR/$f"; done)" >/dev/null
for f in "$QEMU_BIN" $GUESTS; do
    local_sha=$(shasum -a 256 "$BUILD_OUT/$f" | cut -d' ' -f1)
    pad_sha=$(pad_capture "sha256sum $PAD_DIR/$f | cut -d' ' -f1")
    [ "$local_sha" = "$pad_sha" ] || fail "sha divergent pour $f (local $local_sha, pad $pad_sha)"
    say "  $f OK ${local_sha:0:16}"
done

# Extrait le compteur d'iterations d'une sortie torn64. Args : sortie, tag.
torn_iters() {
    local n
    n=$(printf '%s' "$1" | grep -oE "Final iterations: [0-9]+" | grep -oE "[0-9]+")
    [ -n "$n" ] || fail "torn64 $2 : compteur d'iterations illisible"
    printf '%s' "$n"
}

# --- 1. torn64 flag OFF : reference du jour ET non-regression du chemin publie -----
# Joue AVANT le bras ON : c'est lui qui donne le debit du banc, la ou l'ancienne
# constante absolue supposait un overclock qui n'existe plus.
say ""
say "=== 1/6 torn64 N=$TORN_N ${TORN_DUR}s, FLAG OFF (non-regression du publie + reference du jour) ==="
out=$(run_guest "torn64-off" "" torn64 "$TORN_N" "$TORN_DUR")
echo "$out" | grep -q "^SUCCESS: No torn reads" || fail "torn64 flag OFF a DECHIRE : REGRESSION du chemin publie"
echo "$out" | grep -q "tb-dedup" && fail "flag OFF mais des lignes tb-dedup sont emises : le defaut n'est pas OFF"
iters_off=$(torn_iters "$out" "flag OFF")
[ "$iters_off" -ge "$TORN_SANITY_ITERS" ] || fail "torn64 flag OFF : $iters_off iterations < garde-fou $TORN_SANITY_ITERS (banc effondre, la reference n'est pas exploitable)"
say "  torn64 flag OFF VERT : $iters_off iterations, 0 dechirure, aucune ligne tb-dedup (chemin publie inchange)"

# --- 2. torn64 flag ON : le coeur du gate, juge contre la reference du jour --------
say ""
say "=== 2/6 torn64 N=$TORN_N ${TORN_DUR}s, FLAG ON (0 dechirure ET >= $TORN_ON_MIN_PCT % du bras OFF) ==="
out=$(run_guest "torn64-on" "QEMU_TB_DEDUP=1 QEMU_TB_DEDUP_LOG=1" torn64 "$TORN_N" "$TORN_DUR")
echo "$out" | grep -q "^SUCCESS: No torn reads" || fail "torn64 flag ON a DECHIRE (ou n'a pas fini)"
iters_on=$(torn_iters "$out" "flag ON")
min_on=$((iters_off * TORN_ON_MIN_PCT / 100))
[ "$iters_on" -ge "$min_on" ] || fail "torn64 flag ON : $iters_on iterations < $TORN_ON_MIN_PCT % du bras OFF ($iters_off, soit $min_on)"
say "  torn64 flag ON VERT : $iters_on iterations, 0 dechirure ($((iters_on * 100 / iters_off)) % du bras OFF)"

# --- 3. simd-dup2 flag ON ---------------------------------------------------------
say ""
say "=== 3/6 simd-dup2, FLAG ON ==="
out=$(run_guest "simd-dup2-on" "QEMU_TB_DEDUP=1" simd-dup2)
echo "$out" | grep -q "OK: dup2_vec correct" || fail "simd-dup2 flag ON KO"
say "  simd-dup2 flag ON VERT"

# --- 4. smc-alias sync flag ON (l'invalidation SMC doit couvrir un TB servi) -------
say ""
say "=== 4/6 smc-alias sync, FLAG ON (l'invalidation SMC couvre-t-elle un TB servi ?) ==="
out=$(run_guest "smc-alias-on" "QEMU_TB_DEDUP=1" smc-alias sync)
echo "$out" | grep -q "SUCCESS: code frais execute a chaque tour" || fail "smc-alias sync flag ON KO : du code PERIME a ete execute"
say "  smc-alias sync flag ON VERT"

# --- 5. claude --version flag ON --------------------------------------------------
say ""
say "=== 5/6 claude --version, FLAG ON (delegue a run-claude-pad.sh) ==="
out=$(CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M \
      CLAUDE_EXTRA_ENV="QEMU_TB_DEDUP=1 QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1" \
      bash "$REPO_ROOT/test/run-claude-pad.sh" version 1800 2>&1)
echo "$out" >>"$LOG"
echo "$out" | grep -q "RESULT=BOOTED exit_rc=0" || fail "claude --version flag ON : pas de RESULT=BOOTED exit_rc=0 (cf. $LOG)"
say "  claude --version flag ON VERT (RESULT=BOOTED exit_rc=0)"

# --- 6. claude -p JIT-actif flag ON : il faut un RENDU, pas un PID vivant ----------
say ""
say "=== 6/6 claude -p JIT-ACTIF, FLAG ON (le rendu est le juge, pas la survie) ==="
out=$(CLAUDE_CPUS=0,1 CLAUDE_MEMMAX=750M \
      CLAUDE_EXTRA_ENV="QEMU_TB_DEDUP=1 QEMU_TB_SIZE=256 BUN_JSC_useJIT=1 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1" \
      bash "$REPO_ROOT/test/run-claude-pad.sh" prompt "$PROMPT_BUDGET" 2>&1)
echo "$out" >>"$LOG"
echo "$out" | grep -q "RESULT=BOOTED" || fail "claude -p JIT-actif flag ON : pas de RESULT=BOOTED (cf. $LOG)"
bytes=$(echo "$out" | grep -oE "out_bytes=[0-9]+" | head -1 | grep -oE "[0-9]+")
[ -n "$bytes" ] && [ "$bytes" -gt 0 ] || fail "claude -p flag ON : sortie VIDE (un PID vivant mais muet ne compte pas)"
say "  claude -p JIT-actif flag ON VERT (RESULT=BOOTED, out_bytes=$bytes)"

say ""
say "=== GATE V4-1G VERT : les 6 items passent. Log complet : $LOG ==="
