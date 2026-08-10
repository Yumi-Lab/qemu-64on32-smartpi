#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
# Binaire qemu utilise cote pad (doit exister dans build-out/). Surchargeable
# par l'environnement (ex. QEMU_BIN=qemu-aarch64-serstats), comme QEMU_OPTS et
# QEMU_ENV ci-dessous ; defaut : le binaire de production.
QEMU_BIN="${QEMU_BIN:-qemu-aarch64}"

# Options passees a qemu lui-meme (ex. QEMU_OPTS="-cpu cortex-a53" pour un
# invite pre-LSE2). Vide par defaut : comportement identique a l'existant.
QEMU_OPTS="${QEMU_OPTS:-}"

# Paires NAME=VAL ajoutees a l'environnement de qemu sur le pad
# (ex. QEMU_ENV="QEMU_TB_EXEC_PROFILE=1"). Vide par defaut.
QEMU_ENV="${QEMU_ENV:-}"

source "$TEST_DIR/pad.env"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <binary> [args...]"
    echo "Example: $0 torn64 2 30"
    exit 1
fi

BINARY="$1"
shift
ARGS="$@"

if [ ! -f "$BUILD_OUT/$BINARY" ]; then
    echo "ERROR: Binary $BINARY not found in $BUILD_OUT (lancer test/build-guests.sh d'abord)"
    exit 1
fi

if [ ! -f "$BUILD_OUT/$QEMU_BIN" ]; then
    echo "ERROR: $QEMU_BIN not found in $BUILD_OUT (lancer build.sh d'abord)"
    exit 1
fi

# Le sshd du pad throttle les rafales de connexions (le deploiement enchaine
# mkdir + 2 scp + chmod en quelques secondes) : une connexion peut etre rejetee
# "Permission denied" alors que le mot de passe est bon. On retente avec backoff.
# NE PAS envelopper le run de test lui-meme (retenter un run partiel serait faux).
pad_retry() {
    local n=0 max=5
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && { echo "[run-pad.sh] connexion pad echouee apres $max tentatives" >&2; return 1; }
        echo "[run-pad.sh] connexion pad rejetee (throttle sshd ?), retry $n/$max apres backoff..." >&2
        sleep $((n * 3))
    done
}

# Meme robustesse pour une LECTURE (temperature, pgrep) : renvoie le stdout du
# pad, en retentant la connexion si elle est transitoirement rejetee.
pad_capture() {
    local n=0 max=5 out
    until out=$("$@" 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && { echo "[run-pad.sh] lecture pad echouee apres $max tentatives" >&2; return 1; }
        sleep $((n * 3))
    done
    printf '%s' "$out"
}

echo "[run-pad.sh] Deploying $QEMU_BIN and $BINARY to pad..."

pad_retry $PAD_SSH "mkdir -p $PAD_DIR"

# L'image DietPi du pad n'a ni scp ni sftp-server (cf. test/pad.env) : scp
# echouerait sur "/usr/lib/sftp-server: No such file or directory", que le
# retry ci-dessus maquillait en "throttle sshd". On pousse via un `cat >`.
pad_put() {
    $PAD_SSH "cat > $2" < "$1"
}

# QEMU_BIN pese ~35 Mo (contre <1 Mo pour les guests de test) : sur le saut
# mac-maison, son transfert domine le temps total (~30 min mesures). Une
# meme session de tests rejoue souvent plusieurs guests sur le MEME binaire
# qemu inchange -> on saute la retransmission si le sha256 distant colle deja
# au sha256 local (guests toujours retransferes, cout negligeable).
LOCAL_QEMU_SHA=$(shasum -a 256 "$BUILD_OUT/$QEMU_BIN" | cut -d' ' -f1)
REMOTE_QEMU_SHA=$(pad_capture $PAD_SSH "sha256sum $PAD_DIR/$QEMU_BIN 2>/dev/null | cut -d' ' -f1")
if [ "$REMOTE_QEMU_SHA" = "$LOCAL_QEMU_SHA" ]; then
    echo "[run-pad.sh] $QEMU_BIN deja present sur le pad (sha256 identique), transfert saute"
else
    pad_retry pad_put "$BUILD_OUT/$QEMU_BIN" "$PAD_DIR/$QEMU_BIN"
fi
pad_retry pad_put "$BUILD_OUT/$BINARY" "$PAD_DIR/$BINARY"
pad_retry $PAD_SSH "chmod +x $PAD_DIR/$QEMU_BIN $PAD_DIR/$BINARY"

echo "[run-pad.sh] Checking temperature before run..."
TEMP_BEFORE=$(pad_capture $PAD_SSH "cat /sys/class/thermal/thermal_zone0/temp")
echo "Temperature before: $((TEMP_BEFORE / 1000))C"

if [ "$TEMP_BEFORE" -gt 80000 ]; then
    echo "WARNING: Temperature too high, waiting for cooldown..."
    for i in {1..10}; do
        echo "Waiting... ($i/10)"
        sleep 60
        TEMP_BEFORE=$(pad_capture $PAD_SSH "cat /sys/class/thermal/thermal_zone0/temp")
        echo "Temperature: $((TEMP_BEFORE / 1000))C"
        if [ "$TEMP_BEFORE" -le 80000 ]; then
            break
        fi
    done
fi

echo "[run-pad.sh] Checking if qemu is already running..."
QEMU_RUNNING=$(pad_capture $PAD_SSH "pgrep $QEMU_BIN || echo 0")
if [ "$QEMU_RUNNING" != "0" ]; then
    echo "ERROR: QEMU already running on pad, please wait or kill it manually"
    exit 1
fi

# Coeurs alloues au run. Le defaut `0,1` vient d'une garde THERMIQUE posee sur un pad SANS
# refroidissement actif : la carte gelait sous charge soutenue sur 4 coeurs. Sur un pad
# REFROIDI la contrainte n'a plus lieu d'etre, et brider 2 coeurs sur 4 fausse toute mesure
# de scaling au-dela de N=2 (elle mesure alors de la SUR-SOUSCRIPTION, pas du parallelisme).
# Surcharger avec PAD_CPUS=0-3. La coupure thermique reste active dans tous les cas : ce qui
# est leve ici, c'est l'epinglage des coeurs, pas la surveillance de temperature.
PAD_CPUS="${PAD_CPUS:-0,1}"
echo "[run-pad.sh] Running test: $BINARY $ARGS (sous $QEMU_BIN $QEMU_OPTS, coeurs $PAD_CPUS)"
set +e
$PAD_SSH "echo $PAD_PASS | sudo -S taskset -c $PAD_CPUS systemd-run --scope -p MemoryMax=600M timeout 1800 env $QEMU_ENV $PAD_DIR/$QEMU_BIN $QEMU_OPTS $PAD_DIR/$BINARY $ARGS"
TEST_EXIT=$?
set -e

echo "[run-pad.sh] Checking temperature after run..."
TEMP_AFTER=$(pad_capture $PAD_SSH "cat /sys/class/thermal/thermal_zone0/temp")
echo "Temperature after: $((TEMP_AFTER / 1000))C"

exit $TEST_EXIT
