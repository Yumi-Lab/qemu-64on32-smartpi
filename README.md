# qemu-64on32-smartpi

Fork de QEMU 9.2.4 qui rend le user-mode **64-on-32** — invité aarch64 **multithread** sur hôte
armv7l — **atomiquement correct** sur Cortex-A7 LPAE (Allwinner H3, SmartPi / SmartPad).

QEMU >= 10.0 a supprimé le 64-on-32 ; 9.2.4 est la dernière base fonctionnelle, mais son
user-mode déchire les accès 64 bits entre threads (*« in user mode atomicity was simply
broken »*). Sur Cortex-A7 LPAE, `LDRD`/`STRD` alignés sont single-copy atomic : ce fork route
tout accès invité 64 bits par une émission atomique garantie.

Résultat mesuré : le binaire natif **Claude Code** (aarch64-linux-musl, ~258 Mo, runtime Bun /
JavaScriptCore avec JIT) démarre, rend son aide, affiche sa TUI interactive et mène un tour
d'agent jusqu'à l'authentification — sur une carte armv7 32 bits à 1 Go de RAM.

## Appliquer les patches

Série de **16 patches** sur le tag upstream `v9.2.4`, exportée par
`git format-patch v9.2.4..yumi-64on32` :

```bash
git clone --branch v9.2.4 https://gitlab.com/qemu-project/qemu.git
cd qemu
git apply --check ../patches/*.patch     # vérification à blanc
git am ../patches/*.patch                # application dans l'ordre
```

L'ordre compte : plusieurs patches touchent `tcg/arm/tcg-target.c.inc`.

## Compiler

Le build ne se fait **jamais sur la carte** (1 Go de RAM) : il tourne dans Docker sur une
machine de développement, en cross-compilation armhf statique.

```bash
bash build/mkimage.sh   # image de build qemu64on32-build (cross armhf + glib statique)
bash build.sh           # -> build-out/qemu-aarch64 (ELF 32-bit ARM, statique)
```

## Exécuter

```bash
./qemu-aarch64 ./mon-binaire-aarch64                  # invité statique
QEMU_TB_SIZE=64 ./qemu-aarch64 ./mon-binaire-aarch64  # cache de traduction, en MiB
```

Les réglages ajoutés par le fork, avec ce que la mesure dit de chacun :

| Réglage | Effet | Ce que la mesure dit |
|---|---|---|
| `-tb-size N` / `QEMU_TB_SIZE=N` | taille du cache de traduction en MiB (défaut 32) | **ne pas l'augmenter à l'aveugle** : au-delà de ±32 Mo le chaînage direct entre blocs est perdu, et ce coût dépasse le gain de cache. Sur charge multithread auto-modifiante, 32 bat 256 de **+21,98 %** (2 threads) et **+17,65 %** (4 threads). L'augmenter reste utile contre une tempête de `tb_flush` sur un gros runtime mono-thread |
| `-tb-cache <fichier>` / `QEMU_TB_CACHE=<fichier>` | cache de traduction **persistant** entre exécutions | 0,0 % en mono-thread, −1,14 % à 2 threads, **+12,37 % à 4 threads** : il ne paie qu'au-delà de 2 threads. Exige de figer l'ASLR (`setarch $(uname -m) -R`), sinon `guest_base` change et le cache est ignoré |
| `QEMU_TB_FLUSH_LOG=1` | une ligne `stderr` par `tb_flush` | diagnostic de dimensionnement du cache |
| `QEMU_TB_EXEC_PROFILE=1` | profil des blocs pondéré par l'exécution | instrumentation ; coût nul quand la variable est absente |
| `QEMU_OP_HISTOGRAM=1` | histogramme des opcodes traduits | idem |

## Le point technique central

Un invité aarch64 multithread écrit et lit des mots de 64 bits qui doivent être vus **entiers**
par les autres threads. Sur un hôte 32 bits, QEMU 9.2.4 les décompose en deux accès 32 bits :
un thread peut alors observer une moitié ancienne et une moitié nouvelle — une **déchirure**,
qui corrompt silencieusement la mémoire de l'invité.

Le Cortex-A7 avec LPAE garantit l'atomicité single-copy des `LDRD`/`STRD` **alignés**. Les
patches 0001 et 0002 forcent le backend TCG à les émettre pour tout accès invité `MO_64` aligné
(contraintes de paire de registres, alignement forcé), et à router le cas non aligné vers le
helper atomique. C'est le cœur du fork ; le reste traite des pièges rencontrés en exerçant un
vrai runtime JIT.

## Contenu

| Chemin | Rôle |
|---|---|
| `patches/` | la série applicable sur `v9.2.4` (16 patches) |
| `build.sh`, `build/` | build cross armhf statique reproductible (Docker) |
| `test/` | harnais d'exécution sur carte réelle ; `test/pad.env` (non versionné) porte la config |
| `test/logs/` | **preuves d'exécution brutes** de chaque mesure citée ici |
| `docs/METHODOLOGY.md` | méthode, mesures, et limites assumées |
| `docs/REPRO.md` | reproduction de la déchirure en baseline |
| `PROGRESS.md` | journal de bord complet, y compris les pistes fermées et les erreurs |

## Prérequis

- **Build** : Docker, ~4 Go de disque. Aucun outil ARM sur la machine hôte, tout est dans l'image.
- **Test** : une carte armv7l (Cortex-A7) accessible en SSH. Le harnais impose `taskset` sur
  2 cœurs, une borne mémoire, un `timeout` dur, une garde thermique, et refuse de lancer un
  second qemu concurrent.
- L'invité dynamique musl exige un sysroot minimal (`ld-musl-aarch64.so.1`), voir `test/`.

## Statut mesuré

Chaque ligne ci-dessous correspond à un log dans `test/logs/`. Rien n'est annoncé qui n'ait été
exécuté sur la carte réelle.

**Correctness — c'est l'objet du projet.**

- `torn64`, 4 threads, 180 s : **0 déchirure sur 1 175 564 796 itérations**, sur le binaire même
  de la release (`test/logs/o3lto-correctness/release-gate-v9.2.4-yumi.2-20260812.txt`). Le même
  test est **rouge en baseline** (QEMU 9.2.4 non patché) : la reproduction de la panne est dans
  `docs/REPRO.md`.
- `simd-dup2` : le crash de lowering SIMD (`dup2_vec` à une moitié constante) est corrigé et la
  valeur calculée vérifiée.
- `smc-alias` : le code auto-modifiant dual-mappé W^X exécute bien du code frais à chaque tour
  (l'invalidation sur `IC IVAU` est correcte).
- `tcgets2` : la famille d'ioctl `termios2` répond (nécessaire aux TUI).

**Charges réelles.**

- **Claude Code 2.1.217** : `--version` rend `rc=0` ; `--help` rend ses 16 036 octets ; la TUI
  interactive s'affiche ; `claude -p` atteint le contrôle d'authentification. Les versions
  antérieures à 2.1.214 **échouent** (SIGTRAP) — c'est une propriété de l'invité, pas du fork.
- **TUI grok** : survit plus de 30 minutes sous charge JIT.

**Vitesse.** Le surcoût TCG (8 à 20×) est structurel sur cette classe de machine et le projet ne
prétend pas le supprimer. Une seule optimisation a été retenue, parce qu'elle est mesurée : les
options de compilation `-O3 -mcpu=cortex-a7 -flto`.

Son intérêt dépend entièrement de la charge, et c'est le point le plus utile de ce dépôt :

| charge | gain |
|---|---|
| `claude --help` (mono-thread) | **+4,41 %** — médiane 65 s contre 68 s |
| code auto-modifiant, 2 threads, 4 cœurs | **+59,9 %** — médiane 6 612 contre 4 136 ops/s |

Le second chiffre est celui qui compte pour la cible réelle : un runtime JavaScript compile du
code depuis plusieurs threads en permanence. Mesuré avec `test/mtbench.c` **sur la branche
publiée**, les deux bras issus du même `build.sh`, n=3, cellules de 60 s, alternance ABAB,
plages disjointes (pire cas optimisé 6 458 > meilleur cas non optimisé 4 372) —
`test/logs/mtbench/o3lto-vs-o2-yumi64on32-20260813.txt`. La décomposition montre par ailleurs
que `-mcpu` **seul** n'apporte rien : le gain vient de `-O3` et de LTO.

Nous avons jugé ces options sur la charge mono-thread pendant trois semaines, où elles
paraissaient marginales. Elles valent treize fois plus sur la charge représentative.

> Une version antérieure de cette page annonçait **+74,6 %**. Ce chiffre venait d'un A/B mené sur
> une branche de travail instrumentée, dont le bras `-O2` était ralenti par l'instrumentation :
> le ratio en sortait gonflé. Rejoué sur la branche publiée, le bras optimisé est quasi identique
> (6 612 contre 6 356) — c'est le témoin qui bougeait (4 136 contre 3 641). Le gain reste large et
> ses plages disjointes ; seul son ordre de grandeur exact change.

**Le fait qui commande tout le reste.** Le banc de débit multithread (`test/mtbench.c`) montre
que le code auto-modifiant **anti-scale** : **0,633× à 2 threads** dans la configuration retenue
(0,419× sans `-O3`/LTO), mesuré sur la branche publiée
(`test/logs/mtbench/scaling-n1-yumi64on32-20260813.txt`) — passer d'un thread à deux fait
*perdre* du débit — là où les charges atomiques et d'allocation du même banc scalent
normalement (1,77× et 2,15×, chiffres de la campagne précédente, non rejoués ici). Émuler un JIT à plusieurs threads coûte plus cher que de l'émuler
seul. La cause est une contention, pas un volume de travail.

**Pistes explorées et fermées, avec leurs chiffres** — documentées pour éviter qu'on les
refasse :

- mémoïsation de traduction par contenu : **−353 %** de débit, et un défaut de correctness
  démontré (la longueur du code hôte émis dépend du contexte) ;
- calcul paresseux des drapeaux NZCV : la prémisse était un artefact de compteur (ratio réel
  0,39 et non 2,74) ;
- retrait du verrou `pageflags_lock` du chemin chaud : **0,690× après contre 0,711× avant** — le
  scaling ne bouge pas ;
- chaînage direct des blocs par *veneers* : le coût de la portée perdue est réel (**plafond
  mesuré 6 à 9 % par chaîne**), mais aucun banc disponible n'exhibe les chaînes lointaines qu'un
  veneer récupérerait ; non démontrable ici, donc non codé.

**Le même piège a frappé deux fois, et c'est la leçon du dépôt.** Le cache de traduction
persistant avait été fermé à **0,0 %** de gain — mesuré en mono-thread. On en avait tiré que « la
traduction n'est pas le goulot », ce qui fermait par ricochet toute une famille de pistes.
Rejoué en multithread, il rend **+12,37 % à 4 threads** (et −1,14 % à 2) : l'argument ne valait
que pour la charge sur laquelle il avait été mesuré. Même chose pour la taille du cache, où
`tb=32` bat `tb=256` — l'inverse de l'intuition. Les deux réglages sont dans « Exécuter ».

La campagne d'optimisation est close depuis le **11 août 2026**, chaque mesure avec son jeu
d'attribution dans `PROGRESS.md`. Le seul levier de fond encore identifié est une codegen
64 bits, bornée à « quelques % » par les mesures du projet ; il n'est pas engagé.

## Quand utiliser ce fork — et quand ne pas

C'est un **dernier recours**, pas une plateforme d'exécution. Le surcoût d'émulation est
structurel et ne se rattrape pas : `claude --version` met **43 s** sous le fork sur un H3
(2 cœurs, binaire de cette release).

- **À utiliser** pour un binaire aarch64 qu'on ne peut pas porter : distribué en binaire seul,
  compilé depuis un langage sans chaîne 32 bits sous la main, ou dont la logique n'existe sous
  aucune autre forme. C'est le cas de `grok` (Rust compilé) — là, il n'y a pas d'alternative, et
  c'est la valeur irremplaçable de ce dépôt.
- **À ne pas utiliser** quand la charge existe en version portable. Pour Claude Code, la voie
  native — paquet npm pur-JS, ou bundle JS extrait du binaire et exécuté par un Node armv7l
  (recette validée dans `Yumi-Lab/claude-code-smartpi`) — démarre en quelques secondes contre
  des dizaines sous émulation. Le fork n'y apporte rien.

## Développement

Le travail avance lot par lot (`PROGRESS.md`, tags `[EASY]` / `[MED]` / `[HARD]`), chaque lot
étant validé par un gate mécanique (`verify.sh`) et une exécution réelle sur carte. Le clone de
travail `qemu/` n'est pas versionné ici : seuls les patches exportés le sont.

Une règle gouverne le journal : **toute mesure porte son jeu d'attribution** — la commande
exacte, la sortie brute, l'identité (sha, version) de chaque composant qui pourrait expliquer le
résultat, et ce que la mesure ne dit pas. Un résultat sous-documenté ne manque pas de détail : il
propage une conclusion fausse à la relecture. Ce projet en a fait les frais quatre jours durant.

## Licences

Les patches de `patches/` sont dérivés de QEMU et suivent sa licence, **GPL-2.0**. Le harnais
(`build.sh`, `build/`, `test/`, `docs/`) est publié sous la même licence pour la cohérence de
l'ensemble. QEMU est un projet tiers ; ce dépôt n'y est pas affilié.
