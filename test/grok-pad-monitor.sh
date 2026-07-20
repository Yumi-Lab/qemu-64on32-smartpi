#!/bin/bash
# V1, moniteur PAD-SIDE AUTONOME (lance en detache par run-grok-pad.sh via
# setsid+nohup, cf. sa sous-commande "launch"). Tourne ENTIEREMENT sur le pad :
# meme si la liaison ssh du Mac tombe, le run continue et se protege tout seul.
#
# POURQUOI CETTE VERSION (v2, mode headless) : la TUI NATIVE de grok (l'ecran
# interactif) NE FONCTIONNE PAS sous l'emulation 64-on-32. Ce n'est pas notre
# constat : le portage officiel du pad l'ecrit noir sur blanc en tete de son
# clone Python /usr/local/bin/grok-tui : "the native TUI crashes under 64-on-32
# emulation; this one drives the reliable headless streaming mode". La v1 de ce
# moniteur pilotait justement cette TUI native (tmux + send-keys + capture-pane) :
# grok restait un process VIVANT mais N'AFFICHAIT RIEN (le pane ne montrait que
# la banniere systemd-run et les codes d'echappement des fleches non consommees).
# Un PID vivant sur un binaire bloque n'est PAS une preuve que la TUI grok tourne
# (theatre de preuve, exactement l'ecueil deja corrige en T1). Le controle l'a
# signale a juste titre.
#
# Ce que fait la v2 : elle exerce grok dans son SEUL mode qui rend sous
# emulation, le mode HEADLESS STREAMING (--output-format streaming-json -p),
# celui qu'utilise grok-tui pour chaque tour. Ce mode :
#   - boote le runtime lourdement JITe (le meme qui dechire la heap en baseline),
#   - produit une VRAIE sortie capturable (evenements JSON, texte du modele, ou
#     une erreur structuree), ecrite telle quelle dans CONTENT_LOG,
#   - se termine par un code de sortie exploitable (crash qemu vs sortie propre).
# Un preflight `grok --version` (banniere reelle, sans reseau) prouve d'abord que
# le fork execute bien le binaire grok officiel jusqu'a une sortie reelle.
#
# Regles GOAL respectees, toutes cote pad : 2 coeurs (taskset -c 0,1),
# MemoryMax=600M (systemd-run --user --scope, protection OOM SANS root), timeout
# (garde-fou dur), temperature min/max tracee, teardown limite a NOTRE pid
# (jamais le process d'autrui). Ne touche JAMAIS /opt/grok ni la config systeme,
# n'utilise PAS le wrapper /usr/local/bin/grok, pas de sudo.
#
# Config : lue depuis le fichier env passe en $1 (genere par run-grok-pad.sh).
# Sortie machine (derniere ligne du MON_LOG) :
#   RESULT=<SURVIVED|CRASHED|STALLED|COMPLETED|TEMP_ABORT|NOSTART> elapsed=<s>
#          exit_rc=<n> preflight_ok=<yes|no> agent_content=<yes|no>
#          agent_first_content_t=<s> peak_rss_mb=<n> peak_temp_c=<n>
#          min_temp_c=<n> ticks=<n>
#   SURVIVED  = le tour AGENT a produit du contenu reel ET a tourne >= DURATION
#               sans que qemu n'abandonne (objectif V1).
#   CRASHED   = qemu a AVORTE (signal, ex. SIGABRT d'une assertion TCG) = bug fork.
#   STALLED   = le tour AGENT n'a produit AUCUNE sortie pendant toute la fenetre
#               (bloque) ; on l'a coupe. Un PID vivant sans sortie n'est PAS une
#               survie reelle (c'est l'ecueil "theatre de preuve" que le controle
#               a signale sur la v1 de ce harnais). NON succes.
#   COMPLETED = grok a rendu une sortie reelle et a quitte proprement AVANT
#               DURATION (ex. erreur API 402) : pas de crash, mais pas 30 min.
#   TEMP_ABORT= coupe par la protection thermique du H3.
#   NOSTART   = qemu grok n'a jamais demarre.
# NB : preflight_ok distingue la banniere --version (contenu reel, sans reseau)
# de la sortie du TOUR AGENT (agent_content). Seule cette derniere fonde SURVIVED.
set -u

ENV_FILE="${1:?usage: grok-pad-monitor.sh <env-file>}"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${QEMU_ON_PAD:?}" "${GROK_PAD:?}" "${SEED:?}" "${DURATION:?}" "${INTERVAL:?}"
: "${ABORT_TEMP:?}" "${SESSION:?}" "${MON_LOG:?}" "${CONTENT_LOG:?}" "${GROK_TIMEOUT:?}"

ERR_LOG="${CONTENT_LOG%.log}.err"

log()  { echo "[grokpad] $*" >>"$MON_LOG"; }
temp() { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null; }
peak_rss=0; peak_temp=0; min_temp=999000; ticks=0; exit_rc=""
preflight_ok=no; preflight_bytes=0; agent_first_content_t=-1
emit_result() {  # $1=result $2=elapsed
    local rc_disp="${exit_rc:-NA}"; [ -z "$exit_rc" ] && rc_disp=NA
    local agent=no; [ "$agent_first_content_t" -ge 0 ] && agent=yes
    echo "RESULT=$1 elapsed=$2 exit_rc=$rc_disp preflight_ok=$preflight_ok agent_content=$agent agent_first_content_t=${agent_first_content_t}s peak_rss_mb=$(( peak_rss / 1024 )) peak_temp_c=$(( peak_temp / 1000 )) min_temp_c=$(( min_temp / 1000 )) ticks=$ticks" >>"$MON_LOG"
}

# Sommeil FIN : dort $1s en tranches de 8s en surveillant la temperature. Met a
# jour peak/min et retourne 1 des qu'on atteint ABORT_TEMP. Garde-fou anti-gel
# ENTRE deux ticks : l'echantillon a l'intervalle plein laisse une marge trop
# courte avant le gel (~100C) si la temp grimpe entre deux mesures.
safe_sleep() {
    local left="$1" chunk t
    while [ "$left" -gt 0 ]; do
        chunk=8; [ "$left" -lt 8 ] && chunk="$left"
        sleep "$chunk"; left=$(( left - chunk ))
        t=$(temp)
        if [ -n "${t:-}" ]; then
            [ "$t" -gt "$peak_temp" ] && peak_temp=$t
            [ "$t" -lt "$min_temp" ] && min_temp=$t
            [ "$t" -ge "$ABORT_TEMP" ] && return 1
        fi
    done
    return 0
}

# Octets sur le stdout de grok (CONTENT_LOG) : c'est LA sortie reelle de grok
# (banniere --version au preflight, evenements streaming-json du tour agent). La
# detection de "contenu du tour agent" se fait UNIQUEMENT sur ce flux : le stderr
# (ERR_LOG) porte des lignes qui NE viennent PAS de grok (banniere systemd-run
# "Running as unit:", message d'assertion qemu) et ne doit donc jamais compter
# comme du contenu agent (sinon faux positif -> theatre de preuve).
stdout_bytes() { wc -c <"$CONTENT_LOG" 2>/dev/null || echo 0; }
# Total des deux flux : purement informatif pour le tick.
content_bytes() {
    local a b
    a=$(wc -c <"$CONTENT_LOG" 2>/dev/null || echo 0)
    b=$(wc -c <"$ERR_LOG" 2>/dev/null || echo 0)
    echo $(( a + b ))
}

: >"$CONTENT_LOG"; : >"$ERR_LOG"
log "=== moniteur pad v2 (headless) demarre dur=${DURATION}s int=${INTERVAL}s abort=$(( ABORT_TEMP / 1000 ))C timeout=${GROK_TIMEOUT}s ==="
log "qemu=$QEMU_ON_PAD grok=$GROK_PAD mode=--output-format streaming-json -p"

# --- Preflight : preuve de contenu reel, sans reseau ----------------------------
# grok --version sous le fork : boote le runtime, imprime la banniere de version
# (contenu REEL), quitte. Independant du reseau et de l'etat du compte. Prouve que
# le fork execute le binaire grok officiel jusqu'a une sortie reelle.
log "preflight: grok --version sous le fork (contenu reel, sans reseau)"
{ echo "===== preflight: grok --version (fork) ====="; } >>"$CONTENT_LOG"
ver=$(taskset -c 0,1 timeout 200 "$QEMU_ON_PAD" "$GROK_PAD" --version 2>>"$ERR_LOG")
ver_rc=$?
echo "$ver" >>"$CONTENT_LOG"
log "preflight GROK_VERSION='$ver' rc=$ver_rc"
[ "$(stdout_bytes)" -gt 40 ] && preflight_ok=yes

# --- Tour reel : grok agent headless sous le fork -------------------------------
# systemd-run --user --scope MemoryMax=600M (OOM sans root) + taskset -c 0,1
# (2 coeurs, un run 4 coeurs a deja gele ce H3) + timeout (garde-fou dur).
# La sortie streaming-json (contenu reel) va dans CONTENT_LOG, l'erreur dans
# ERR_LOG. GROK_EXIT_RC=<code> est appose au MON_LOG a la fin (>=128 => signal
# => qemu a avorte = crash du fork ; 0/1 => grok a quitte proprement).
log "lancement du tour agent headless (streaming-json)..."
{ echo; echo "===== tour agent headless : grok -p (fork) ====="; } >>"$CONTENT_LOG"
# Repere l'octet STDOUT a partir duquel toute nouvelle sortie provient du TOUR
# AGENT (et non du preflight --version / des en-tetes deja ecrits ci-dessus).
preflight_bytes=$(stdout_bytes)
(
  systemd-run --user --scope -p MemoryMax=600M -- \
      taskset -c 0,1 timeout "$GROK_TIMEOUT" \
      "$QEMU_ON_PAD" "$GROK_PAD" --always-approve --output-format streaming-json -p "$SEED" \
      >>"$CONTENT_LOG" 2>>"$ERR_LOG"
  echo "GROK_EXIT_RC=$?" >>"$MON_LOG"
) &
LAUNCHER=$!

# Capturer NOTRE pid qemu (comm exact 'qemu-aarch64'). run-grok-pad.sh a deja
# garanti Mac-side qu'aucun autre qemu ne tournait, donc le premier match est le
# notre. Ensuite on ne surveille QUE /proc/PID.
OUR_PID=""
for _ in $(seq 1 40); do
    sleep 3
    OUR_PID=$(pgrep -x qemu-aarch64 | head -1)
    [ -n "$OUR_PID" ] && break
done
if [ -z "$OUR_PID" ]; then
    log "ERROR: qemu grok n'a pas demarre (tour agent)."
    wait "$LAUNCHER" 2>/dev/null
    exit_rc=$(grep '^GROK_EXIT_RC=' "$MON_LOG" | tail -1 | cut -d= -f2)
    emit_result NOSTART 0
    exit 1
fi
log "grok agent lance, pid=$OUR_PID"

START=$(date +%s); result=SURVIVED
while :; do
    elapsed=$(( $(date +%s) - START ))
    if [ "$elapsed" -ge "$DURATION" ]; then
        # Fin de fenetre : SURVIVED seulement si le TOUR AGENT a reellement
        # produit du contenu ; sinon STALLED (process vivant mais muet != survie).
        if [ "$agent_first_content_t" -ge 0 ]; then result=SURVIVED; else result=STALLED; fi
        break
    fi
    if [ ! -d "/proc/$OUR_PID" ]; then
        # Le process qemu a disparu : lire son code de sortie pour trancher.
        wait "$LAUNCHER" 2>/dev/null
        exit_rc=$(grep '^GROK_EXIT_RC=' "$MON_LOG" | tail -1 | cut -d= -f2)
        if [ -n "$exit_rc" ] && [ "$exit_rc" -ge 128 ] && [ "$exit_rc" -ne 143 ]; then
            result=CRASHED
            log "t=${elapsed}s : qemu a AVORTE (rc=$exit_rc, signal $(( exit_rc - 128 ))) = crash du fork"
        elif [ "$agent_first_content_t" -ge 0 ]; then
            result=COMPLETED
            log "t=${elapsed}s : grok a rendu du contenu et quitte (rc=${exit_rc:-?}) avant DURATION"
        else
            result=STALLED
            log "t=${elapsed}s : grok a quitte sans aucune sortie du tour agent (rc=${exit_rc:-?})"
        fi
        break
    fi
    RSS=$(awk '/VmRSS/{print $2}' "/proc/$OUR_PID/status" 2>/dev/null)
    T=$(temp)
    [ -n "${RSS:-}" ] && [ "$RSS" -gt "$peak_rss" ] && peak_rss=$RSS
    if [ -n "${T:-}" ]; then
        [ "$T" -gt "$peak_temp" ] && peak_temp=$T
        [ "$T" -lt "$min_temp" ] && min_temp=$T
    fi
    if [ "$agent_first_content_t" -lt 0 ] && [ "$(stdout_bytes)" -gt "$(( preflight_bytes + 8 ))" ]; then
        agent_first_content_t=$elapsed
        log "t=${elapsed}s : PREMIER CONTENU du TOUR AGENT capture (stdout=$(stdout_bytes) octets)"
    fi
    warn=""
    [ -n "${T:-}" ] && [ "$T" -ge 90000 ] && warn=" WARN>=90C"
    log "t=${elapsed}s rss=$(( ${RSS:-0} / 1024 ))MB temp=$(( ${T:-0} / 1000 ))C out=$(stdout_bytes) tot=$(content_bytes)${warn}"
    if [ -n "${T:-}" ] && [ "$T" -ge "$ABORT_TEMP" ]; then
        result=TEMP_ABORT; log "t=${elapsed}s : ABORT temp $(( T / 1000 ))C (protection gel)"; break
    fi
    ticks=$(( ticks + 1 ))
    if ! safe_sleep "$INTERVAL"; then
        result=TEMP_ABORT
        log "t=$(( $(date +%s) - START ))s : ABORT temp $(( peak_temp / 1000 ))C entre deux ticks (protection gel)"
        break
    fi
done

FINAL=$(( $(date +%s) - START ))
TA=$(temp); log "Temperature apres: $(( ${TA:-0} / 1000 ))C"

# Teardown : NOTRE pid uniquement (jamais celui d'autrui). Si le tour tourne
# encore (SURVIVED/TEMP_ABORT), on le coupe proprement.
if [ -d "/proc/$OUR_PID" ]; then
    kill "$OUR_PID" 2>/dev/null; sleep 2; kill -9 "$OUR_PID" 2>/dev/null || true
fi
wait "$LAUNCHER" 2>/dev/null
[ -z "$exit_rc" ] && exit_rc=$(grep '^GROK_EXIT_RC=' "$MON_LOG" | tail -1 | cut -d= -f2)

[ "$min_temp" -eq 999000 ] && min_temp=$peak_temp
log "=== bilan result=$result survie=${FINAL}s exit_rc=${exit_rc:-NA} preflight_ok=$preflight_ok agent_content=$([ "$agent_first_content_t" -ge 0 ] && echo yes || echo no) agent_first_content_t=${agent_first_content_t}s ticks=$ticks pic_rss=$(( peak_rss / 1024 ))MB temp_min=$(( min_temp / 1000 ))C temp_max=$(( peak_temp / 1000 ))C ==="
emit_result "$result" "$FINAL"
[ "$result" = "SURVIVED" ] && exit 0 || exit 1
