#!/bin/bash
# GATE O3LTO-CORRECTNESS : verifie que -O3 -mcpu=cortex-a7 -flto (defaut de build.sh depuis
# le commit 394f543) ne casse pas les deux garanties nues de correctness (torn64, smc-alias)
# SOUS LE COMMIT SOURCE QEMU REELLEMENT BUILDE. Distinct du gate V4-1G (qui verifiait la dedup
# de TB, QEMU_TB_DEDUP=1, sur v9.2.4-18-gf7ecdb6, un commit source anterieur a pageflags_lock,
# fb1c3b7/a0812ef/2eb4532 du 2026-08-08) : la revue du 2026-08-10 a releve que build.sh:58
# citait ce gate V4-1G pour justifier -O3+LTO alors qu'il ne porte ni sur ces flags de build
# hote, ni sur le commit source actuel.
#
# Deux items seulement (pas les 6 de V4-1G : pas de flag QEMU_TB_DEDUP ici, pas de
# claude --version/-p, hors perimetre de cette question precise) :
#   1. torn64 N=4, >=180 s, 0 dechirure
#   2. smc-alias sync : "SUCCESS: code frais execute a chaque tour"
#
# Usage : test/run-o3lto-correctness-gate.sh [duree_torn64_s]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/o3lto-correctness"
QEMU_BIN="${QEMU_BIN:-qemu-aarch64}"

TORN_DUR="${1:-180}"
TORN_N="${TORN_N:-4}"
# Meme garde-fou d'ordre de grandeur que run-v41g-gate.sh (attrape un banc effondre) :
# le pad plafonne a 1296 MHz, cf. sa note sur l'ancienne constante 1368 MHz disparue au reflash.
TORN_SANITY_ITERS="${TORN_SANITY_ITERS:-$((100000000 / 180 * TORN_DUR))}"
GUESTS="torn64 smc-alias"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/o3lto-gate-$STAMP.txt"

PAD_FAIL_PREFIX="GATE O3LTO-CORRECTNESS"
# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# Un run de guest sous notre qemu. Args : tag, binaire, args_guest.
# STDOUT N'EST QUE LA VALEUR DE RETOUR (cf. entete pad-lib.sh) : l'appelant capture par $(...).
run_guest() {
    local tag="$1" bin="$2"; shift 2
    local tb ta out

    require_idle
    tb=$(wait_cool)
    say "--- $tag temp_before=$((tb / 1000))C ---"
    out=$($PAD_SSH "cd $PAD_DIR && taskset -c 0,1 timeout $((TORN_DUR + 120)) ./$QEMU_BIN ./$bin $* 2>&1; echo RC=\$?")
    ta=$(temp_now)
    printf '%s\n' "$out" >>"$LOG"
    say "    temp_after=$((ta / 1000))C"
    printf '%s' "$out"
}

say "=== GATE O3LTO-CORRECTNESS, $STAMP ==="
say "pad=$PAD_USER@$PAD_HOST dir=$PAD_DIR torn64: N=$TORN_N duree=${TORN_DUR}s"

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

# Extrait le compteur d'iterations d'une sortie torn64. Args : sortie.
torn_iters() {
    local n
    n=$(printf '%s' "$1" | grep -oE "Final iterations: [0-9]+" | grep -oE "[0-9]+")
    [ -n "$n" ] || fail "torn64 : compteur d'iterations illisible"
    printf '%s' "$n"
}

# --- 1/2 torn64 -------------------------------------------------------------------
say ""
say "=== 1/2 torn64 N=$TORN_N ${TORN_DUR}s ==="
out=$(run_guest "torn64" torn64 "$TORN_N" "$TORN_DUR")
echo "$out" | grep -q "^SUCCESS: No torn reads" || fail "torn64 a DECHIRE (ou n'a pas fini)"
iters=$(torn_iters "$out")
[ "$iters" -ge "$TORN_SANITY_ITERS" ] || fail "torn64 : $iters iterations < garde-fou $TORN_SANITY_ITERS (banc effondre, non exploitable)"
say "  torn64 VERT : $iters iterations, 0 dechirure"

# --- 2/2 smc-alias sync ------------------------------------------------------------
say ""
say "=== 2/2 smc-alias sync (l'invalidation SMC couvre-t-elle un TB servi ?) ==="
out=$(run_guest "smc-alias" smc-alias sync)
echo "$out" | grep -q "SUCCESS: code frais execute a chaque tour" || fail "smc-alias sync KO : du code PERIME a ete execute"
say "  smc-alias sync VERT"

say ""
say "=== GATE O3LTO-CORRECTNESS VERT : les 2 items passent. Log complet : $LOG ==="
