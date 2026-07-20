#!/bin/bash
# V1, orchestrateur Mac-side du run de survie grok. Le run lui-meme est PAD-SIDE
# et AUTONOME (cf. test/grok-pad-monitor.sh) : ce script ne fait que deployer,
# verifier la surete, LANCER le moniteur en detache sur le pad, puis SONDER son
# log. Un run de 30 min ne bloque donc jamais une session : on lance ("launch")
# puis on sonde ("poll") occasionnellement.
#
# But V1 : prouver que le binaire NATIF grok survit >= 30 min sous notre qemu
# fork (contre ~2-5 min de crash JIT en baseline), 2 coeurs, pas d'OOM, pas de gel.
#
# Usage :
#   test/run-grok-pad.sh launch [DURATION_s] [INTERVAL_s] ["seed prompt"]
#       Deploie, verifie (temp, un seul qemu), lance le moniteur pad-side en
#       detache (setsid nohup) et rend la main tout de suite. Ecrit l'etat du
#       run dans test/logs/grok-tui/.last-run.
#   test/run-grok-pad.sh poll [STAMP]
#       Rapatrie le log pad du dernier run (ou du STAMP donne) dans
#       test/logs/grok-tui/, affiche le tail + la ligne RESULT=. Code retour :
#       0 = SURVIVED, 2 = run encore en cours, 1 = CRASHED/TEMP_ABORT/NOSTART.
#   test/run-grok-pad.sh status
#       Etat brut du pad (temp, qemu en cours).
#
#   BASELINE_QEMU=/opt/grok/qemu-aarch64-static test/run-grok-pad.sh launch ...
#       Mode demo baseline (crash attendu) : execute grok sous un qemu deja
#       present sur le pad au lieu du fork.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
BUILD_OUT="$REPO_ROOT/build-out"
LOG_DIR="$REPO_ROOT/test/logs/grok-tui"
QEMU_BIN="qemu-aarch64"
MONITOR_SRC="$TEST_DIR/grok-pad-monitor.sh"
STATE_FILE="$LOG_DIR/.last-run"
# shellcheck disable=SC1091
source "$TEST_DIR/pad.env"
mkdir -p "$LOG_DIR"

# Plafond thermique du run (mC). Empirique : grok sous fork, 2 coeurs, plafonne
# ~83-85C (le SoC throttle des 75C et se stabilise), le gel du H3 survient
# ~100-102C. 92C = plafond dur : l'echantillon de temperature n'est pris qu'a
# intervalle, donc 95C laissait une marge trop courte avant le gel si la temp
# grimpe entre deux mesures ; 92C garde ~8C de reserve (un WARN est logue des 90C,
# et le moniteur pad affine la mesure en tranches, cf. grok-pad-monitor.sh). Un run
# est demarre uniquement si la temperature est deja <=80C (cooldown force ci-dessous).
ABORT_TEMP="${ABORT_TEMP:-92000}"
BASELINE_QEMU="${BASELINE_QEMU:-}"

# Le sshd du pad throttle les rafales : on retente une connexion transitoirement
# rejetee. NE JAMAIS retenter le run grok lui-meme (il est pad-side, autonome).
pad_retry() {
    local n=0 max=5
    until "$@"; do
        n=$((n + 1)); [ "$n" -ge "$max" ] && { echo "[grok] connexion pad KO x$max" >&2; return 1; }
        sleep $((n * 3))
    done
}
pad_capture() {
    local n=0 max=5 out
    until out=$("$@" 2>/dev/null); do
        n=$((n + 1)); [ "$n" -ge "$max" ] && { echo "[grok] lecture pad KO x$max" >&2; return 1; }
        sleep $((n * 3))
    done
    printf '%s' "$out"
}

# UN SEUL qemu a la fois : compter tout process dont le comm commence par
# qemu-aarch64 (le notre ET le qemu-aarch64-static de la gateway). ps -eo comm
# n'auto-matche pas. On ne TUE jamais le qemu d'autrui : on refuse et on reessaiera.
running_qemu_count() { pad_capture $PAD_SSH "ps -eo comm | grep -c '^qemu-aarch64' || true"; }

cmd_status() {
    echo "[grok] pad status :"
    pad_capture $PAD_SSH "echo -n 'temp='; awk '{printf \"%dC\n\", \$1/1000}' /sys/class/thermal/thermal_zone0/temp; echo 'qemu en cours :'; ps -eo pid,etimes,comm,args | grep '^[ ]*[0-9]* .*qemu-aarch64' | grep -v grep || echo '  (aucun)'"
    echo
}

cmd_launch() {
    local duration="${1:-1800}" interval="${2:-25}"
    local seed="${3:-Reply with just the word READY, then wait for further input.}"
    local stamp tag qemu_on_pad
    stamp="$(date +%Y%m%d-%H%M%S)"
    tag="fork"; [ -n "$BASELINE_QEMU" ] && tag="baseline"

    local mon_log="v1-grok-$tag-monitor-$stamp.log"
    local content_log="v1-grok-$tag-content-$stamp.log"
    local env_file="grok-run-$stamp.env"

    if [ -n "$BASELINE_QEMU" ]; then
        qemu_on_pad="$BASELINE_QEMU"
        echo "[grok] MODE BASELINE : grok sous $qemu_on_pad (crash attendu)"
    else
        [ -f "$BUILD_OUT/$QEMU_BIN" ] || { echo "ERROR: $QEMU_BIN absent de $BUILD_OUT (lancer build.sh)" >&2; exit 1; }
        qemu_on_pad="$PAD_DIR/$QEMU_BIN"
        echo "[grok] fork sha256=$(shasum -a 256 "$BUILD_OUT/$QEMU_BIN" | cut -d' ' -f1)"
        echo "[grok] deploiement de $QEMU_BIN..."
        pad_retry $PAD_SSH "mkdir -p $PAD_DIR"
        pad_retry $PAD_SCP "$BUILD_OUT/$QEMU_BIN" "$PAD_USER@$PAD_HOST:$PAD_DIR/$QEMU_BIN"
        pad_retry $PAD_SSH "chmod +x $PAD_DIR/$QEMU_BIN"
    fi

    # Temperature avant + cooldown force si trop chaud (regle GOAL : ne pas
    # demarrer une charge lourde au-dessus de 80C).
    local temp_before
    temp_before=$(pad_capture $PAD_SSH "cat /sys/class/thermal/thermal_zone0/temp")
    echo "[grok] temperature avant: $((temp_before / 1000))C"
    if [ "$temp_before" -gt 80000 ]; then
        echo "[grok] trop chaud, attente de refroidissement..."
        local i
        for i in $(seq 1 15); do
            sleep 60
            temp_before=$(pad_capture $PAD_SSH "cat /sys/class/thermal/thermal_zone0/temp")
            echo "[grok]   refroidissement ($i/15): $((temp_before / 1000))C"
            [ "$temp_before" -le 80000 ] && break
        done
        [ "$temp_before" -gt 80000 ] && { echo "ERROR: pad toujours >80C apres attente, on ne demarre pas." >&2; exit 1; }
    fi

    # Nettoyage des qemu RESIDUELS A NOUS (orphelins d'un run precedent tue) avant
    # de (re)lancer. On cible par comm EXACT 'qemu-aarch64' (pgrep -x) : c'est le
    # nom de NOTRE binaire deploye, et il exclut le qemu de la gateway (comm
    # 'qemu-aarch64-static', autre nom). On EVITE pgrep -f sur le chemin complet :
    # le chemin apparait dans l'argv du shell distant qui execute le pgrep lui-meme,
    # donc pgrep -f s'auto-matcherait (faux positif), et le pkill -f qui suit
    # tuerait ce shell + declencherait le throttle sshd (rafales rejetees). GOAL
    # absolu : jamais tuer le process d'autrui. Ils mangent la RAM du pad (1 Go).
    if [ -z "$BASELINE_QEMU" ]; then
        local residual
        residual=$(pad_capture $PAD_SSH "pgrep -x $QEMU_BIN || true")
        if [ -n "$residual" ]; then
            echo "[grok] qemu residuels A NOUS (orphelins) : $(echo "$residual" | tr '\n' ' ') -> nettoyage cible"
            pad_retry $PAD_SSH "pkill -x $QEMU_BIN || true"
            sleep 3
        fi
    fi

    # Un seul qemu a la fois : refus si un AUTRE qemu tourne encore (gateway) apres
    # notre menage (on ne le tue jamais, on reessaiera plus tard).
    if [ "$(running_qemu_count)" -gt 0 ]; then
        echo "ERROR: un autre qemu tourne deja sur le pad (gateway ?). On n'y touche pas, reessayer plus tard." >&2
        pad_capture $PAD_SSH "ps -eo pid,comm,args | grep '^[ ]*[0-9]* qemu-aarch64' | grep -v grep" >&2 || true
        exit 1
    fi

    # Fichier de config du moniteur (evite tout enfer de quoting sur ssh : les
    # valeurs vivent ici comme des affectations shell propres).
    local grok_timeout=$((duration + 120))
    local tmp_env="/tmp/grok-run-$stamp.env"
    cat > "$tmp_env" <<EOF
QEMU_ON_PAD="$qemu_on_pad"
GROK_PAD="/opt/grok/grok-aarch64"
SEED="$seed"
DURATION=$duration
INTERVAL=$interval
ABORT_TEMP=$ABORT_TEMP
SESSION="grokv1"
MON_LOG="$PAD_DIR/$mon_log"
CONTENT_LOG="$PAD_DIR/$content_log"
GROK_TIMEOUT=$grok_timeout
EOF
    pad_retry $PAD_SCP "$tmp_env" "$PAD_USER@$PAD_HOST:$PAD_DIR/$env_file"
    pad_retry $PAD_SCP "$MONITOR_SRC" "$PAD_USER@$PAD_HOST:$PAD_DIR/grok-pad-monitor.sh"
    pad_retry $PAD_SSH "chmod +x $PAD_DIR/grok-pad-monitor.sh"
    rm -f "$tmp_env"

    # Lancement DETACHE : setsid + nohup, stdio coupe. Le moniteur pad-side tourne
    # alors independamment de cette session ssh.
    echo "[grok] lancement pad-side detache (duree=${duration}s intervalle=${interval}s abort=$((ABORT_TEMP/1000))C)..."
    pad_retry $PAD_SSH "cd $PAD_DIR && setsid nohup bash grok-pad-monitor.sh $env_file >/dev/null 2>&1 < /dev/null & echo LAUNCHED"

    # Confirmation du demarrage via le LOG PAD du moniteur (une connexion ssh
    # espacee, robuste au throttle sshd qui suit la rafale de deploiement, contrairement
    # a un pgrep serre). On cherche la ligne "pid=" (grok lance) ou un echec explicite.
    echo "[grok] confirmation du demarrage (log pad)..."
    sleep 12
    local started="" our_pid="" i probe
    for i in $(seq 1 12); do
        probe=$(pad_capture $PAD_SSH "cat $PAD_DIR/$mon_log 2>/dev/null" || true)
        if echo "$probe" | grep -q 'grok agent lance, pid='; then started=yes; break; fi
        if echo "$probe" | grep -qE 'RESULT=NOSTART|pas demarre'; then
            echo "ERROR: grok n'a pas demarre. Log pad :" >&2; echo "$probe" >&2; exit 1
        fi
        sleep 8
    done
    our_pid=$(echo "$probe" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
    if [ -z "$started" ]; then
        echo "WARN: demarrage non confirme via le log apres ~100s ; verifier avec 'poll'." >&2
        our_pid="?"
    fi

    # Etat du run pour poll.
    cat > "$STATE_FILE" <<EOF
STAMP=$stamp
TAG=$tag
DURATION=$duration
PAD_MON_LOG=$PAD_DIR/$mon_log
PAD_CONTENT_LOG=$PAD_DIR/$content_log
LOCAL_MON_LOG=$LOG_DIR/$mon_log
LOCAL_CONTENT_LOG=$LOG_DIR/$content_log
SHA256=$( [ -n "$BASELINE_QEMU" ] && echo baseline || shasum -a 256 "$BUILD_OUT/$QEMU_BIN" | cut -d' ' -f1)
EOF
    echo "[grok] LANCE. pid qemu=$our_pid stamp=$stamp"
    echo "[grok] log pad : $PAD_DIR/$mon_log"
    echo "[grok] sonder avec : test/run-grok-pad.sh poll"
}

cmd_poll() {
    local stamp="${1:-}"
    local pad_mon pad_content local_mon local_content
    if [ -n "$stamp" ]; then
        pad_mon=$(pad_capture $PAD_SSH "ls $PAD_DIR/v1-grok-*-monitor-$stamp.log" | head -1)
        pad_content="${pad_mon/monitor/content}"
        local_mon="$LOG_DIR/$(basename "$pad_mon")"
        local_content="$LOG_DIR/$(basename "$pad_content")"
    else
        [ -f "$STATE_FILE" ] || { echo "ERROR: aucun run enregistre ($STATE_FILE absent). Lancer 'launch' d'abord." >&2; exit 1; }
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        pad_mon="$PAD_MON_LOG"; pad_content="$PAD_CONTENT_LOG"
        local_mon="$LOCAL_MON_LOG"; local_content="$LOCAL_CONTENT_LOG"
    fi

    pad_retry $PAD_SCP "$PAD_USER@$PAD_HOST:$pad_mon" "$local_mon"
    # Le contenu reel (streaming-json) et son .err : preuve capturee du run.
    pad_retry $PAD_SCP "$PAD_USER@$PAD_HOST:$pad_content" "$local_content" 2>/dev/null || true
    pad_retry $PAD_SCP "$PAD_USER@$PAD_HOST:${pad_content%.log}.err" "${local_content%.log}.err" 2>/dev/null || true

    echo "[grok] --- tail $local_mon ---"
    tail -8 "$local_mon"
    echo "[grok] ------------------------"
    local result_line
    result_line=$(grep '^RESULT=' "$local_mon" | tail -1 || true)
    if [ -z "$result_line" ]; then
        echo "[grok] run EN COURS (pas encore de ligne RESULT=)."
        return 2
    fi
    echo "[grok] $result_line"
    case "$result_line" in
        *RESULT=SURVIVED*) return 0 ;;
        *) return 1 ;;
    esac
}

case "${1:-}" in
    launch)  shift; cmd_launch "$@" ;;
    poll)    shift; cmd_poll "$@" ;;
    status)  cmd_status ;;
    *) echo "usage: $0 {launch [dur] [int] [seed] | poll [stamp] | status}" >&2; exit 2 ;;
esac
