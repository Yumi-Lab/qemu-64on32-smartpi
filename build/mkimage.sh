#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

echo "[mkimage.sh] Building Docker image qemu64on32-build..."
docker build -t qemu64on32-build "$BUILD_DIR"
echo "[mkimage.sh] Image qemu64on32-build built successfully."
