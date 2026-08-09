#!/usr/bin/env bash
# Tests du contrat de sortie de test/pad-lib.sh. Tourne SANS pad (le ssh est bouchonne),
# donc rejouable a tout moment, y compris quand la carte est eteinte.
#
# Verrouille les deux defauts constates le 2026-08-01 :
#   1. une fonction capturee par $(...) qui narre sur STDOUT pollue la valeur mesuree ;
#   2. `fail` appele depuis $(...) ne tuait que le sous-shell, le script continuait avec
#      le message d'erreur en guise de valeur.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()   { echo "ok:   $*"; pass=$((pass + 1)); }
nope() { echo "FAIL: $*"; failed=$((failed + 1)); }

# Harnais bouchon : un faux pad.env + un faux ssh, pour ne dependre ni du reseau ni
# des identifiants reels. La lib source pad.env par chemin relatif a elle-meme, on la
# recopie donc dans le bac a sable avec son voisin.
setup_sandbox() {
    cp "$REPO_ROOT/test/pad-lib.sh" "$TMP/pad-lib.sh"
    cat > "$TMP/pad.env" <<'ENV'
PAD_HOST=pad.invalid
PAD_USER=nobody
PAD_PASS=stub
PAD_DIR=/tmp/stub
PAD_SSH="bash $TMP_STUB_SSH"
ENV
    sed -i.bak "s#\$TMP_STUB_SSH#$TMP/stub-ssh.sh#" "$TMP/pad.env" && rm -f "$TMP/pad.env.bak"
}

# $1 = suite de temperatures (millidegres) rendues tour a tour par le faux pad.
write_stub_ssh() {
    printf '%s\n' "$1" > "$TMP/temps.txt"
    cat > "$TMP/stub-ssh.sh" <<'STUB'
#!/usr/bin/env bash
# Faux `ssh` : rend la temperature suivante de la liste, ou echoue quand la liste est
# epuisee (pad injoignable). `sed` plutot que `mapfile`, absent du bash 3.2 de macOS.
D="$(dirname "$0")"
n=$(cat "$D/idx.txt" 2>/dev/null || echo 0)
t=$(sed -n "$((n + 1))p" "$D/temps.txt")
[ -n "$t" ] || exit 255
echo $((n + 1)) > "$D/idx.txt"
printf '%s' "$t"
STUB
    echo 0 > "$TMP/idx.txt"
}

# --- 1. wait_cool ne rend QUE la temperature, meme apres des paliers d'attente -------
# Le pad est au-dessus du seuil deux fois, puis redescend : les lignes d'attente ne
# doivent PAS se retrouver dans la valeur capturee.
setup_sandbox
write_stub_ssh "85000
84000
70000"
out=$(cd "$TMP" && cat > run.sh <<'RUN' && bash run.sh 2>/dev/null
LOG=/dev/null
PAD_COOL_TRIES=5
source ./pad-lib.sh
sleep() { :; }              # on ne dort pas pour de vrai dans un test
tb=$(wait_cool)
printf '%s' "$tb"
RUN
)
if [ "$out" = "70000" ]; then
    ok "wait_cool rend la seule temperature (70000) apres deux paliers d'attente"
else
    nope "wait_cool a rendu [$out] au lieu de 70000 (narration collee a la valeur)"
fi

# La valeur doit rester utilisable en arithmetique : c'est l'usage reel des appelants
# (`temp_before=$((tb / 1000))C`), et c'est exactement ce qui cassait avant.
if arith=$( (echo "$((out / 1000))") 2>&1 ); then
    ok "la valeur rendue est arithmetiquement utilisable ($arith C)"
else
    nope "la valeur rendue casse l'arithmetique des appelants : $arith"
fi

# --- 2. fail depuis $(...) tue bien le script appelant -------------------------------
# Pad injoignable : wait_cool appelle fail depuis une substitution de commande. Le
# script NE DOIT PAS atteindre la ligne suivante.
setup_sandbox
write_stub_ssh ""           # aucune temperature -> le faux ssh echoue
out=$(cd "$TMP" && cat > run2.sh <<'RUN' && bash run2.sh 2>/dev/null
LOG=/dev/null
source ./pad-lib.sh
sleep() { :; }
tb=$(wait_cool)
printf 'ATTEINT_APRES_FAIL'
RUN
)
rc=$?
if [ -z "$out" ]; then
    ok "fail depuis \$(...) arrete le script (rc=$rc, rien apres l'echec)"
else
    nope "le script a continue apres fail : sortie [$out]"
fi

# --- 3. say n'ecrit jamais sur stdout ------------------------------------------------
setup_sandbox
write_stub_ssh "70000"
out=$(cd "$TMP" && cat > run3.sh <<'RUN' && bash run3.sh 2>/dev/null
LOG=/dev/null
source ./pad-lib.sh
say "narration qui ne doit jamais polluer une valeur"
RUN
)
if [ -z "$out" ]; then
    ok "say n'ecrit rien sur stdout (narration sur stderr + log)"
else
    nope "say a ecrit sur stdout : [$out]"
fi

# --- 4. say alimente bien le fichier de log ------------------------------------------
setup_sandbox
write_stub_ssh "70000"
( cd "$TMP" && cat > run4.sh <<'RUN' && bash run4.sh >/dev/null 2>&1
LOG=./run4.log
source ./pad-lib.sh
say "ligne de journal"
RUN
)
if grep -q "ligne de journal" "$TMP/run4.log" 2>/dev/null; then
    ok "say alimente le fichier de log"
else
    nope "say n'a pas ecrit dans le fichier de log"
fi

# --- 5. pad_really_idle : les fonctions et scripts communs (pad-lib.sh) --------------
# $1 = liste espace-separee des noms de process (argv[0]) que le faux /proc doit exposer
# ("" = pad au repos). L'exclusion elargie doit rendre 0 sur un pad AU REPOS, pas seulement
# >0 sur un pad occupe (le test contraire du garde, cf. W3 : trois versions successives de
# ce garde ont ete fausses sans qu'un test ne l'attrape avant).
# pgrep_argv0 (W6) lit /proc/PID/cmdline, PAS le binaire `pgrep` (comm tronque a 15c) :
# le bouchon construit donc un faux /proc, injecte via PAD_LIB_PROC_ROOT (le SEUL usage
# prevu de cette variable, cf. son commentaire dans pad-lib.sh). $1 = liste espace-separee
# de "pid:argv0".
write_stub_procroot() {
    rm -rf "$TMP/fakeproc"
    mkdir -p "$TMP/fakeproc"
    local entry pid a0
    for entry in $1; do
        pid="${entry%%:*}"; a0="${entry#*:}"
        mkdir -p "$TMP/fakeproc/$pid"
        printf '%s\0' "$a0" > "$TMP/fakeproc/$pid/cmdline"
    done
    cat > "$TMP/stub-ssh.sh" <<STUB
#!/usr/bin/env bash
PAD_LIB_PROC_ROOT="$TMP/fakeproc" bash -c "\$1"
STUB
    chmod +x "$TMP/stub-ssh.sh"
}

setup_sandbox
write_stub_procroot ""   # aucun process dans le faux /proc -> pad au repos
out=$(cd "$TMP" && cat > run5.sh <<'RUN' && bash run5.sh 2>/dev/null
LOG=/dev/null
source ./pad-lib.sh
pad_really_idle && printf 'IDLE' || printf 'BUSY'
RUN
)
if [ "$out" = "IDLE" ]; then
    ok "pad_really_idle rend vrai (0) sur un pad AU REPOS, pas seulement faux sur un pad occupe"
else
    nope "pad_really_idle a rendu [$out] au lieu de IDLE sur un pad sans aucun process busy"
fi

# --- 6. pad_really_idle : detecte un process busy sous un nom AUTRE que QEMU_BIN --------
# C'est le defaut precis que W3 corrige : require_idle ne regardait que $QEMU_BIN, donc
# deux harnais qui lancent qemu sous des noms distincts (qemu-aarch64 vs qemu-ab-a) etaient
# aveugles l'un a l'autre.
setup_sandbox
write_stub_procroot "5678:/root/qemu-fork-test/qemu-ab-b"   # le bras B d'un AUTRE harnais tourne
out=$(cd "$TMP" && cat > run6.sh <<'RUN' && bash run6.sh 2>/dev/null
LOG=/dev/null
QEMU_BIN=qemu-ab-a
source ./pad-lib.sh
pad_really_idle && printf 'IDLE' || printf 'BUSY'
RUN
)
if [ "$out" = "BUSY" ]; then
    ok "pad_really_idle detecte qemu-ab-b busy alors que QEMU_BIN=qemu-ab-a (exclusion elargie)"
else
    nope "pad_really_idle a rendu [$out] au lieu de BUSY : un harnais sous un autre nom passe inapercu"
fi

# --- 6a. pad_really_idle : QEMU_BIN peut lister PLUSIEURS noms (gate A/B qui deploie et
# execute ses deux bras sous des noms distincts, ex. run-y5-gate.sh "qemu-y5-a qemu-y5-b").
# Defaut precis constate en revue le 2026-08-09 : QEMU_BIN="qemu-y5-a" seul laissait
# "qemu-y5-b" hors de l'exclusion mutuelle, deux instances du gate pouvaient tourner en
# meme temps sans etre detectees. pad_really_idle scinde QEMU_BIN sur les espaces (boucle
# `for p in $names`), une liste doit donc suffire sans dupliquer PAD_BUSY_NAMES_DEFAULT.
setup_sandbox
write_stub_procroot "4242:/root/qemu-fork-test/qemu-y5-b"   # seul le bras B tourne
out=$(cd "$TMP" && cat > run6a.sh <<'RUN' && bash run6a.sh 2>/dev/null
LOG=/dev/null
QEMU_BIN="qemu-y5-a qemu-y5-b"
source ./pad-lib.sh
pad_really_idle && printf 'IDLE' || printf 'BUSY'
RUN
)
if [ "$out" = "BUSY" ]; then
    ok "pad_really_idle detecte qemu-y5-b busy quand QEMU_BIN liste \"qemu-y5-a qemu-y5-b\""
else
    nope "pad_really_idle a rendu [$out] au lieu de BUSY : qemu-y5-b passe inapercu avec un QEMU_BIN a plusieurs noms"
fi

# --- 6b. pgrep_argv0 : trouve un nom de 19 caracteres, que `comm` (TASK_COMM_LEN=15)
# tronquerait et rendrait invisible a `pgrep -x` (W6, le defaut precis derriere ce lot :
# constate en preparant le gate, `qemu-aarch64-o3lto` passait inapercu de la garde
# "un seul qemu a la fois"). argv[0] via /proc/PID/cmdline n'est jamais tronque.
setup_sandbox
write_stub_procroot "9012:/root/qemu-fork-test/qemu-aarch64-o3lto"
out=$(cd "$TMP" && cat > run6b.sh <<'RUN' && bash run6b.sh 2>/dev/null
LOG=/dev/null
QEMU_BIN=qemu-aarch64-o3lto
source ./pad-lib.sh
pad_really_idle && printf 'IDLE' || printf 'BUSY'
RUN
)
if [ "$out" = "BUSY" ]; then
    ok "pgrep_argv0 detecte qemu-aarch64-o3lto (19c) que comm tronque a 15c aurait rendu invisible"
else
    nope "pgrep_argv0 a rendu [$out] au lieu de BUSY : qemu-aarch64-o3lto est passe inapercu (regression du defaut W6)"
fi

# --- 6c. pgrep_argv0 : PID sorti entre le glob et la lecture (race /proc reelle) --------
# Constate en conditions reelles (v41g-gate-20260804-160357.txt lignes 491/508) : le PID
# glob-e disparait avant la lecture de son cmdline, un lien symbolique casse le simule ici.
# `<"$p" 2>/dev/null` (ordre gauche-droite bash) laissait fuir "No such file or directory"
# sur stderr AVANT que 2>/dev/null ne s'applique ; le fix regroupe la redirection d'entree
# et la suppression d'erreur dans le meme bloc. stdout ET stderr doivent rester propres.
setup_sandbox
rm -rf "$TMP/fakeproc"
mkdir -p "$TMP/fakeproc"
ln -s /nonexistent-race-target "$TMP/fakeproc/9999/cmdline" 2>/dev/null || {
    mkdir -p "$TMP/fakeproc/9999"
    ln -s /nonexistent-race-target "$TMP/fakeproc/9999/cmdline"
}
cat > "$TMP/stub-ssh.sh" <<STUB
#!/usr/bin/env bash
PAD_LIB_PROC_ROOT="$TMP/fakeproc" bash -c "\$1"
STUB
chmod +x "$TMP/stub-ssh.sh"
err=$(cd "$TMP" && cat > run6c.sh <<'RUN' && bash run6c.sh 2>run6c.err
LOG=/dev/null
source ./pad-lib.sh
pgrep_argv0 qemu-aarch64 >/dev/null
RUN
cat run6c.err)
if [ -z "$err" ]; then
    ok "pgrep_argv0 ne fuit rien sur stderr quand un PID glob-e disparait avant lecture (race /proc)"
else
    nope "pgrep_argv0 a fui sur stderr lors d'une race /proc : [$err]"
fi

# --- 7. classify_qemu_rc : ECHEC DE BANC vs ECHEC DU PRODUIT (W2) --------------------
# rc=126/127 ne disent RIEN de l'emulateur teste (binaire non executable / introuvable) :
# c'est le defaut de preparation qui a coute 4 jours a la campagne V4-1H quand il etait
# confondu avec un vrai resultat de run. Verrouille le contrat pour toute l'arborescence
# (source unique, cf. son commentaire dans pad-lib.sh).
setup_sandbox
check_classify() {
    local rc="$1" want="$2" got
    got=$(cd "$TMP" && bash -c "source ./pad-lib.sh; classify_qemu_rc $rc" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        ok "classify_qemu_rc $rc -> $want"
    else
        nope "classify_qemu_rc $rc a rendu [$got] au lieu de [$want]"
    fi
}
check_classify 0 BOOTED
check_classify 1 BOOTED
check_classify 126 BENCH_FAIL
check_classify 127 BENCH_FAIL
check_classify 124 TIMEOUT
check_classify 143 TIMEOUT
check_classify 137 TIMEOUT
check_classify 134 CRASHED   # SIGABRT
check_classify 139 CRASHED   # SIGSEGV

echo
echo "test-pad-lib : $pass ok, $failed echec(s)"
[ "$failed" = 0 ]
