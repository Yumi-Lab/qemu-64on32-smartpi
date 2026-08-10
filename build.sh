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

    # Build RELEASE. Le --enable-debug historique, assertions TCG + -O0, utile pendant
    # la phase correctness, coutait 2 a 4x de debit TCG.
    #
    # -O3 -mcpu=cortex-a7 -flto : configuration MESUREE, pas supposee (phase X1, 2026-08-05).
    # Decomposition A/B contre le meme commit source, invite 2.1.217, charge --help JIT-active,
    # ABAB + chauffe jetee + medianes, mediane du bras baseline stable a 68 s sur les 4 runs :
    #     -O2 -mcpu             68 s   +0,00 %   <- -mcpu SEUL napporte RIEN
    #     -O3 -mcpu             66 s   +2,94 %
    #     -O2 -mcpu -flto       66 s   +2,94 %
    #     -O3 -mcpu -flto       65 s   +4,41 %   <- retenu
    # -mcpu est conserve bien quinerte seul : les quatre bras mesures le portaient, le
    # retirer donnerait une configuration NON MESUREE (il active probablement NEON, donc
    # use_neon_instructions=1 fige a la compile, et lauto-vectorisation du C chaud).
    # NOTE : pas dapostrophes dans ce bloc, tout le corps du build est une chaine simple-quotee.
    # LE CHIFFRE QUI COMPTE VRAIMENT (2026-08-10). Les +4,41 % ci-dessus viennent dune charge
    # MONO-THREAD (--help). Sur la charge REPRESENTATIVE de la cible — code auto-modifiant
    # MULTI-THREAD, ce que fait un JIT JavaScript — la meme configuration rend BEAUCOUP plus :
    #     mtbench smc, N=2, 4 coeurs (pad refroidi, PAD_CPUS=0-3), n=3, cellules 60 s
    #     -O2      : 3471 3641 3897 ops/s  -> mediane 3641
    #     -O3+LTO  : 6738 6131 6356 ops/s  -> mediane 6356      = +74,6 %
    # Les plages ne se chevauchent PAS (pire O3LTO 6131 > meilleur O2 3897).
    # Le scaling smc reste NEGATIF dans les deux cas (0,38x en -O2, 0,61x en -O3+LTO a N=2) :
    # LTO ne corrige pas lanti-scaling, il rend tout plus rapide, y compris en multi-thread.
    # LECON : pendant trois semaines loptimisation a ete jugee sur une charge mono-thread, ou
    # ces options paraissaient marginales. Mesurer sur la charge REELLE change lordre de
    # grandeur du verdict.
    #
    # Correctness validee sur cette configuration : gate V4-1G 6/6 (torn64 0 dechirure sur
    # 1 175 356 114 iterations, simd-dup2, smc-alias, claude --version rc=0, claude -p).
    # ATTENTION : LTO rend les traces de compilation moins lisibles et allonge le build.
    # Si un diagnostic devient difficile, rebuild sans `-flto` (cout : -2,94 % mono-thread,
    # et beaucoup plus en multi-thread — cf. les chiffres ci-dessus).
    ../configure \
      --cross-prefix=arm-linux-gnueabihf- \
      --static \
      --target-list=aarch64-linux-user \
      --extra-cflags="-O3 -mcpu=cortex-a7 -flto" \
      --extra-ldflags="-flto" \
      --disable-docs \
      --disable-tools \
      --disable-werror \
      --enable-capstone

    make -j6
    cp qemu-aarch64 /workspace/build-out/qemu-aarch64
    echo "[build.sh] Build completed. Artifact: /workspace/build-out/qemu-aarch64"
  '
