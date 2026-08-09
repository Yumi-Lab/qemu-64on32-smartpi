# Passation : le crash crypto/TLS du fork QEMU 64-on-32

Document pour une instance fraiche qui prend le sujet avec un contexte minimal.
Lis-le en entier avant d'agir. Ce qui est note ETABLI est prouve et source :
ne le re-derive pas, construis dessus.

## La mission, en une phrase

Le PRODUIT est l'emulateur : ce fork de QEMU 9.2.4 est le dernier user-mode
64-on-32 vivant (aarch64 sur armv7). Quatre bugs de correctness sont deja
corriges. Il en reste UN, decouvert le 2026-07-20 : sous le vrai binaire
Claude Code, une fois tout l'init termine et une connexion reseau etablie,
l'emulateur CRASHE sur le chemin crypto/TLS. Ta mission : le CARACTERISER
puis le CORRIGER, sans casser les quatre fixes existants.

## Regle d'or (non negociable)

"Structurellement impossible" ou "trop complexe" ne sont PAS des conclusions
recevables. Chaque hypothese se termine par une PREUVE (un repro, un dump, un
diff de comportement), jamais par un raisonnement seul. L'histoire du repo
donne raison a cette regle : le crash SIMD dup2_vec semblait obscur et s'est
revele un cas d'une seule moitie constante, corrige en 2 fichiers.

## RESOLU (2026-07-20) : c'est un bug du chemin STRACE, pas de l'execution

Apres 2 reruns : le SIGSEGV se reproduit 2/2 AVEC QEMU_STRACE=1 (rc=139, ~20 min,
au syscall `sendto` du ClientHello TLS les deux fois), et 0/1 SANS strace
(40 min, aucun crash). Cause racine dans les sources : `print_sendto`
(linux-user/strace.c:3279) -> `print_buf_len` (:1720) -> `print_buf` (:1691)
fait `lock_user(VERIFY_READ, addr, len, 1)` puis lit le buffer de 517 octets ;
la lecture faute (MAPERR, adresse variable = donnees, pas code). C'est un bug de
l'OUTIL de trace de qemu-user, borne a print_buf/lock_user, PAS un bug
d'execution. L'execution reelle du fork ne crashe pas sur le crypto/TLS.

CONSEQUENCE pour cette passation : ce "crash" ne bloque PAS l'usage reel. Deux
options pour l'instance fraiche : (1) le corriger quand meme (petit fix strace.c :
borner la lecture a la portion sûrement mappee, ou durcir l'acces) pour rendre le
traçage du fork utilisable , cible propre et reproductible ; (2) le deprioriser,
car le vrai obstacle au rendu d'un `-p` est la VITESSE du chemin crypto emule, pas
la correctness. Ne PAS repartir de l'idee (fausse) d'un bug d'execution crypto.

## Le crash initial (contexte, avant resolution)

- Signature : `qemu-aarch64: QEMU internal SIGSEGV {code=MAPERR, addr=0x4334000}`,
  RESULT=CRASHED exit_rc=139 (SIGSEGV). Vu sur build -O2, mono-coeur, ~20 min.
- "QEMU internal SIGSEGV" = la faute est dans le code HOTE genere par TCG ou
  dans un helper, PAS une faute guest normale relayee au guest. addr=0x4334000
  (~70 MB) est dans l'espace d'adressage guest.
- Contexte EXACT (trace strace conservee : test/logs/claude-native/
  v2-crash-tls-strace.err, 21 353 lignes) : le binaire fait tout l'init, puis
  reseau COMPLET , (1) DNS de api.anthropic.com via systemd-resolved
  (127.0.0.53), (2) sockets TCP + connect EINPROGRESS + TCP_NODELAY + epoll,
  (3) getrandom x3 (cles ephemeres ECDHE), (4) `sendto` d'un ClientHello TLS de
  517 octets (`\x16\x03\x01...`). Le SIGSEGV survient PENDANT ce sendto.
- Multi-thread au moment du crash (threads 2904, 4453, 2506 actifs). La crypto
  est BoringSSL (X25519/ECDHE = bignum, plus possibles instructions
  vectorielles/AES/SHA).
- STATUT DU CRASH : NON confirme deterministe. Le SIGSEGV (rc=139) n'est
  survenu QU'UNE FOIS, avec QEMU_STRACE=1. La repro SANS strace (meme -O2, meme
  env, meme reseau joignable) n'a PAS produit de SIGSEGV : elle a tourne 40 min
  puis a ete tuee par le garde-fou (rc=137 = SIGKILL de timeout -k, PAS un
  crash ; stderr sans aucun message SIGSEGV). Logs : v2-crash-repro-nostrace.log.
  => Hypotheses ouvertes, a trancher : (a) bug du CHEMIN STRACE de qemu-user
  (le formatage d'un argument de sendto/recvmsg deref un pointeur guest ?),
  (b) course multi-thread rare exposee par le timing du traceur, (c) one-off.
  PREMIER TEST a refaire : relancer AVEC strace 2-3 fois. Si le SIGSEGV
  reapparait -> lie a strace (bug reel mais localise dans le code de trace).
  Sinon -> race rare, difficile, deprioriser au profit du chemin crypto lui-meme.
- RESEAU du pad : api.anthropic.com est JOIGNABLE (TCP 443 OK, DNS v4+v6 ok ;
  ICMP bloque, normal). Le `-p` ne rend donc pas par LENTEUR du chemin crypto
  emule (chaque operation TLS ~1500-2000x plus lente), pas par absence de
  reseau. Un `-p` qui rendrait atteindrait au moins une erreur d'auth (pas de
  cle ANTHROPIC_API_KEY sur le pad) = sortie valide au sens du GOAL.

## Pistes d'investigation (par ordre de valeur)

1. REPRODUIRE de facon fiable AVANT de corriger. Idees :
   - relancer plusieurs fois le `-p` observable et compter les crashs vs les
     non-crashs (le crash est-il systematique ? lie a QEMU_STRACE ?) ;
   - isoler le chemin crypto SANS Claude : un petit guest aarch64 statique qui
     fait une poignee de main TLS (BoringSSL ou mbedTLS ou openssl) vers un
     serveur local, sous le fork, multi-thread. Si ca crashe -> repro minimal
     en or. C'est la meme methode que torn64/simd-dup2/smc-alias (test/*.c).
2. LOCALISER l'instruction fautive : relancer sous `qemu-aarch64 -d
   in_asm,op,cpu -D log` borne autour du crash, ou `-d unimp,guest_errors`.
   Le dernier bloc traduit + l'etat CPU au SIGSEGV pointent l'op guest. Un core
   dump hote (ulimit -c) + gdb sur qemu donne la stack HOTE (helper fautif ?).
3. SUSPECTS classiques 64-on-32 sur ce chemin :
   - instruction NEON/crypto non geree ou mal abaissee (meme classe que
     dup2_vec mais autre op ; BoringSSL ARM emet AES/SHA/PMULL/bignum NEON) ;
   - acces 128-bit (STXP/LDXP, stop-the-world sur armv7) mal gere sous charge
     multi-thread ;
   - acces non aligne ou cross-page 64-bit sur un buffer crypto ;
   - un helper qui deref un pointeur guest non verifie (lock_user manquant).
4. Verifier si le bug EXISTE en amont (v9.2.4 vierge) ou est propre au fork :
   rejouer le meme guest crypto sous un qemu 9.2.4 non patche (comme
   l'attribution baseline des autres bugs). Etablit regression-vs-preexistant.

## ETABLI ailleurs (ne pas re-tester, cf. docs/METHODOLOGY.md)

- 4 fixes corrects : atomicite 64-bit (torn64), SIMD dup2_vec, termios2, SMC.
  8 patches sur yumi-64on32 (patches/), s'appliquent sur v9.2.4 vierge.
- Boot du benchmark : jamais-fini -> 106 s (tb-size 256 + BUN_JSC_useJIT=0 +
  build -O2). Le `-p` atteint le reseau en ~20 min. La VITESSE n'est PAS ton
  sujet (voir docs/EFFICIENCY-HANDOFF.md pour ce volet, separe).
- Le build est RELEASE -O2 depuis le 2026-07-20 (build.sh). Un crash en -O2
  doit etre reverifie en -O0 (--enable-debug) : les assertions TCG debug
  peuvent transformer un SIGSEGV en assertion nommee (indice sur la cause).
  C'est le PREMIER reflexe : rebuild --enable-debug et rejouer le crash, une
  assertion TCG donnerait le fichier:ligne exact.

## Infra (fixe)

- Repo ~/Documents/GitHub/qemu-64on32-smartpi ; sous-repo qemu/ branche
  yumi-64on32. Build : `bash build.sh` (docker colima ; --enable-debug pour la
  variante assertions, cf. build.sh a rebasculer temporairement).
- Pad H3 : test/pad.env ; harnais test/run-claude-pad.sh (overrides
  CLAUDE_CPUS/MEMMAX/EXTRA_ENV/ARGS_EXTRA/SETARCH). Guests de test : test/*.c
  compiles par test/build-guests.sh. ALIMENTATION SECTEUR obligatoire (des
  runs ont ete perdus sur batterie).
- Journal : PROGRESS.md. Hygiene commits : aucune mention d'outil IA, pas de
  tirets cadratins. Publication GitHub = gate humain, jamais autonome.
