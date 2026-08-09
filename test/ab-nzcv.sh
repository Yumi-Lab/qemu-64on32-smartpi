#!/bin/bash
# Campagne de mesure A/B du flag QEMU_NZCV_LAZY sur un build deja deploye sur le
# pad (aucun scp de qemu-aarch64 en plus de ce que run-pad.sh/run-claude-pad.sh
# font deja). Meme protocole reutilise par L4A et L4B (cf. PROGRESS.md phase L) :
# alternance ABAB, mediane de >= N runs par bras, sur torn64 + claude --version +
# claude --help, plus une preuve de mecanisme (profil QEMU_TB_EXEC_PROFILE) par bras.
#
# Usage: test/ab-nzcv.sh <tag> [runs_per_arm]
#   tag           : sous-dossier de logs, ex. l4a ou l4b (test/logs/nzcv-lazy/<tag>/)
#   runs_per_arm  : nombre de runs par bras pour torn64/version/help (defaut 3)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: ab-nzcv.sh <tag> [runs_per_arm]}"
RUNS="${2:-3}"
LOGDIR="$REPO_ROOT/test/logs/nzcv-lazy/$TAG"
mkdir -p "$LOGDIR"

TORN_SECS="${TORN_SECS:-180}"
VERSION_TIMEOUT="${VERSION_TIMEOUT:-600}"
HELP_TIMEOUT="${HELP_TIMEOUT:-2400}"
CLAUDE_COMBO="QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

median() {
    sort -n | awk '{a[NR]=$1} END{if(NR==0){print "NA"; exit} if(NR%2==1) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'
}

run_torn64() {
    local flag="$1" idx="$2" out
    if [ "$flag" = "on" ]; then
        out=$(QEMU_ENV="QEMU_NZCV_LAZY=1" bash "$REPO_ROOT/test/run-pad.sh" torn64 4 "$TORN_SECS" 2>&1)
    else
        out=$(bash "$REPO_ROOT/test/run-pad.sh" torn64 4 "$TORN_SECS" 2>&1)
    fi
    echo "$out" > "$LOGDIR/torn64-$flag-$idx.log"
    echo "$out" | grep -oE "Final iterations: [0-9]+" | grep -oE "[0-9]+" | tail -1
}

run_claude() {
    local mode="$1" flag="$2" idx="$3" timeout="$4" extra out
    extra="$CLAUDE_COMBO"
    [ "$flag" = "on" ] && extra="$extra QEMU_NZCV_LAZY=1"
    out=$(CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$extra" bash "$REPO_ROOT/test/run-claude-pad.sh" "$mode" "$timeout" 2>&1)
    echo "$out" > "$LOGDIR/claude-$mode-$flag-$idx.log"
    echo "$out" | grep -oE "elapsed=[0-9]+" | head -1 | grep -oE "[0-9]+"
}

echo "=== torn64 ABAB (N=4, ${TORN_SECS}s x $RUNS par bras) ==="
on_vals=(); off_vals=()
for i in $(seq 1 "$RUNS"); do
    v=$(run_torn64 on "$i"); echo "  torn64 ON  run $i: ${v:-FAIL} it"; on_vals+=("${v:-0}")
    v=$(run_torn64 off "$i"); echo "  torn64 OFF run $i: ${v:-FAIL} it"; off_vals+=("${v:-0}")
done
torn_on_median=$(printf '%s\n' "${on_vals[@]}" | median)
torn_off_median=$(printf '%s\n' "${off_vals[@]}" | median)
echo "torn64 mediane: ON=$torn_on_median OFF=$torn_off_median"

echo "=== claude --version ABAB (combo, x$RUNS par bras) ==="
von=(); voff=()
for i in $(seq 1 "$RUNS"); do
    v=$(run_claude version on "$i" "$VERSION_TIMEOUT"); echo "  version ON  run $i: ${v:-FAIL}s"; von+=("${v:-0}")
    v=$(run_claude version off "$i" "$VERSION_TIMEOUT"); echo "  version OFF run $i: ${v:-FAIL}s"; voff+=("${v:-0}")
done
version_on_median=$(printf '%s\n' "${von[@]}" | median)
version_off_median=$(printf '%s\n' "${voff[@]}" | median)
echo "version mediane: ON=$version_on_median OFF=$version_off_median"

echo "=== claude --help ABAB (combo, x$RUNS par bras) ==="
hon=(); hoff=()
for i in $(seq 1 "$RUNS"); do
    v=$(run_claude help on "$i" "$HELP_TIMEOUT"); echo "  help ON  run $i: ${v:-FAIL}s"; hon+=("${v:-0}")
    v=$(run_claude help off "$i" "$HELP_TIMEOUT"); echo "  help OFF run $i: ${v:-FAIL}s"; hoff+=("${v:-0}")
done
help_on_median=$(printf '%s\n' "${hon[@]}" | median)
help_off_median=$(printf '%s\n' "${hoff[@]}" | median)
echo "help mediane: ON=$help_on_median OFF=$help_off_median"

echo "=== preuve de mecanisme : profil NZCV (execution weighted), 1 run --version par bras ==="
on_prof=$(CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$CLAUDE_COMBO QEMU_NZCV_LAZY=1 QEMU_TB_EXEC_PROFILE=1" bash "$REPO_ROOT/test/run-claude-pad.sh" version "$VERSION_TIMEOUT" 2>&1)
echo "$on_prof" > "$LOGDIR/profile-on.log"
off_prof=$(CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M CLAUDE_EXTRA_ENV="$CLAUDE_COMBO QEMU_TB_EXEC_PROFILE=1" bash "$REPO_ROOT/test/run-claude-pad.sh" version "$VERSION_TIMEOUT" 2>&1)
echo "$off_prof" > "$LOGDIR/profile-off.log"
prof_on_line=$(echo "$on_prof" | grep "NZCV (execution weighted)")
prof_off_line=$(echo "$off_prof" | grep "NZCV (execution weighted)")
echo "profil ON : $prof_on_line"
echo "profil OFF: $prof_off_line"

{
  echo "torn64 mediane it/${TORN_SECS}s: ON=$torn_on_median OFF=$torn_off_median"
  echo "version mediane elapsed s: ON=$version_on_median OFF=$version_off_median"
  echo "help mediane elapsed s: ON=$help_on_median OFF=$help_off_median"
  echo "profil ON : $prof_on_line"
  echo "profil OFF: $prof_off_line"
} | tee "$LOGDIR/summary.txt"
