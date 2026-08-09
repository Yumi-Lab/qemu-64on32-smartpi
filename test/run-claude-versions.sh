#!/bin/bash
# Matrice `claude --version` sous le fork, PAR VERSION D'INVITE.
#
# Raison d'etre : la campagne V4-1H a traite l'invite comme une constante ("claude-native
# inchange depuis le 18 juillet") et a fait varier le qemu. C'etait faux : les runs VERTS du
# 22 juillet tournaient sur un invite 2.1.214, et le diagnostic du 27 juillet sur 2.1.205
# (cf. .loop/inject.md ligne 20, qui l'ecrivait deja). Or 2.1.205 TRAPPE et 2.1.214 BOOTE, sur
# le meme hote et le meme fork. Ce script rend cette variable explicite et mesurable.
#
# Il capture le rc REEL. Piege a ne pas reproduire : `time (cmd | tail); echo ${PIPESTATUS[0]}`
# rend le statut du SOUS-SHELL (donc de `tail`, donc 0) et pas celui de qemu. Ici le `echo RC=$?`
# est execute par le shell DISTANT, juste apres la commande, sans pipe ni `time` autour.
#
# Discipline pad (GOAL.md) : sha verifie des deux cotes, un seul qemu a la fois, taskset 2 coeurs,
# timeout dur, temperature avant/apres. PLUS un palier inconditionnel entre deux runs : enchainer
# des runs qemu sans respirer a FIGE le pad le 2026-07-31 (SSH mort, power-cycle physique requis),
# et ce gel n'etait PAS thermique (56-62 C) mais un thrash RAM/swap - chaque run mappe ~2 Go de VA
# sur une carte de 960 Mo + 1 Go de swap.
#
# Usage :
#   test/run-claude-versions.sh [timeout_s] SPEC [SPEC ...]
# ou SPEC vaut :
#   nom               -> binaire DEJA present sur le pad sous $PAD_DIR/nom
#   nom=/chemin/local -> deploye (gzip | ssh gunzip) puis verifie par sha avant de tourner
#
# Exemple (les builds officiels ne sont PAS dans le repo, ils pesent 255 Mo) :
#   test/run-claude-versions.sh 300 claude-native \
#       claude-2.1.205=build-out/claude-native \
#       claude-2.1.214=/chemin/claude-2.1.214-musl.bin
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$REPO_ROOT/test/logs/claude-versions"
QEMU_BIN="qemu-aarch64"

RUN_TIMEOUT="${1:-300}"; shift || true
[ $# -ge 1 ] || { echo "usage: $0 [timeout_s] SPEC [SPEC ...]" >&2; exit 2; }

SETTLE="${SETTLE:-45}"          # palier inconditionnel entre deux runs (secondes)

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/versions-$STAMP.txt"

PAD_FAIL_PREFIX="MATRICE VERSIONS"
# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

pad_alive || fail "pad $PAD_HOST injoignable (allume-le ; ce gate exige une execution reelle)"

say "=== MATRICE claude --version PAR VERSION D'INVITE, $STAMP ==="
say "pad=$PAD_USER@$PAD_HOST dir=$PAD_DIR qemu=$QEMU_BIN timeout=${RUN_TIMEOUT}s settle=${SETTLE}s"

# Le qemu du pad doit etre celui du build local : une matrice sur un emulateur perime ne prouve rien.
local_sha=$(shasum -a 256 "$REPO_ROOT/build-out/$QEMU_BIN" | cut -c1-16)
pad_sha=$(pad_capture "sha256sum $PAD_DIR/$QEMU_BIN 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha qemu)"
if [ "$local_sha" != "$pad_sha" ]; then
    say "  $QEMU_BIN differe (local=$local_sha pad=${pad_sha:-absent}), deploiement..."
    pad_put "$REPO_ROOT/build-out/$QEMU_BIN" "$PAD_DIR/$QEMU_BIN" || fail "deploiement de $QEMU_BIN echoue"
    $PAD_SSH "chmod +x $PAD_DIR/$QEMU_BIN"
fi
say "  qemu-aarch64 sha=$local_sha (identique des deux cotes)"
say ""

RESULTS=()
first=1
for spec in "$@"; do
    name="${spec%%=*}"
    src="${spec#*=}"; [ "$src" = "$spec" ] && src=""

    # Deploiement conditionnel, avec sha des deux cotes.
    if [ -n "$src" ]; then
        [ -f "$src" ] || fail "$src absent"
        lsha=$(shasum -a 256 "$src" | cut -c1-16)
        psha=$(pad_capture "sha256sum $PAD_DIR/$name 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha $name)"
        if [ "$lsha" != "$psha" ]; then
            say "  $name differe (local=$lsha pad=${psha:-absent}), deploiement de $src..."
            pad_put "$src" "$PAD_DIR/$name" || fail "deploiement de $name echoue"
            $PAD_SSH "chmod +x $PAD_DIR/$name"
            psha=$(pad_capture "sha256sum $PAD_DIR/$name | cut -c1-16")
            [ "$lsha" = "$psha" ] || fail "$name : sha divergent apres deploiement (local=$lsha pad=$psha)"
        fi
        gsha="$lsha"
    else
        gsha=$(pad_capture "sha256sum $PAD_DIR/$name 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha $name)"
        [ -n "$gsha" ] || fail "$name absent du pad et aucun chemin local donne"
    fi

    # Palier entre deux runs : voir l'entete (gel du 2026-07-31, non thermique).
    if [ "$first" = 0 ]; then
        say "  palier de ${SETTLE}s avant le run suivant..."
        sleep "$SETTLE"
        pad_alive || fail "le pad a cesse de repondre apres le run precedent (gel : power-cycle physique requis)"
    fi
    first=0

    require_idle
    tb=$(wait_cool)
    t0=$(date +%s)
    out=$(pad_capture "cd $PAD_DIR && taskset -c 0,1 timeout $RUN_TIMEOUT \
          env HOME=$PAD_DIR DISABLE_AUTOUPDATER=1 \
          ./$QEMU_BIN -L sysroot ./$name --version 2>&1; echo RC=\$?") \
        || fail "$name : pad injoignable pendant le run (gel probable)"
    t1=$(date +%s)
    ta=$(temp_now)

    rc="$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)"
    banner="$(printf '%s' "$out" | grep -v '^RC=' | tail -1)"

    say "--- $name (sha=$gsha) ---"
    printf '%s\n' "$out" | tee -a "$LOG" >/dev/null
    say "    rc=$rc  elapsed=$((t1 - t0))s  temp $((tb / 1000))C->$((ta / 1000))C"
    say "    sortie: $banner"
    say ""
    RESULTS+=("$(printf '%-20s sha=%-16s rc=%-4s %4ss  %s' "$name" "$gsha" "$rc" "$((t1 - t0))" "$banner")")
done

say "=== RECAP ==="
for r in "${RESULTS[@]}"; do say "$r"; done
say ""
say "Log complet : $LOG"
