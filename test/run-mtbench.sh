#!/bin/bash
# run-mtbench.sh : pilote du banc multi-thread Y2 (guest test/mtbench.c).
# Fait varier N (1, 2, 4 par defaut) pour chaque workload, delegue chaque run a
# test/run-pad.sh (deploiement, garde thermique, pgrep, taskset 0,1, MemoryMax),
# consigne les logs bruts dans test/logs/mtbench/ et rend une TABLE DE SCALING :
# debit(N) / debit(1). Un emulateur qui ne scale pas au-dela de 1 thread est le
# symptome de serialisation que la phase Y cherche.
#
# Usage : $0 [seconds] [workloads] [Ns]
#   $0                # defaut : 15 s, "atomic alloc smc mixed", "1 2 4"
#   $0 20 "atomic"    # un seul workload, 20 s par run
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
LOG_DIR="$TEST_DIR/logs/mtbench"

SECONDS_PER_RUN="${1:-15}"
WORKLOADS="${2:-atomic alloc smc mixed}"
NS="${3:-1 2 4}"

mkdir -p "$LOG_DIR"

if [ ! -f "$BUILD_OUT/mtbench" ]; then
    echo "ERROR: build-out/mtbench absent (lancer test/build-guests.sh mtbench.c d'abord)"
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"

# resultats stockes dans des variables dynamiques OPS_<workload>_<N> (bash 3.2
# du Mac : pas de tableaux associatifs). Noms controles (listes internes).
set_ops() { eval "OPS_$1_$2=$3"; }
get_ops() { eval "printf '%s' \"\${OPS_$1_$2:-}\""; }
fail=0

for w in $WORKLOADS; do
    for n in $NS; do
        log="$LOG_DIR/mtbench-${w}-N${n}-${STAMP}.log"
        echo "[run-mtbench.sh] run workload=$w N=$n (${SECONDS_PER_RUN}s) -> $log"
        set +e
        "$TEST_DIR/run-pad.sh" mtbench "$w" "$n" "$SECONDS_PER_RUN" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ]; then
            echo "[run-mtbench.sh] ECHEC run workload=$w N=$n (rc=$rc)"
            fail=1
            continue
        fi
        ops="$(grep -oE 'ops_per_sec=[0-9]+' "$log" | tail -1 | cut -d= -f2)"
        if [ -z "$ops" ]; then
            echo "[run-mtbench.sh] ligne RESULT absente pour workload=$w N=$n"
            fail=1
            continue
        fi
        set_ops "$w" "$n" "$ops"
    done
done

echo
echo "[run-mtbench.sh] TABLE DE SCALING (ops/s, ratio vs N=1) :"
printf '%-8s' "workload"
for n in $NS; do printf ' %12s' "N=$n"; done
echo
for w in $WORKLOADS; do
    printf '%-8s' "$w"
    base=""
    for n in $NS; do
        ops="$(get_ops "$w" "$n")"
        if [ -z "$ops" ]; then
            printf ' %12s' "ECHEC"
        elif [ -z "$base" ]; then
            base="$ops"
            printf ' %12s' "$ops"
        else
            # ratio en millièmes, entier (awk deja requis par le projet)
            ratio="$(awk -v a="$ops" -v b="$base" 'BEGIN{printf "%.2f", a/b}')"
            printf ' %12s' "$ops (${ratio}x)"
        fi
    done
    echo
done

exit "$fail"
