#!/bin/bash
# V2, harnais de test du binaire natif Claude Code (linux-arm64-musl) sous NOTRE
# fork qemu, sur le pad. Critere du lot V2 (cf. GOAL.md / PROGRESS.md) : le binaire
# doit BOOTER et ne PAS crasher (crash interdit, lenteur OK). C'est la vraie cible
# JSC/Bun du fix Fix A + du fix SIMD dup2_vec.
#
# Le binaire natif est DYNAMIQUE (interp /lib/ld-musl-aarch64.so.1) : le pad est
# armv7/glibc, il n'a pas le loader musl aarch64. On le fournit via un sysroot
# (`-L $SYSROOT`) contenant seulement `lib/ld-musl-aarch64.so.1` (le loader musl
# EST la libc, 0 DT_NEEDED en plus). qemu ne redirige que les chemins qui existent
# sous le prefixe : /proc, /etc, /dev du pad restent visibles normalement.
#
# Regles GOAL respectees, tout cote pad : taskset (CLAUDE_CPUS, "0" mono-coeur pour
# le boot lourd a froid ou "0,1"), MemoryMax
# (systemd-run --user --scope, protection OOM SANS root), timeout (garde-fou dur),
# garde thermique (abort avant le gel ~100C, echantillon fin anti-gel), un seul
# qemu a la fois (refus si un autre tourne), teardown limite a NOTRE pid. HOME est
# confine au dossier de travail (ecritures de claude dans $PAD_DIR/.claude, jamais
# la config systeme). Ne touche jamais /opt/grok ni /opt/yumi-ai-gateway.
#
# Usage : run-claude-pad.sh <version|prompt> [timeout_s] [prompt_text]
#   version : claude --version (preuve de boot, sans reseau ni auth)
#   prompt  : claude -p "<prompt_text>" (boot + tour agent ; sans cle il atteint
#             une erreur d'auth propre = boot sans crash ; avec cle il repond)
# Sortie machine (derniere ligne) :
#   RESULT=<BOOTED|CRASHED|TEMP_ABORT|TIMEOUT|NOSTART> exit_rc=<n> elapsed=<s>
#          out_bytes=<n> peak_temp_c=<n> min_temp_c=<n> temp_before_c=<n>
#   BOOTED    = qemu a execute claude jusqu'a une sortie/erreur propre (rc<128).
#   CRASHED   = qemu a AVORTE (signal, ex. SIGABRT d'une assertion TCG) = bug fork.
#   TIMEOUT   = coupe par timeout (rc=124) ou SIGTERM (rc=143), pas un crash.
#   TEMP_ABORT= coupe par la garde thermique du H3.
#   NOSTART   = qemu n'a jamais demarre.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
QEMU_BIN="qemu-aarch64"

# shellcheck disable=SC1091
source "$TEST_DIR/pad.env"

MODE="${1:?usage: run-claude-pad.sh <version|prompt> [timeout_s] [prompt_text]}"
TIMEOUT="${2:-300}"
PROMPT_TEXT="${3:-Reply with the single word OK and nothing else.}"

# Reglages (surchargibles par l'environnement, aucun hardcodage disperse).
MEMMAX="${CLAUDE_MEMMAX:-600M}"
ABORT_TEMP="${CLAUDE_ABORT_TEMP:-90000}"   # milli-degres : coupe avant le gel ~100C
INTERVAL="${CLAUDE_POLL_INTERVAL:-15}"     # secondes entre deux ticks
CPUS="${CLAUDE_CPUS:-0,1}"                 # liste taskset : "0" (mono-coeur, boot lourd/froid) ou "0,1"
EXTRA_ENV="${CLAUDE_EXTRA_ENV:-}"          # paires NAME=VAL (sans espaces) ajoutees a l'env de qemu,
                                           # ex: "QEMU_TB_SIZE=256 BUN_JSC_useJIT=0"
SETARCH="${CLAUDE_SETARCH:-}"              # "1" = lancer qemu sous setarch -R (ASLR hote coupe,
                                           # layout deterministe, requis par le cache -tb-cache)
QEMU_OPTS="${CLAUDE_QEMU_OPTS:-}"          # options passees a qemu lui-meme,
                                           # ex: "-cpu cortex-a53" (invite pre-LSE2)

CLAUDE_PAD="$PAD_DIR/claude-native"
SYSROOT="$PAD_DIR/sysroot"
QEMU_ON_PAD="$PAD_DIR/$QEMU_BIN"

case "$MODE" in
    version) CLAUDE_ARGS="--version" ;;
    help)    CLAUDE_ARGS="--help" ;;   # init CLI complete + rendu, sans reseau ni auth
    prompt)  CLAUDE_ARGS="-p" ;;   # le texte du prompt est passe separement (quoting)
    *) echo "ERROR: mode inconnu '$MODE' (attendu: version|help|prompt)" >&2; exit 2 ;;
esac
# Arguments additionnels du CLI (ex: "--output-format stream-json --verbose"), sans quoting interne.
CLAUDE_ARGS="$CLAUDE_ARGS${CLAUDE_ARGS_EXTRA:+ $CLAUDE_ARGS_EXTRA}"

# --- Meme robustesse de connexion que run-pad.sh (sshd throttle les rafales) -----
pad_capture() {
    local n=0 max=5 out
    until out=$($PAD_SSH "$@" 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && { echo "[run-claude-pad] lecture pad echouee apres $max tentatives" >&2; return 1; }
        sleep $((n * 3))
    done
    printf '%s' "$out"
}

# --- Verification du deploiement (aucun re-scp du binaire de 255 Mo ici) ----------
echo "[run-claude-pad] Verification du deploiement sur le pad..."
LOCAL_QEMU_SHA=$(shasum -a 256 "$BUILD_OUT/$QEMU_BIN" | cut -d' ' -f1)
PAD_QEMU_SHA=$(pad_capture "sha256sum $QEMU_ON_PAD 2>/dev/null | cut -d' ' -f1")
if [ "$LOCAL_QEMU_SHA" != "$PAD_QEMU_SHA" ]; then
    echo "ERROR: le qemu du pad ($PAD_QEMU_SHA) != le fork local ($LOCAL_QEMU_SHA). Deployer build-out/$QEMU_BIN d'abord." >&2
    exit 1
fi
echo "  qemu fork OK ($PAD_QEMU_SHA)"
DEPLOY_OK=$(pad_capture "test -x $CLAUDE_PAD && test -f $SYSROOT/lib/ld-musl-aarch64.so.1 && echo yes || echo no")
if [ "$DEPLOY_OK" != "yes" ]; then
    echo "ERROR: claude-native ou le loader musl absent sur le pad ($CLAUDE_PAD / $SYSROOT/lib/ld-musl-aarch64.so.1)." >&2
    exit 1
fi
echo "  claude-native + loader musl OK"

# --- Garde : un seul qemu a la fois -----------------------------------------------
QEMU_RUNNING=$(pad_capture "pgrep -x $QEMU_BIN || echo 0")
if [ "$QEMU_RUNNING" != "0" ]; then
    echo "ERROR: un qemu-aarch64 tourne deja sur le pad, on n'en lance jamais un 2e (ni ne tue celui d'autrui)." >&2
    exit 1
fi

# --- Temperature avant (attente si trop chaud) ------------------------------------
TEMP_BEFORE=$(pad_capture "cat /sys/class/thermal/thermal_zone0/temp")
echo "[run-claude-pad] Temperature before: $((TEMP_BEFORE / 1000))C"
if [ "$TEMP_BEFORE" -gt 80000 ]; then
    echo "  trop chaud, attente du refroidissement..."
    for i in $(seq 1 10); do
        sleep 60
        TEMP_BEFORE=$(pad_capture "cat /sys/class/thermal/thermal_zone0/temp")
        echo "  ... $((TEMP_BEFORE / 1000))C"
        [ "$TEMP_BEFORE" -le 80000 ] && break
    done
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_PAD="$PAD_DIR/claude-${MODE}-${STAMP}.out"
ERR_PAD="$PAD_DIR/claude-${MODE}-${STAMP}.err"

echo "[run-claude-pad] Lancement: claude $CLAUDE_ARGS ${MODE:+}(mode=$MODE, timeout=${TIMEOUT}s, MemoryMax=$MEMMAX, abort=$((ABORT_TEMP/1000))C) sous le fork"

# Script moniteur execute SUR LE PAD en une seule session ssh. qemu est lance dans
# un scope systemd --user (OOM sans root) borne par timeout ; meme si la liaison ssh
# tombe, `timeout` termine qemu. Le loop surveille temp + aliveness et coupe NOTRE
# pid seul si la temperature approche le gel. Le prompt est passe en argument
# positionnel de bash ("$1") pour un quoting propre.
REMOTE=$(cat <<'REMOTE_EOF'
set -u
QEMU="$Q"; CLA="$C"; SYS="$S"; HOMEDIR="$H"; QOPTS="$QO"
ARGS="$A"; MODE="$M"; PROMPT="$1"
OUT="$O"; ERR="$E"; TIMEOUT="$T"; MEMMAX="$MM"; ABORT="$AB"; INTERVAL="$IV"; CPUS="$CP"
EXTRA="$X"
SA=""; [ -n "$SX" ] && SA="setarch $(uname -m) -R"
: >"$OUT"; : >"$ERR"
peak=0; min=999000; rc=""
tempc(){ cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null; }
# Lance qemu -> claude en tache de fond, capture le code de sortie dans un fichier.
RCF="$OUT.rc"; : >"$RCF"
if [ "$MODE" = "prompt" ]; then
  ( systemd-run --user --scope -q -p MemoryMax="$MEMMAX" -- \
      taskset -c "$CPUS" timeout -k 60 "$TIMEOUT" \
      env HOME="$HOMEDIR" DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 $EXTRA \
      $SA "$QEMU" $QOPTS -L "$SYS" "$CLA" $ARGS "$PROMPT" </dev/null >>"$OUT" 2>>"$ERR"; echo $? >"$RCF" ) &
else
  ( systemd-run --user --scope -q -p MemoryMax="$MEMMAX" -- \
      taskset -c "$CPUS" timeout -k 60 "$TIMEOUT" \
      env HOME="$HOMEDIR" DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 $EXTRA \
      $SA "$QEMU" $QOPTS -L "$SYS" "$CLA" $ARGS </dev/null >>"$OUT" 2>>"$ERR"; echo $? >"$RCF" ) &
fi
LP=$!
# Retrouver NOTRE pid qemu (comm exact, exclut la gateway -static).
PID=""
for _ in $(seq 1 40); do sleep 2; PID=$(pgrep -x qemu-aarch64 | head -1); [ -n "$PID" ] && break; done
if [ -z "$PID" ]; then
  # qemu a pu deja finir (boot ultra court) : lire le rc si present.
  wait "$LP" 2>/dev/null; rc=$(cat "$RCF" 2>/dev/null)
  if [ -n "$rc" ]; then
    # 124 = timeout SIGTERM, 143 = 128+SIGTERM, 137 = 128+SIGKILL (timeout -k) :
    # ce sont des coupures par le garde-fou, PAS des crashs. Seuls les autres
    # signaux >=128 (139 SIGSEGV, 134 SIGABRT, 132 SIGILL, 135 SIGBUS...) le sont.
    res=BOOTED
    if [ "$rc" -ge 128 ] && [ "$rc" -ne 143 ] && [ "$rc" -ne 137 ]; then res=CRASHED; fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then res=TIMEOUT; fi
    ta=$(tempc); echo "RESULT=$res exit_rc=$rc elapsed=0 out_bytes=$(wc -c <"$OUT") peak_temp_c=$(( ${ta:-0}/1000 )) min_temp_c=$(( ${ta:-0}/1000 )) temp_before_c=$(( ${ta:-0}/1000 ))"
    exit 0
  fi
  echo "RESULT=NOSTART exit_rc=NA elapsed=0 out_bytes=0 peak_temp_c=0 min_temp_c=0 temp_before_c=0"; exit 1
fi
START=$(date +%s); result=TIMEOUT
while :; do
  el=$(( $(date +%s) - START ))
  if [ ! -d "/proc/$PID" ]; then
    wait "$LP" 2>/dev/null; rc=$(cat "$RCF" 2>/dev/null)
    # 124/143/137 = coupures du garde-fou (timeout, timeout -k), pas des crashs.
    if [ -n "$rc" ] && [ "$rc" -ge 128 ] && [ "$rc" -ne 143 ] && [ "$rc" -ne 137 ]; then result=CRASHED
    elif [ "${rc:-0}" -eq 124 ] || [ "${rc:-0}" -eq 143 ] || [ "${rc:-0}" -eq 137 ]; then result=TIMEOUT
    else result=BOOTED; fi
    break
  fi
  t=$(tempc)
  if [ -n "${t:-}" ]; then
    [ "$t" -gt "$peak" ] && peak=$t
    [ "$t" -lt "$min" ] && min=$t
    rss=$(awk '/VmRSS/{print $2}' "/proc/$PID/status" 2>/dev/null)
    echo "[claudepad] t=${el}s temp=$(( t/1000 ))C rss=$(( ${rss:-0}/1024 ))MB out=$(wc -c <"$OUT")" >&2
    if [ "$t" -ge "$ABORT" ]; then
      result=TEMP_ABORT
      kill "$PID" 2>/dev/null; sleep 2; kill -9 "$PID" 2>/dev/null
      break
    fi
  fi
  # sommeil fin anti-gel (tranches de 5s)
  left="$INTERVAL"
  while [ "$left" -gt 0 ]; do
    c=5; [ "$left" -lt 5 ] && c="$left"; sleep "$c"; left=$(( left - c ))
    tt=$(tempc)
    if [ -n "${tt:-}" ] && [ "$tt" -ge "$ABORT" ]; then
      [ "$tt" -gt "$peak" ] && peak=$tt
      result=TEMP_ABORT; kill "$PID" 2>/dev/null; sleep 2; kill -9 "$PID" 2>/dev/null; break 2
    fi
  done
done
FINAL=$(( $(date +%s) - START ))
[ -z "$rc" ] && rc=$(cat "$RCF" 2>/dev/null)
[ "$min" -eq 999000 ] && min=$peak
ta=$(tempc); [ -n "${ta:-}" ] && { [ "$ta" -gt "$peak" ] && peak=$ta; }
echo "RESULT=$result exit_rc=${rc:-NA} elapsed=$FINAL out_bytes=$(wc -c <"$OUT") peak_temp_c=$(( peak/1000 )) min_temp_c=$(( min/1000 )) temp_before_c=$TB"
REMOTE_EOF
)

set +e
$PAD_SSH "Q='$QEMU_ON_PAD' C='$CLAUDE_PAD' S='$SYSROOT' H='$PAD_DIR' A='$CLAUDE_ARGS' M='$MODE' O='$OUT_PAD' E='$ERR_PAD' T='$TIMEOUT' MM='$MEMMAX' AB='$ABORT_TEMP' IV='$INTERVAL' CP='$CPUS' X='$EXTRA_ENV' SX='$SETARCH' QO='$QEMU_OPTS' TB='$((TEMP_BEFORE/1000))' bash -s -- '$PROMPT_TEXT'" <<<"$REMOTE"
SSH_RC=$?
set -e 2>/dev/null || true

echo "[run-claude-pad] ssh_rc=$SSH_RC"
echo "[run-claude-pad] --- claude stdout (tail) ---"
$PAD_SSH "tail -30 '$OUT_PAD' 2>/dev/null" || true
echo "[run-claude-pad] --- claude stderr (tail) ---"
$PAD_SSH "tail -30 '$ERR_PAD' 2>/dev/null" || true
echo "[run-claude-pad] logs pad: $OUT_PAD / $ERR_PAD"
exit $SSH_RC
