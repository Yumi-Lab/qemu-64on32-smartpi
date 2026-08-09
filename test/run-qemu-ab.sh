#!/bin/bash
# A/B WALL-CLOCK ENTRE DEUX BUILDS DE L'EMULATEUR, invite et charge FIXES.
#
# Raison d'etre : les harnais existants comparent deux OPTIONS avec un emulateur fixe
# (`run-v42-ab.sh`) ou deux INVITES avec un emulateur fixe (`run-claude-versions.sh`).
# Il manquait l'axe symetrique : MEME invite, MEME charge, DEUX emulateurs. C'est celui
# qu'exigent les re-validations de leviers fermes (-O3, -O3+LTO, nzcv-lazy...), dont
# certains ont ete clos sur des ecarts de 0,4 a 2,3 % — assez serres pour qu'un defaut de
# quelques pourcents en inverse le signe.
#
# METHODE (les trois protections qui manquaient aux campagnes de juillet) :
#   - comparaison de bras mesures LE MEME JOUR, jamais contre une constante d'un autre banc
#     (le pad a perdu son overclock au reflash : 1296 MHz max contre 1368 auparavant) ;
#   - run de CHAUFFE jete : le premier run paie la lecture du binaire invite (258 Mo) depuis
#     la carte SD et les caches internes ;
#   - alternance ABAB + medianes sur >= 3 runs VALIDES par bras, et un run non valide est
#     EXCLU, jamais remplace par une estimation.
# Garde de correctness : les deux bras doivent produire la MEME taille de sortie. Un bras
# plus rapide qui rend moins d'octets n'est pas plus rapide, il est casse.
#
# Usage :
#   test/run-qemu-ab.sh <qemuA> <qemuB> [paires] [mode]
#     qemuA/qemuB : noms de binaires dans build-out/ (ex: qemu-aarch64 qemu-aarch64-o3lto)
#     paires      : nombre de couples A/B (defaut 4)
#     mode        : help (defaut) | version
#
# Exemple (re-valider la fermeture de -O3+LTO) :
#   test/run-qemu-ab.sh qemu-aarch64 qemu-aarch64-o3lto 4 help
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="$REPO_ROOT/build-out"
LOGDIR="$REPO_ROOT/test/logs/qemu-ab"

QEMU_A="${1:?usage: run-qemu-ab.sh <qemuA> <qemuB> [paires] [mode]}"
QEMU_B="${2:?usage: run-qemu-ab.sh <qemuA> <qemuB> [paires] [mode]}"
PAIRS="${3:-4}"
MODE="${4:-help}"
SETTLE="${SETTLE:-45}"
RUN_TIMEOUT="${RUN_TIMEOUT:-900}"
GUEST="${GUEST:-claude-native}"

case "$MODE" in
    help)    GUEST_ARGS="--help" ;;
    version) GUEST_ARGS="--version" ;;
    *) echo "mode inconnu '$MODE' (attendu: help|version)" >&2; exit 2 ;;
esac

mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/qemu-ab-$STAMP.txt"
PAD_FAIL_PREFIX="A/B EMULATEURS"
QEMU_BIN="qemu-ab-a"   # pour require_idle : les deux bras tournent sous des noms distincts

# shellcheck disable=SC1091
source "$REPO_ROOT/test/pad-lib.sh"

# JIT invite ACTIF : c'est le regime produit, et le seul ou les leviers TCG se jugent.
# DOIT rester APRES le source : $PAD_DIR vient de pad-lib.sh, et sous `set -u` une
# affectation prematuree tue le script avant le premier run (constate le 2026-08-02 :
# 40 min de mur perdues faute d'avoir verifie que la mesure avait DEMARRE ; `bash -n`
# ne valide que la syntaxe, jamais l'execution).
COMMON_ENV="HOME=$PAD_DIR DISABLE_AUTOUPDATER=1 QEMU_TB_SIZE=256 BUN_JSC_useJIT=1 BUN_JSC_useConcurrentGC=0 BUN_JSC_numberOfGCMarkers=1"

median() {
    local n sorted
    sorted=$(printf '%s\n' "$@" | sort -n)
    n=$#
    if [ $((n % 2)) -eq 1 ]; then
        printf '%s' "$(printf '%s\n' "$sorted" | sed -n "$(((n + 1) / 2))p")"
    else
        local a b
        a=$(printf '%s\n' "$sorted" | sed -n "$((n / 2))p")
        b=$(printf '%s\n' "$sorted" | sed -n "$((n / 2 + 1))p")
        printf '%s' $(((a + b) / 2))
    fi
}

# Deploie un build local sous un nom distinct sur le pad, sha verifie DES DEUX COTES.
deploy_arm() {
    local src="$1" name="$2" lsha psha
    [ -f "$BUILD_OUT/$src" ] || fail "$BUILD_OUT/$src absent"
    lsha=$(shasum -a 256 "$BUILD_OUT/$src" | cut -c1-16)
    psha=$(pad_capture "sha256sum $PAD_DIR/$name 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha $name)"
    if [ "$lsha" != "$psha" ]; then
        say "  deploiement $src -> $name (local=$lsha pad=${psha:-absent})..."
        pad_put "$BUILD_OUT/$src" "$PAD_DIR/$name" || fail "deploiement de $src echoue"
        $PAD_SSH "chmod +x $PAD_DIR/$name"
        psha=$(pad_capture "sha256sum $PAD_DIR/$name | cut -c1-16")
        [ "$lsha" = "$psha" ] || fail "$name : sha divergent apres deploiement"
    fi
    # chmod INCONDITIONNEL : quand le sha correspond deja on saute le deploiement, et un
    # `chmod` enferme dans ce bloc laisse un binaire non executable. Constate le 2026-08-02 :
    # les 4 runs du bras B ont rendu rc=126 (Permission denied), ce qui ressemblait a un
    # echec du BUILD alors que c'etait un echec de BANC. Un fichier deploye doit toujours
    # sortir de cette fonction executable.
    $PAD_SSH "chmod +x $PAD_DIR/$name" >/dev/null 2>&1
    printf '%s' "$lsha"
}

# Un run. $1 = nom du binaire sur le pad. Imprime "elapsed:octets", ou rien si invalide.
# `pad_really_idle` (test/pad-lib.sh) porte l'exclusion ELARGIE : ce script fait tourner
# ses bras sous des noms distincts (qemu-ab-a/b), elle regarde donc toute la liste
# PAD_BUSY_NAMES_DEFAULT, pas seulement $QEMU_BIN. Voir son commentaire pour l'historique
# des trois versions fausses avant celle-ci.
one_run() {
    local qbin="$1" tb t0 t1 out rc bytes i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pad_really_idle && break
        say "    pad occupe (autre qemu ou transfert en cours), attente $i/10..."
        sleep 30
        [ "$i" = 10 ] && fail "le pad reste occupe par un autre processus : mesure abandonnee plutot que contaminee"
    done
    require_idle
    tb=$(wait_cool)
    t0=$(date +%s)
    out=$(pad_capture "cd $PAD_DIR && taskset -c 0,1 timeout $RUN_TIMEOUT \
          env $COMMON_ENV ./$qbin -L sysroot ./$GUEST $GUEST_ARGS 2>/dev/null | wc -c; echo RC=\${PIPESTATUS[0]}") \
        || { say "    [$qbin] pad injoignable pendant le run"; return 1; }
    t1=$(date +%s)
    rc=$(printf '%s' "$out" | sed -n 's/^RC=//p' | tail -1)
    bytes=$(printf '%s' "$out" | grep -vE '^RC=' | tr -dc '0-9')
    say "    [$qbin] rc=$rc elapsed=$((t1 - t0))s out_bytes=${bytes:-0} temp_before=$((tb / 1000))C"
    # ECHEC DE BANC vs ECHEC DU PRODUIT (classify_qemu_rc, test/pad-lib.sh, W2) : rc=126/127
    # ne disent RIEN de l'emulateur teste, ils disent que le banc est mal prepare. Les
    # confondre avec un echec produit est la faute qui a coute 4 jours a la campagne V4-1H.
    if [ "$(classify_qemu_rc "$rc")" = "BENCH_FAIL" ]; then
        fail "$qbin : rc=$rc -> ECHEC DE BANC (binaire non executable ou absent), PAS un echec du build teste. Rien a conclure sur l'emulateur."
    fi
    [ "$rc" = "0" ] || { say "    [$qbin] rc!=0 -> EXCLU de la mediane"; return 1; }
    [ -n "$bytes" ] && [ "$bytes" -gt 0 ] || { say "    [$qbin] sortie vide -> EXCLU"; return 1; }
    printf '%s:%s' "$((t1 - t0))" "$bytes"
}

pad_alive || fail "pad injoignable (allume-le ; cette mesure exige une execution reelle)"

say "=== A/B EMULATEURS, invite=$GUEST charge=$GUEST_ARGS, $PAIRS paires (ABAB), $STAMP ==="
say "A = $QEMU_A   B = $QEMU_B"
say "env commun : $COMMON_ENV"

SHA_A=$(deploy_arm "$QEMU_A" "qemu-ab-a")
SHA_B=$(deploy_arm "$QEMU_B" "qemu-ab-b")
say "  A=$QEMU_A sha=$SHA_A   B=$QEMU_B sha=$SHA_B (identiques des deux cotes)"
[ "$SHA_A" != "$SHA_B" ] || fail "les deux bras ont le MEME sha : il n'y a rien a comparer"

# Verification de l'invite : une mesure sur un invite perime ne prouve rien.
GSHA=$(pad_capture "sha256sum $PAD_DIR/$GUEST 2>/dev/null | cut -c1-16") || fail "pad injoignable (sha invite)"
[ -n "$GSHA" ] || fail "$GUEST absent du pad"
say "  invite $GUEST sha=$GSHA"
say ""

say "--- run de chauffe (JETE) ---"
one_run qemu-ab-a >/dev/null || say "    (chauffe non concluante, elle n'entre dans aucune mediane)"
sleep "$SETTLE"
say ""

A_T=(); B_T=(); A_BYTES=""; B_BYTES=""
for i in $(seq 1 "$PAIRS"); do
    say "--- paire $i/$PAIRS ---"
    if r=$(one_run qemu-ab-a); then A_T+=("${r%%:*}"); A_BYTES="${r##*:}"; fi
    sleep "$SETTLE"
    if r=$(one_run qemu-ab-b); then B_T+=("${r%%:*}"); B_BYTES="${r##*:}"; fi
    sleep "$SETTLE"
done

say ""
say "=== RESULTATS ==="
say "A ($QEMU_A, n=${#A_T[@]}) : ${A_T[*]:-aucun}"
say "B ($QEMU_B, n=${#B_T[@]}) : ${B_T[*]:-aucun}"
say "octets rendus : A=${A_BYTES:-?} B=${B_BYTES:-?}"

[ "${A_BYTES:-0}" = "${B_BYTES:-1}" ] \
    || say "ATTENTION : les deux bras ne rendent PAS la meme taille de sortie — la comparaison de vitesse n'a pas de sens tant que ce n'est pas explique."

if [ "${#A_T[@]}" -lt 3 ] || [ "${#B_T[@]}" -lt 3 ]; then
    say "VERDICT : INCONCLUSIF, moins de 3 runs valides par bras."
    say "Log : $LOG"
    exit 2
fi

MA=$(median "${A_T[@]}"); MB=$(median "${B_T[@]}")
say "mediane A = ${MA}s   mediane B = ${MB}s"
GAIN=$(awk -v a="$MA" -v b="$MB" 'BEGIN{printf "%+.2f", (a-b)/a*100}')
say "B vs A : $GAIN %  (positif = B est PLUS RAPIDE que A)"
say ""
say "RAPPEL DE PORTEE : ce chiffre vaut pour l'invite $GSHA, la charge '$GUEST_ARGS', le pad"
say "dans son etat du jour. Il ne dit RIEN d'une autre charge ni d'un autre banc."
say "Log : $LOG"
