#!/bin/bash
# Diagnostic du SIGTRAP de claude-native sous le fork, sur le pad.
#
# Point de depart : l'orchestrateur signale `claude-native --version` qui meurt en
# SIGTRAP (signal 5, rc=133) sous le build V4-1, et soupconne une regression du
# dedup de TB. Ce script tranche la question en trois mesures, et sa sortie est la
# PREUVE a coller au Journal.
#
# Ce qu'il etablit, dans cet ordre :
#   1. REPRO      : le SIGTRAP sous le build courant (attendu rc=133).
#   2. BISECTION  : le meme run sous `qemu-aarch64-baseline` (build ANTERIEUR a
#                   V4-1). S'il trappe aussi, V4-1 est HORS DE CAUSE.
#   3. CAUSE      : echantillonne VmSize du process qemu jusqu'a sa mort, et
#                   releve le dernier syscall avant le trap. La cause attendue est
#                   un mmap invite qui rend ENOMEM parce que l'espace d'adressage
#                   HOTE 32 bits (~3 Go utilisables) est sature, pas une faute TCG :
#                   le runtime invite appelle alors son propre gestionnaire OOM,
#                   qui execute un `brk` (d'ou le SIGTRAP).
#
# Le trap n'est donc PAS une instruction mal traduite : c'est le guest qui abandonne
# volontairement. Le distinguer importe, un `brk` invite ne se corrige pas dans TCG.
#
# Regles pad GOAL.md respectees : sha verifie des deux cotes avant tout run, un seul
# qemu a la fois (on ne tue jamais le process d'autrui), taskset 2 coeurs, timeout
# dur, temperature lue avant et apres chaque run, refus au-dela de PAD_MAX_TEMP.
#
# Usage : test/diag-claude-sigtrap.sh [timeout_s]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/sigtrap-repro"
QEMU_BIN="qemu-aarch64"
BASELINE_BIN="qemu-baseline"
GUEST="claude-native"

RUN_TIMEOUT="${1:-300}"

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/diag-sigtrap-$STAMP.txt"

PAD_FAIL_PREFIX="DIAG SIGTRAP"
# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# Un run de claude-native sous l'emulateur demande. Args : tag, binaire_qemu, env.
run_claude() {
    local tag="$1" qbin="$2" qenv="${3:-}"
    local tb ta out

    require_idle
    tb=$(wait_cool)
    # STDOUT N'EST QUE LA VALEUR DE RETOUR (cf. entete de pad-lib.sh) : l'appelant
    # capture cette fonction par $(...) et en extrait `RC=` par grep.
    say "--- $tag (qemu=$qbin env=${qenv:-aucun}) temp_before=$((tb / 1000))C ---"
    out=$($PAD_SSH "cd $PAD_DIR && taskset -c 0,1 timeout $RUN_TIMEOUT \
          env HOME=$PAD_DIR DISABLE_AUTOUPDATER=1 $qenv \
          ./$qbin -L sysroot ./$GUEST --version 2>&1; echo RC=\$?")
    ta=$(temp_now)
    printf '%s\n' "$out" >>"$LOG"
    say "    temp_after=$((ta / 1000))C"
    printf '%s' "$out"
}

say "=== DIAG SIGTRAP claude-native, $STAMP ==="
say "pad=$PAD_USER@$PAD_HOST dir=$PAD_DIR timeout=${RUN_TIMEOUT}s"

if ! sshpass -p "$PAD_PASS" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -o BatchMode=no "$PAD_USER@$PAD_HOST" true 2>/dev/null; then
    fail "pad $PAD_HOST injoignable (allume-le, ce diagnostic exige une execution reelle)"
fi

# Le sha des deux cotes : un diagnostic sur un binaire perime ne prouve rien.
for b in "$QEMU_BIN" "$GUEST"; do
    [ -f "$BUILD_OUT/$b" ] || fail "$BUILD_OUT/$b absent (build.sh d'abord)"
    local_sha=$(shasum -a 256 "$BUILD_OUT/$b" | cut -c1-16)
    pad_sha=$(pad_capture "sha256sum $PAD_DIR/$b 2>/dev/null | cut -c1-16") \
        || fail "pad injoignable (sha $b)"
    if [ "$local_sha" != "$pad_sha" ]; then
        say "  $b differe (local=$local_sha pad=${pad_sha:-absent}), deploiement..."
        pad_put "$BUILD_OUT/$b" "$PAD_DIR/$b" || fail "deploiement de $b echoue"
        $PAD_SSH "chmod +x $PAD_DIR/$b"
        pad_sha=$(pad_capture "sha256sum $PAD_DIR/$b | cut -c1-16")
        [ "$local_sha" = "$pad_sha" ] || fail "$b toujours different apres deploiement"
    fi
    say "  $b sha=$local_sha (identique des deux cotes)"
done

# ---------------------------------------------------------------- 1. REPRO
say ""
say "[1/3] REPRO du SIGTRAP sous le build courant"
out=$(run_claude "repro build courant" "$QEMU_BIN")
rc_current=$(echo "$out" | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
if [ "$rc_current" = "0" ]; then
    say "  claude-native rend rc=0 : le blocage signale ne se reproduit PAS ici."
    say "DIAG SIGTRAP: pas de repro, rien a diagnostiquer."
    exit 0
fi
say "  rc=$rc_current (133 = SIGTRAP, le blocage est reproduit)"

# ------------------------------------------------------------ 2. BISECTION
say ""
say "[2/3] BISECTION : le meme run sous le build ANTERIEUR a V4-1"
if [ ! -f "$BUILD_OUT/qemu-aarch64-baseline" ]; then
    say "  build-out/qemu-aarch64-baseline absent, bisection impossible (etape sautee)"
    rc_baseline="absent"
else
    base_local=$(shasum -a 256 "$BUILD_OUT/qemu-aarch64-baseline" | cut -c1-16)
    base_pad=$(pad_capture "sha256sum $PAD_DIR/$BASELINE_BIN 2>/dev/null | cut -c1-16")
    if [ "$base_local" != "$base_pad" ]; then
        say "  deploiement du baseline (local=$base_local pad=${base_pad:-absent})..."
        pad_put "$BUILD_OUT/qemu-aarch64-baseline" "$PAD_DIR/$BASELINE_BIN" \
            || fail "deploiement du baseline echoue"
        $PAD_SSH "chmod +x $PAD_DIR/$BASELINE_BIN"
    fi
    out=$(run_claude "bisection baseline pre-V4-1" "$BASELINE_BIN")
    rc_baseline=$(echo "$out" | grep -o 'RC=[0-9]*' | tail -1 | cut -d= -f2)
    say "  baseline rc=$rc_baseline"
fi

# ---------------------------------------------------------------- 3. CAUSE
# VmSize du process qemu au fil du run + dernier syscall avant le trap. Le probe
# tourne SUR le pad : echantillonner depuis le Mac via ssh raterait la fenetre.
say ""
say "[3/3] CAUSE : espace d'adressage hote au moment du trap + dernier syscall"
require_idle
tb=$(wait_cool)
say "--- probe VmSize + strace, temp_before=$((tb / 1000))C ---"
$PAD_SSH "cat > $PAD_DIR/vaprobe.sh" <<PROBE
#!/bin/sh
# Echantillonne VmSize du qemu jusqu'a sa mort et garde le dernier etat de /proc.
cd $PAD_DIR || exit 1
rm -f va.log maps.snap strace.log
taskset -c 0,1 timeout $RUN_TIMEOUT env HOME=$PAD_DIR DISABLE_AUTOUPDATER=1 \\
  ./$QEMU_BIN -L sysroot -strace ./$GUEST --version >/dev/null 2>strace.log &
W=\$!
Q=""
while [ -z "\$Q" ]; do
    kill -0 "\$W" 2>/dev/null || break
    Q=\$(pgrep -x $QEMU_BIN | head -1)
done
while [ -r "/proc/\$Q/status" ]; do
    printf '%s %s maps=%s\n' \\
      "\$(grep '^VmSize' /proc/\$Q/status | tr -s ' \t' ' ')" \\
      "\$(grep '^VmRSS' /proc/\$Q/status | tr -s ' \t' ' ')" \\
      "\$(wc -l < /proc/\$Q/maps)" >> va.log
    cp "/proc/\$Q/maps" maps.snap 2>/dev/null
    sleep 2
done
wait "\$W"; echo "RC=\$?"
echo "=== dernier VmSize avant le trap ==="; tail -2 va.log
echo "=== dernier syscall avant le trap ==="; tail -3 strace.log
PROBE
probe_out=$($PAD_SSH "cd $PAD_DIR && sh vaprobe.sh 2>&1")
ta=$(temp_now)
echo "$probe_out" | tee -a "$LOG"
say "    temp_after=$((ta / 1000))C"

# Rapatrie la carte memoire pour la totaliser ici (le pad n'a ni python ni awk gnu).
$PAD_SSH "cat $PAD_DIR/maps.snap" > "$LOGDIR/maps-$STAMP.snap" 2>/dev/null
va_total=$(awk -F'[- ]' '
    /^[0-9a-f]+-[0-9a-f]+ / {
        s = 0; e = 0
        for (i = 1; i <= length($1); i++) s = s * 16 + index("0123456789abcdef", substr($1, i, 1)) - 1
        for (i = 1; i <= length($2); i++) e = e * 16 + index("0123456789abcdef", substr($2, i, 1)) - 1
        tot += e - s
    }
    END { printf "%.0f", tot / 1048576 }
' "$LOGDIR/maps-$STAMP.snap" 2>/dev/null)

say ""
say "=== VERDICT ==="
say "  build courant     : rc=$rc_current"
say "  baseline pre-V4-1 : rc=$rc_baseline"
say "  VA hote totale mappee au dernier echantillon : ${va_total:-?} Mo"
if [ "$rc_baseline" = "$rc_current" ]; then
    say "  => le baseline ANTERIEUR a V4-1 echoue a l'identique : V4-1 est HORS DE CAUSE."
fi
if echo "$probe_out" | grep -q 'errno=12'; then
    say "  => dernier syscall = mmap ENOMEM : l'espace d'adressage hote 32 bits est sature."
    say "     Le SIGTRAP est le gestionnaire OOM du runtime invite (brk), pas une faute TCG."
fi
say ""
say "Log complet : $LOG"
