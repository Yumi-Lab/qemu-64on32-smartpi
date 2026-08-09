# Fonctions communes des harnais pad (connexion, transfert, garde thermique, exclusion).
# A sourcer APRES avoir defini LOG, et QEMU_BIN si require_idle est utilise :
#
#     LOG="$LOGDIR/mon-run.txt"
#     PAD_FAIL_PREFIX="GATE V4-1G"
#     source "$REPO_ROOT/test/pad-lib.sh"
#
# DEUX REGLES DE SORTIE, nees de defauts reels qui ont fausse des gates. Les respecter
# dans toute fonction ajoutee ici.
#
# 1. STDOUT N'EST QUE LA VALEUR DE RETOUR. Une fonction capturee par $(...) ne doit
#    ecrire sur stdout QUE la valeur demandee ; toute narration part sur stderr (`say`).
#    Defaut constate le 2026-08-01 dans run-v41g-gate.sh et diag-claude-sigtrap.sh
#    (sortie emise en double -> `grep -oE` rendait DEUX nombres -> "integer expression
#    expected" -> l'item 1 du gate ne pouvait passer dans AUCUN cas). Le meme piege
#    restait tendu dans `wait_cool` : `tb=$(wait_cool)` recuperait les lignes d'attente
#    de refroidissement COLLEES a la temperature des que le pad depassait le seuil.
#
# 2. `fail` DOIT TUER LE SCRIPT, MEME APPELE DEPUIS $(...). Un `exit 1` dans une
#    substitution de commande ne quitte que le sous-shell : le script continuait avec
#    le message d'erreur EN GUISE DE VALEUR. D'ou le signal au PID principal ci-dessous.

[ -n "${PAD_LIB_SOURCED:-}" ] && return 0
PAD_LIB_SOURCED=1

# PID du script principal, capture au source : $$ garde cette valeur dans les
# sous-shells, ce qui permet a `fail` de les traverser.
PAD_LIB_MAIN_PID=$$

PAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config pad centralisee (IP, identifiants, chemins) : jamais en dur dans un script.
# shellcheck disable=SC1091
source "$PAD_LIB_DIR/pad.env"

PAD_MAX_TEMP="${PAD_MAX_TEMP:-80000}"   # au-dela, on attend au lieu de charger la carte
PAD_COOL_TRIES="${PAD_COOL_TRIES:-10}"  # paliers d'une minute avant d'abandonner
PAD_SSH_TRIES="${PAD_SSH_TRIES:-5}"     # le sshd du pad throttle les rafales

say() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

# Le TERM que `fail` s'envoie sortirait sinon en 143 avec un "Terminated" imprime par
# le shell appelant : le trap le rend en echec propre et silencieux.
trap 'exit 1' TERM

fail() {
    say "${PAD_FAIL_PREFIX:-HARNAIS PAD}: ECHEC, $*"
    kill -TERM "$PAD_LIB_MAIN_PID" 2>/dev/null
    exit 1
}

pad_capture() {
    local n=0 out
    until out=$($PAD_SSH "$@" 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -ge "$PAD_SSH_TRIES" ] && return 1
        sleep $((n * 3))
    done
    printf '%s' "$out"
}

# L'image DietPi du pad n'a ni scp ni sftp-server, et un `cat >` brut fait tomber le
# lien sur des dizaines de Mo : on passe par gzip (present sur l'image).
pad_put() { gzip -c "$1" | $PAD_SSH "gunzip -c > $2"; }

pad_alive() {
    $PAD_SSH true 2>/dev/null
}

temp_now() { pad_capture "cat /sys/class/thermal/thermal_zone0/temp"; }

# Attend que le pad soit sous PAD_MAX_TEMP avant d'imposer une charge.
# STDOUT = la temperature retenue, RIEN D'AUTRE (cf. regle 1 de l'entete).
wait_cool() {
    local t i
    for i in $(seq 1 "$PAD_COOL_TRIES"); do
        t=$(temp_now) || fail "pad injoignable (lecture temperature)"
        [ "$t" -le "$PAD_MAX_TEMP" ] && { printf '%s' "$t"; return 0; }
        say "  pad a $((t / 1000))C, attente du refroidissement ($i/$PAD_COOL_TRIES)..."
        sleep 60
    done
    fail "pad toujours au-dessus de $((PAD_MAX_TEMP / 1000))C apres $PAD_COOL_TRIES min"
}

# EXCLUSION ELARGIE. Deux harnais qui lancent qemu sous des NOMS differents (ex:
# qemu-aarch64 vs qemu-ab-a/qemu-ab-b) sont aveugles l'un a l'autre si on ne regarde que
# $QEMU_BIN : constate le 2026-08-02, un run a mis 408 s la ou les autres mettent ~57 s,
# deux mesures s'etaient chevauchees sans que ni l'une ni l'autre le detecte. On refuse
# donc de demarrer tant que le pad porte le MOINDRE processus de cette liste, quel que
# soit le harnais qui l'a lance, et tant qu'un transfert lourd est en cours (gzip/gunzip).
# NE PAS utiliser `pgrep -f` ici : il compare la LIGNE DE COMMANDE entiere, donc il compte
# le shell appelant des que celle-ci mentionne un chemin contenant le motif (`chmod +x
# .../qemu-ab-a` suffit). Deux variantes successives de cette forme ont rendu 1 puis 2 sur
# un pad VIDE avant d'etre corrigees. `pgrep -x` compare le NOM DE L'EXECUTABLE, jamais la
# ligne de commande : immunise par construction.
PAD_BUSY_NAMES_DEFAULT="qemu-aarch64 qemu-ab-a qemu-ab-b qemu-baseline gunzip gzip"

# ARGV[0] MATCH, PAS `comm`. Le noyau tronque `/proc/PID/comm` (et donc ce que compare
# `pgrep -x`) a TASK_COMM_LEN=15 caracteres : constate le 2026-08-04 en preparant le
# gate W6, `qemu-aarch64-o3lto` (19c) devient invisible a `pgrep -x qemu-aarch64-o3lto`
# (0 match silencieux) ET indiscernable par comm de `qemu-aarch64-o3` (15c, un AUTRE
# binaire du repo) -- la garde "un seul qemu a la fois" ne voyait donc PAS un run en
# cours. argv[0] (`/proc/PID/cmdline`, premier champ NUL-termine) n'est jamais tronque.
# Source UNIQUE (meme regle que classify_qemu_rc) : injectee via `declare -f` partout
# ou ce code doit tourner EN DISTANT (cf. run-claude-pad.sh), jamais redupliquee.
# STDOUT = un PID par ligne (peut etre vide), RIEN D'AUTRE. $1 = nom exact du binaire.
# PAD_LIB_PROC_ROOT (defaut /proc) n'existe que pour l'injection de test (aucun /proc
# sur le Mac hote qui fait tourner test-pad-lib.sh) : jamais surchargee en production,
# le harnais distant tourne sur Linux avec le defaut.
pgrep_argv0() {
    local want="$1" p pid a0 root="${PAD_LIB_PROC_ROOT:-/proc}"
    for p in "$root"/[0-9]*/cmdline; do
        pid=$(basename "$(dirname "$p")")
        a0=$( { tr '\0' '\n' <"$p"; } 2>/dev/null | head -1)
        [ "$(basename "${a0:-}" 2>/dev/null)" = "$want" ] && printf '%s\n' "$pid"
    done
    return 0
}

# STDOUT = rien (code de retour seulement, cf. regle 1 de l'entete). 0 = pad libre.
pad_really_idle() {
    local names busy
    names="${QEMU_BIN:-} ${PAD_BUSY_NAMES:-$PAD_BUSY_NAMES_DEFAULT}"
    # `pgrep -c` AFFICHE 0 et SORT EN ERREUR quand il ne trouve rien : un `|| echo 0`
    # ajoute alors un SECOND zero, la variable vaut "0\n0" et l'arithmetique meurt en
    # "syntax error". `pgrep_argv0 | wc -l` imprime toujours un nombre et reussit toujours.
    busy=$(pad_capture "$(declare -f pgrep_argv0); n=0; for p in $names; do c=\$(pgrep_argv0 \"\$p\" | wc -l); n=\$((n + c)); done; echo \$n") || return 1
    [ "${busy:-1}" -eq 0 ]
}

# On ne tue JAMAIS le process d'autrui : la gateway lance parfois grok emule.
require_idle() {
    pad_really_idle || fail "un processus busy (${QEMU_BIN:-} ${PAD_BUSY_NAMES:-$PAD_BUSY_NAMES_DEFAULT}) tourne deja sur le pad, ou le pad est injoignable"
    return 0
}

# ECHEC DE BANC vs ECHEC DU PRODUIT (W2). Un run qui n'a jamais reellement demarre
# n'autorise AUCUNE conclusion sur l'emulateur teste : rc=126 (non executable) et
# rc=127 (introuvable) sont des defauts de PREPARATION du banc (deploiement, chmod,
# chemin), jamais un comportement de qemu. Les confondre avec BOOTED/CRASHED est la
# faute precise qui a coute 4 jours a la campagne V4-1H (cf. PROGRESS.md, phase W).
# Source UNIQUE de cette classification : injectee telle quelle (via `declare -f`)
# dans les scripts distants lances par ssh (cf. run-claude-pad.sh), pour ne jamais
# diverger entre la copie locale et la copie distante.
# STDOUT = un mot parmi BOOTED|CRASHED|TIMEOUT|BENCH_FAIL, RIEN D'AUTRE. $1 = rc.
classify_qemu_rc() {
    local rc="$1"
    case "$rc" in
        126|127) printf 'BENCH_FAIL'; return ;;
        124|143|137) printf 'TIMEOUT'; return ;;   # timeout / timeout -k : garde-fou, pas un crash
    esac
    if [ "$rc" -ge 128 ] 2>/dev/null; then
        printf 'CRASHED'   # signal (SIGABRT/SIGSEGV/SIGILL/SIGBUS...) = bug fork
    else
        printf 'BOOTED'
    fi
}
