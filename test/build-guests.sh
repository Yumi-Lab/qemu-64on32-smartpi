#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_DIR="$REPO_ROOT/build-out"

mkdir -p "$BUILD_DIR"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <guest.c> [guest.c...]"
    echo "Example: $0 hello.c torn64.c"
    exit 1
fi

for src in "$@"; do
    name="${src%.c}"
    if [ ! -f "$TEST_DIR/$src" ]; then
        echo "ERROR: $TEST_DIR/$src introuvable"
        exit 1
    fi
    echo "[build-guests.sh] Compiling $src -> build-out/$name (aarch64 static)..."
    docker run --rm \
      -v "$TEST_DIR:/workspace/test" \
      -v "$BUILD_DIR:/workspace/build-out" \
      qemu64on32-build \
      aarch64-linux-gnu-gcc -static -O2 -pthread \
        -o "/workspace/build-out/$name" "/workspace/test/$src"
done

echo "[build-guests.sh] Done."
