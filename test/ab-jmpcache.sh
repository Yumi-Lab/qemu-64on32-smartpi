#!/bin/bash
# Z1a, campagne A/B du reglage TB_JMP_CACHE_BITS (12 -> 15 bits, host-tuning).
# Contrairement a QEMU_NZCV_LAZY (flag runtime), ce reglage est un define
# compile-time : le protocole compare DEUX BINAIRES qemu-aarch64 (off/on) au
# lieu d'un flag d'env sur un seul binaire. Meme discipline que ab-nzcv.sh :
# ABAB, medianes >= N runs, torn64 + claude --version/--help + correctness.
#
# Usage: test/ab-jmpcache.sh <tag> <off_binary> <on_binary> [runs_per_arm]
#   tag         : sous-dossier de logs (test/logs/host-tuning/<tag>/)
#   off_binary  : chemin vers le qemu-aarch64 baseline (12 bits, yumi-64on32)
#   on_binary   : chemin vers le qemu-aarch64 modifie (15 bits, host-tuning)
#   runs_per_arm: nombre de runs par bras pour torn64/version/help (defaut 3)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: ab-jmpcache.sh <tag> <off_binary> <on_binary> [runs_per_arm]}"
OFF_BIN="${2:?usage: ab-jmpcache.sh <tag> <off_binary> <on_binary> [runs_per_arm]}"
ON_BIN="${3:?usage: ab-jmpcache.sh <tag> <off_binary> <on_binary> [runs_per_arm]}"
RUNS="${4:-3}"
LOGDIR="$REPO_ROOT/test/logs/host-tuning/$TAG"
BUILD_OUT="$REPO_ROOT/build-out"
QEMU_BIN="qemu-aarch64"
mkdir -p "$LOGDIR"

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad.env"

TORN_SECS="${TORN_SECS:-120}"
VERSION_TIMEOUT="${VERSION_TIMEOUT:-600}"
HELP_TIMEOUT="${HELP_TIMEOUT:-2400}"
CLAUDE_COMBO="QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

median() {
    sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

# Deploie le binaire demande en tant que build-out/qemu-aarch64 local ET sur le pad
# (run-claude-pad.sh ne scp jamais lui-meme, il verifie seulement le sha ; run-pad.sh
# scp a chaque appel, donc torn64 n'a pas besoin de ce helper).
pad_retry() {
    local n=0 max=5
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && { echo "[ab-jmpcache] connexion pad echouee apres $max tentatives" >&2; return 1; }
        sleep $((n * 3))
    done
}
deploy() {
    local src="$1" dest="$BUILD_OUT/$QEMU_BIN"
    # OFF_BIN/ON_BIN doit designer un artefact STABLE, distinct de la
    # destination de staging : sinon le deploy() du bras oppose ecrase ce
    # fichier avant qu'il ne soit lu, et cp source==dest est un no-op
    # silencieux (pas d'erreur), transformant l'A/B en A/A (incident z1c).
    if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" = "$dest" ]; then
        echo "[ab-jmpcache] ERREUR : source de deploy() ($src) == destination de staging ($dest)" >&2
        echo "[ab-jmpcache] utiliser un artefact distinct (ex: build-out/qemu-aarch64-baseline)" >&2
        exit 1
    fi
    cp "$src" "$dest"
    pad_retry $PAD_SSH "mkdir -p $PAD_DIR"
    pad_retry $PAD_SCP "$dest" "$PAD_USER@$PAD_HOST:$PAD_DIR/$QEMU_BIN"
    pad_retry $PAD_SSH "chmod +x $PAD_DIR/$QEMU_BIN"
}

run_torn64() {
    local flag="$1" idx="$2" out
    out=$(bash "$REPO_ROOT/test/run-pad.sh" torn64 4 "$TORN_SECS" 2>&1)
    echo "$out" > "$LOGDIR/torn64-$flag-$idx.log"
    echo "$out" | grep -oE "No torn reads detected after [0-9]+ iterations" | grep -oE "[0-9]+" | tail -1
}

run_claude() {
    local mode="$1" flag="$2" idx="$3" timeout="$4" out
    out=$(CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$CLAUDE_COMBO" bash "$REPO_ROOT/test/run-claude-pad.sh" "$mode" "$timeout" 2>&1)
    echo "$out" > "$LOGDIR/claude-$mode-$flag-$idx.log"
    echo "$out" | grep -oE "elapsed=[0-9]+" | head -1 | grep -oE "[0-9]+"
}

echo "=== torn64 ABAB (N=4, ${TORN_SECS}s x $RUNS par bras) : correctness d'abord ==="
on_vals=(); off_vals=()
for i in $(seq 1 "$RUNS"); do
    deploy "$ON_BIN"
    v=$(run_torn64 on "$i"); echo "  torn64 ON  run $i: ${v:-FAIL} it"; on_vals+=("${v:-0}")
    deploy "$OFF_BIN"
    v=$(run_torn64 off "$i"); echo "  torn64 OFF run $i: ${v:-FAIL} it"; off_vals+=("${v:-0}")
done
torn_on_median=$(printf '%s\n' "${on_vals[@]}" | median)
torn_off_median=$(printf '%s\n' "${off_vals[@]}" | median)
echo "torn64 mediane: ON=$torn_on_median OFF=$torn_off_median"

echo "=== claude --version ABAB (combo, x$RUNS par bras) ==="
von=(); voff=()
for i in $(seq 1 "$RUNS"); do
    deploy "$ON_BIN"
    v=$(run_claude version on "$i" "$VERSION_TIMEOUT"); echo "  version ON  run $i: ${v:-FAIL}s"; von+=("${v:-0}")
    deploy "$OFF_BIN"
    v=$(run_claude version off "$i" "$VERSION_TIMEOUT"); echo "  version OFF run $i: ${v:-FAIL}s"; voff+=("${v:-0}")
done
version_on_median=$(printf '%s\n' "${von[@]}" | median)
version_off_median=$(printf '%s\n' "${voff[@]}" | median)
echo "version mediane: ON=$version_on_median OFF=$version_off_median"

echo "=== claude --help ABAB (combo, x$RUNS par bras) ==="
hon=(); hoff=()
for i in $(seq 1 "$RUNS"); do
    deploy "$ON_BIN"
    v=$(run_claude help on "$i" "$HELP_TIMEOUT"); echo "  help ON  run $i: ${v:-FAIL}s"; hon+=("${v:-0}")
    deploy "$OFF_BIN"
    v=$(run_claude help off "$i" "$HELP_TIMEOUT"); echo "  help OFF run $i: ${v:-FAIL}s"; hoff+=("${v:-0}")
done
help_on_median=$(printf '%s\n' "${hon[@]}" | median)
help_off_median=$(printf '%s\n' "${hoff[@]}" | median)
echo "help mediane: ON=$help_on_median OFF=$help_off_median"

{
  echo "torn64 mediane it/${TORN_SECS}s: ON=$torn_on_median OFF=$torn_off_median"
  echo "version mediane elapsed s: ON=$version_on_median OFF=$version_off_median"
  echo "help mediane elapsed s: ON=$help_on_median OFF=$help_off_median"
} | tee "$LOGDIR/summary.txt"
