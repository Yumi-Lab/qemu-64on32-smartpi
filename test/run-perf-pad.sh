#!/bin/bash
# R1, carte des couts HOTE ponderee execution. Profile le fork qemu DEJA DEPLOYE sur
# le pad avec `perf record` + QEMU_PERFMAP (symbolisation du code JIT traduit), sans
# aucun patch ni rebuild (perfmap natif de 9.2.4, cf. linux-user/main.c). Deux
# workloads representatifs : torn64 (boucle d'atomicite serree) et claude --version
# (combo produit standard : QEMU_TB_SIZE=256 + JIT invite coupe + GC calme). Produit,
# dans test/logs/perf-hotspots/ : le perf.data, la map JIT, et deux rapports --stdio
# (buckets par DSO et top des symboles), plus la ligne de synthese temp/overhead.
#
# Regles GOAL pad respectees (tout cote pad) : sha du qemu verifie contre le local,
# UN SEUL qemu a la fois (refus sinon), taskset (2 coeurs pour torn64, mono-coeur pour
# le combo claude standard), timeout (garde-fou dur), temperature avant/apres,
# jamais /opt/grok ni /opt/yumi-ai-gateway. perf tourne sous sudo (acces PMU
# Cortex-A7 + symboles noyau) ; l'outillage perf (paquet linux-perf) est justifie au
# Journal R1 et ne modifie pas la config d'EXECUTION du pad (aucun service, aucun env
# systeme touche). Frequence d'echantillonnage modeste (defaut -F 99, cf. R1).
#
# Usage : run-perf-pad.sh <torn64|claude-version|claude-help> [dur_s]
#   torn64         : profile torn64 N=PERF_TORN_N (defaut 4) pendant dur_s (defaut 60)
#   claude-version : profile claude --version, combo standard, timeout dur_s (defaut 180)
#   claude-help    : profile claude --help (init CLI complete), combo standard, 2 coeurs
#   claude-help-jit: idem claude-help mais JIT invite ACTIF (BUN_JSC_useJIT=1), le
#                    regime -p reel (angle mort du profilage jitless). Mesure Z0 (a) :
#                    part du temps hote dans le traducteur / l'invalidation de TB.
# Env : PERF_FREQ (defaut 99), PERF_TORN_N (defaut 4), PERF_TAG (suffixe de log),
#       PERF_NO_MAP=1 (ne pas passer QEMU_PERFMAP, pour la mesure d'overhead sans perfmap)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
QEMU_BIN="qemu-aarch64"

# shellcheck disable=SC1091
source "$TEST_DIR/pad.env"

MODE="${1:?usage: run-perf-pad.sh <torn64|claude-version|claude-help|claude-help-jit> [dur_s]}"
FREQ="${PERF_FREQ:-99}"
TORN_N="${PERF_TORN_N:-4}"
LOGDIR="$REPO_ROOT/test/logs/perf-hotspots"
mkdir -p "$LOGDIR"

QEMU_ON_PAD="$PAD_DIR/$QEMU_BIN"
CLAUDE_PAD="$PAD_DIR/claude-native"
SYSROOT="$PAD_DIR/sysroot"

# Reconnexions robustes (sshd throttle les rafales), meme logique que run-pad.sh.
pad_capture() {
    local n=0 max=5 out
    until out=$($PAD_SSH "$@" 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && { echo "[perf] lecture pad echouee apres $max tentatives" >&2; return 1; }
        sleep $((n * 3))
    done
    printf '%s' "$out"
}

# --- Verification du deploiement (le binaire profile DOIT etre le fork local) ------
LOCAL_SHA=$(shasum -a 256 "$BUILD_OUT/$QEMU_BIN" | cut -d' ' -f1)
PAD_SHA=$(pad_capture "sha256sum $QEMU_ON_PAD 2>/dev/null | cut -d' ' -f1")
if [ "$LOCAL_SHA" != "$PAD_SHA" ]; then
    echo "ERROR: qemu pad ($PAD_SHA) != fork local ($LOCAL_SHA), deployer build-out/$QEMU_BIN d'abord." >&2
    exit 1
fi
echo "[perf] qemu fork OK ($PAD_SHA)"

# --- Garde : un seul qemu a la fois -----------------------------------------------
RUN=$(pad_capture "pgrep -x $QEMU_BIN || echo 0")
if [ "$RUN" != "0" ]; then
    echo "ERROR: un qemu-aarch64 tourne deja sur le pad, on n'en lance jamais un 2e." >&2
    exit 1
fi

# --- Temperature avant (refus si trop chaud) --------------------------------------
TB=$(pad_capture "cat /sys/class/thermal/thermal_zone0/temp")
echo "[perf] temp before: $((TB / 1000))C"
if [ "$TB" -gt 80000 ]; then
    echo "ERROR: pad trop chaud ($((TB / 1000))C > 80C), refroidir d'abord." >&2
    exit 1
fi

# --- Construction de la ligne de commande invite selon le mode --------------------
PERFMAP_ENV="QEMU_PERFMAP=1"
[ "${PERF_NO_MAP:-0}" = "1" ] && PERFMAP_ENV=""

# Env commun aux workloads claude (combo produit standard), le SEUL parametre qui
# distingue jitless de JIT-actif est BUN_JSC_useJIT, injecte via $JITENV par mode.
claude_workload() {
    local guest_flag="$1" jitenv="$2"
    echo "env HOME=$PAD_DIR DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 QEMU_TB_SIZE=256 $jitenv BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1 $PERFMAP_ENV $QEMU_ON_PAD -L $SYSROOT $CLAUDE_PAD $guest_flag"
}

case "$MODE" in
    torn64)
        DUR="${2:-60}"
        HARD=$((DUR + 60))
        TASKSET="0,1"
        WORKLOAD="env $PERFMAP_ENV $QEMU_ON_PAD $PAD_DIR/torn64 $TORN_N $DUR"
        ;;
    claude-version)
        DUR="${2:-180}"
        HARD="$DUR"
        TASKSET="0"
        WORKLOAD="$(claude_workload --version BUN_JSC_useJIT=0)"
        ;;
    claude-help)
        DUR="${2:-300}"
        HARD="$DUR"
        TASKSET="0,1"
        WORKLOAD="$(claude_workload --help BUN_JSC_useJIT=0)"
        ;;
    claude-help-jit)
        DUR="${2:-300}"
        HARD="$DUR"
        TASKSET="0,1"
        WORKLOAD="$(claude_workload --help BUN_JSC_useJIT=1)"
        ;;
    *)
        echo "ERROR: mode inconnu '$MODE' (attendu: torn64|claude-version|claude-help|claude-help-jit)" >&2
        exit 2
        ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
TAG="${PERF_TAG:-$MODE}"
PERFDATA="$PAD_DIR/perf-${TAG}-${STAMP}.data"
BASE="perf-${TAG}-${STAMP}"

echo "[perf] mode=$MODE freq=$FREQ taskset=$TASKSET dur=$DUR (hard=${HARD}s) perfmap=${PERFMAP_ENV:-off}"

# Runner distant genere avec les valeurs concretes deja substituees, puis execute en
# UN SEUL `sudo bash` (perf record + rapports + chown des artefacts vers pi, pour que
# le rapatriement scp fonctionne : qemu/perf tournent en root, la map JIT et le
# perf.data naissent root). perf suit tout le sous-arbre (--), timeout = garde-fou dur.
REMOTE_SH="$(mktemp)"
cat >"$REMOTE_SH" <<EOF
#!/bin/bash
set -u
REC="$PAD_DIR/$BASE.rec"
: >"\$REC"
rm -f /tmp/perf-*.map
perf record -F $FREQ -o "$PERFDATA" -- timeout -k 30 $HARD taskset -c $TASKSET $WORKLOAD >"$PAD_DIR/$BASE.out" 2>&1
echo "RECRC=\$?" >>"\$REC"
MAP=\$(ls -1 /tmp/perf-*.map 2>/dev/null | head -1)
echo "MAPFILE=\$MAP" >>"\$REC"
if [ -n "\$MAP" ]; then
    echo "MAPLINES=\$(wc -l <"\$MAP")" >>"\$REC"
    cp "\$MAP" "$PAD_DIR/$BASE.map"
fi
perf report -i "$PERFDATA" --stdio -s dso 2>/dev/null >"$PAD_DIR/$BASE.dso"
perf report -i "$PERFDATA" --stdio -F overhead,dso,symbol --percent-limit 0.10 2>/dev/null >"$PAD_DIR/$BASE.sym"
perf report -i "$PERFDATA" --stdio 2>/dev/null | grep -E "# (Samples|Event count)" >>"\$REC"
echo "TEMP_AFTER=\$(cat /sys/class/thermal/thermal_zone0/temp)" >>"\$REC"
chown $PAD_USER:$PAD_USER "$PAD_DIR/$BASE".* "$PERFDATA" 2>/dev/null
chmod 644 "$PAD_DIR/$BASE".* "$PERFDATA" 2>/dev/null
EOF

set +e
$PAD_SCP "$REMOTE_SH" "$PAD_USER@$PAD_HOST:$PAD_DIR/$BASE.runner.sh" >/dev/null 2>&1
$PAD_SSH "echo $PAD_PASS | sudo -S bash $PAD_DIR/$BASE.runner.sh; rm -f $PAD_DIR/$BASE.runner.sh"
SSH_RC=$?
rm -f "$REMOTE_SH"
set -e 2>/dev/null || true

# --- Rapatriement des artefacts ----------------------------------------------------
for ext in rec dso sym map out; do
    $PAD_SCP "$PAD_USER@$PAD_HOST:$PAD_DIR/$BASE.$ext" "$LOGDIR/$BASE.$ext" 2>/dev/null || true
done
$PAD_SCP "$PAD_USER@$PAD_HOST:$PERFDATA" "$LOGDIR/$BASE.data" 2>/dev/null || true

TA=$(pad_capture "cat /sys/class/thermal/thermal_zone0/temp")
echo "[perf] temp after: $((TA / 1000))C   ssh_rc=$SSH_RC"
echo "[perf] artefacts: $LOGDIR/$BASE.{rec,dso,sym,map,data}"
echo "[perf] --- rec ---"
cat "$LOGDIR/$BASE.rec" 2>/dev/null | grep -E "RECRC|MAPFILE|MAPLINES|TEMP_AFTER|# (Samples|Event)" || true
exit $SSH_RC
