#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_ROOT/build-out"
QEMU_DIR="$REPO_ROOT/qemu"

mkdir -p "$BUILD_DIR"

# meson execute un binaire armhf pendant sa sanity-check de cross-compilation
# (configure du qemu). L'hote colima est arm64 : sans handler binfmt_misc pour
# arm, l'execution echoue avec "Exec format error". Le handler vit dans le
# noyau de la VM colima et disparait a chaque redemarrage de la VM, d'ou ce
# check idempotent (sans effet si deja enregistre).
if ! docker run --rm arm64v8/debian:bookworm test -e /proc/sys/fs/binfmt_misc/qemu-arm 2>/dev/null; then
  echo "[build.sh] binfmt qemu-arm absent, enregistrement (docker run --privileged tonistiigi/binfmt)..."
  docker run --rm --privileged tonistiigi/binfmt --install arm
fi

docker run --rm \
  -v "$QEMU_DIR:/workspace/qemu" \
  -v "$BUILD_DIR:/workspace/build-out" \
  qemu64on32-build \
  bash -c '
    set -euo pipefail
    cd /workspace/qemu

    mkdir -p build
    cd build

    # Build RELEASE -O2. Le --enable-debug historique, assertions TCG + -O0,
    # utile pendant la phase correctness, coutait 2 a 4x de debit TCG.
    ../configure \
      --cross-prefix=arm-linux-gnueabihf- \
      --static \
      --target-list=aarch64-linux-user \
      --disable-docs \
      --disable-tools \
      --disable-werror \
      --enable-capstone

    make -j6
    cp qemu-aarch64 /workspace/build-out/qemu-aarch64
    echo "[build.sh] Build completed. Artifact: /workspace/build-out/qemu-aarch64"
  '
