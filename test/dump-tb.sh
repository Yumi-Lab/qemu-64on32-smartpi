#!/bin/bash
set -euo pipefail

# Lot A4 : preuve empirique que le fast-path 64-bit inline emet bien LDRD/STRD
# (Fix A2/A3) pour un acces MO_64 ORDINAIRE de l'invite, en dumpant le code
# hote traduit (-d op,out_asm) restreint au TB de la fonction cible via
# -dfilter (bornes ELF exactes, nm -S). Reutilise run-pad.sh (deploiement,
# temperature, verrou un seul qemu a la fois) : QEMU_OPTS porte -dfilter/-d/-D.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
LOG_DIR="$TEST_DIR/logs/dump-tb"
GUEST="dump-tb"
SYMBOL="${1:-touch64}"

source "$TEST_DIR/pad.env"

if [ ! -f "$BUILD_OUT/$GUEST" ]; then
    echo "ERROR: $BUILD_OUT/$GUEST absent (lancer test/build-guests.sh dump-tb.c d'abord)"
    exit 1
fi
if [ ! -f "$BUILD_OUT/qemu-aarch64" ]; then
    echo "ERROR: $BUILD_OUT/qemu-aarch64 absent (lancer build.sh d'abord)"
    exit 1
fi

echo "[dump-tb.sh] Localisation du symbole $SYMBOL dans build-out/$GUEST..."
SYM_LINE=$(docker run --rm -v "$BUILD_OUT:/workspace/build-out" qemu64on32-build \
    aarch64-linux-gnu-nm -S "/workspace/build-out/$GUEST" | awk -v s="$SYMBOL" '$4 == s {print}')
if [ -z "$SYM_LINE" ]; then
    echo "ERROR: symbole $SYMBOL introuvable (nm -S) dans build-out/$GUEST"
    exit 1
fi

ADDR_HEX=$(echo "$SYM_LINE" | awk '{print $1}')
SIZE_HEX=$(echo "$SYM_LINE" | awk '{print $2}')
START=$((16#$ADDR_HEX))
END=$((16#$ADDR_HEX + 16#$SIZE_HEX))
RANGE=$(printf '0x%x..0x%x' "$START" "$END")
echo "[dump-tb.sh] $SYMBOL = $RANGE ($((END - START)) octets)"

REMOTE_LOG="$PAD_DIR/dump-tb.log"
QEMU_OPTS="-dfilter $RANGE -d op,out_asm -D $REMOTE_LOG" "$TEST_DIR/run-pad.sh" "$GUEST"

mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOCAL_LOG="$LOG_DIR/dump-tb-$SYMBOL-$STAMP.log"

$PAD_SSH "echo $PAD_PASS | sudo -S chmod 644 $REMOTE_LOG"
$PAD_SCP "$PAD_USER@$PAD_HOST:$REMOTE_LOG" "$LOCAL_LOG"

echo "[dump-tb.sh] Recherche LDRD/STRD dans le code hote emis pour $SYMBOL..."
if grep -inE 'ldrd|strd' "$LOCAL_LOG"; then
    echo "[dump-tb.sh] OK: LDRD/STRD present dans le dump. L'acces 64-bit ordinaire de"
    echo "[dump-tb.sh] l'invite est bien emis single-copy-atomic sur l'hote (Fix A2/A3 actif)."
    echo "[dump-tb.sh] Log complet : $LOCAL_LOG"
else
    echo "ERROR: aucune instruction LDRD/STRD trouvee dans $LOCAL_LOG"
    echo "ERROR: (fix A2/A3 inactif, ou -dfilter/capstone mal configures)"
    exit 1
fi
