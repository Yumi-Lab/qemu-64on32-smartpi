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

- `torn64`, 4 threads, 180 s : **0 déchirure sur 1 175 356 114 itérations**. Le même test est
  **rouge en baseline** (QEMU 9.2.4 non patché) : la reproduction de la panne est dans
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

**Vitesse — explicitement hors critère.** Le surcoût TCG (8 à 20×) est structurel sur cette
classe de machine. Une seule optimisation a été retenue, parce qu'elle est mesurée : les options
de compilation `-O3 -mcpu=cortex-a7 -flto` donnent **+4,41 %** sur `claude --help` (médiane 65 s
contre 68 s, 4 paires alternées, sortie identique). La décomposition montre que `-mcpu` seul
n'apporte rien.

**Pistes explorées et fermées, avec leurs chiffres** — elles sont documentées pour éviter qu'on
les refasse :

- mémoïsation de traduction par contenu : **−353 %** de débit, et un défaut de correctness
  démontré (la longueur du code hôte émis dépend du contexte) ;
- cache de traduction persistant : supprime 100 % de la retraduction pour **0,0 %** de gain —
  ce qui établit que la traduction n'est pas le goulot ;
- calcul paresseux des drapeaux NZCV : la prémisse était un artefact de compteur (ratio réel
  0,39 et non 2,74).

**En cours.** Un banc de débit multithread (`test/mtbench.c`) montre que le code auto-modifiant
**anti-scale** : 0,76× à 2 threads, là où les charges atomiques et d'allocation scalent
normalement (1,77× et 2,15×). La cause est localisée — contention, pas volume. Le correctif
n'est pas validé à ce jour.

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
