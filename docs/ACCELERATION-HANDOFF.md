# Passation , Accélérer le boot d'un runtime aarch64 sous le fork QEMU 64-on-32

Document pour **une instance/ingénieur qui prend le sujet**. Tu hérites d'une base solide et
d'un problème de performance **ouvert et très abordable**. Tout ce qui suit est du matériel de
travail : artefacts, environnement reproductible, mesures de référence, et un large éventail de
leviers à explorer. À toi de trouver et d'implémenter l'accélération.

## Ta mission
Faire **booter vite** le binaire **Claude Code natif aarch64** (et par extension tout gros
runtime JIT type Bun/JSC) sous le fork, sur le board armv7, jusqu'à un **système fonctionnel et
interactif**. **Changer de langage, d'approche, de couche d'optimisation est autorisé** , latitude
totale sur le « comment ».

Bonne nouvelle de départ : **la correctness est déjà résolue et prouvée** (voir §1). Le binaire
s'exécute **correctement** sous le fork , pas de crash, pas de corruption. Tu n'as donc **pas** à
te battre avec la justesse : c'est un **problème de vitesse pur**, le genre le plus tractable, avec
beaucoup de leviers classiques encore inexploités ici.

---

## 1. Ce qui est déjà construit et prouvé (ta fondation)

### Le fork QEMU
- Base : **QEMU v9.2.4** (dernière branche upstream avec le user-mode 64-on-32).
- Repo : `~/Documents/GitHub/qemu-64on32-smartpi` ; clone de travail `qemu/`, branche
  `yumi-64on32`, **4 commits** (série dans `patches/`, s'applique proprement via `git am` sur un
  `v9.2.4` vierge, arbre identique) :
  1. `f3cc256` tcg/arm : LDRD garanti pour load invité 64-bit aligné (atomicité).
  2. `1ba623b` tcg/arm : STRD garanti pour store invité 64-bit aligné (atomicité).
  3. `dab6ddc` linux-user : backport famille ioctl termios2 (TCGETS2/TCSETS2/…).
  4. `882961f` tcg/arm : lowering `dup2_vec` à une moitié constante (`C_O1_I2(w,r,r)` + VMOV
     cœur→doubleword).
- Binaire : `build-out/qemu-aarch64` (ELF **32-bit ARM armhf statique**),
  sha256 `8373bb580a6a49b9d201643038eadb45067f04cfbcfdd6f3b844df26c056a767`.
- Atomicité prouvée par `torn64` : rouge en baseline, **vert sous le fork** (~549 M itérations,
  0 déchirure, N=2/4/8). Logs : `test/logs/fixa/`, `test/logs/baseline/`.
- Le fork **exécute le vrai Claude Code natif proprement** : run long observé sans aucune
  assertion TCG, sans SIGABRT, sans corruption. **L'exécution est correcte ; le levier, c'est la
  vitesse.**

### La cible (binaire à faire booter)
- **Claude Code natif `linux-arm64-musl` 2.1.205** (Bun/JSC compilé).
- URL : `https://downloads.claude.ai/claude-code-releases/2.1.205/linux-arm64-musl/claude`
  (résolution : `.../claude-code-releases/latest` puis `.../<version>/manifest.json`).
- 247 Mo (255 243 624 octets). ELF 64-bit aarch64, **dynamique**.
- Interpréteur : `/lib/ld-musl-aarch64.so.1`. `DT_NEEDED` : `libc.musl-aarch64.so.1`
  (musl self-contained ; le loader EST la libc). Aucune autre dépendance.

### Le board
- **Allwinner H3, Cortex-A7 (ARMv7-A + LPAE), 4 cœurs ~1 GHz, 1 Go RAM**, OS Yumi/trixie.
- Accès : `source test/pad.env && sshpass -p "$PAD_PASS" ssh "$PAD_USER@$PAD_HOST"` ; dossier `/home/pi/qemu-fork-test/`.
- Fork + Claude natif déjà déployés (+ sysroot `sysroot/lib/ld-musl-aarch64.so.1`).
- Thermique : throttle CPU ~75 °C. **Dissipateur dual-fan disponible** → 4 cœurs plein régime
  sans throttling (~48 °C mesuré). Tu as donc **de la marge CPU et 3 cœurs libres** à exploiter.

### Harnais de test (réutilisable)
- `test/run-claude-pad.sh <version|prompt> [timeout_s] [prompt_text]` , déploie/vérifie, lance
  `claude --version`/`claude -p` sous le fork, avec `taskset` (`CLAUDE_CPUS`), `MemoryMax`
  (`CLAUDE_MEMMAX`), `timeout`, garde thermique (`CLAUDE_ABORT_TEMP`). Émet une ligne machine :
  `RESULT=… exit_rc=… elapsed=… out_bytes=… peak_temp_c=…` , idéale pour **mesurer tes gains**.
- `test/run-pad.sh` (générique), `test/build-guests.sh` (compile les guests aarch64).

### Chaîne de build (Mac, sans toucher le pad)
- `bash build/mkimage.sh` , image docker `qemu64on32-build` (via **colima** ; `colima start` si
  `docker info` échoue).
- `bash build.sh` , cross armhf statique, cible `aarch64-linux-user` → `build-out/qemu-aarch64`
  (rebuild ninja incrémental, rapide).

### Boucle d'itération RAPIDE sur le Mac (émulation imbriquée, sans pad)
Tu peux exécuter le fork + un guest aarch64 **directement sur le Mac** pour profiler/débugger vite :
```
# image : arm64v8/alpine (musl) + debian:bookworm-slim + qemu-user-static (qemu-arm 7.2)
#   COPY --from=musl /lib/ld-musl-aarch64.so.1 /guestroot/lib/ ; ln -s ... libc.musl-aarch64.so.1
docker run --rm -v <repo>/build-out:/g:ro nest-claude bash -c \
  'QEMU_LD_PREFIX=/guestroot qemu-arm-static /g/qemu-aarch64 -L /guestroot /g/claude-native --version'
```
Vérifié fonctionnel : `qemu-arm → fork → hello aarch64` OK, `simd-dup2` sort les bonnes valeurs.
C'est une **boucle de dev courte** pour instrumenter le chemin de démarrage (traces TCG, `perf`)
sans dépendre du pad.

---

## 2. Profil de démarrage actuel (ta ligne de base à battre)

Mesures reproductibles via `test/run-claude-pad.sh` + lecture `/proc`. **C'est le point de départ
non optimisé ; ton travail est de le faire descendre.**

| Invocation | cœurs | RSS (début→palier) | thermique | note |
|---|---|---|---|---|
| `claude --version` | 1 | 8 → ~194 Mo | ok | référence légère (pas de réseau) |
| `claude -p "..."`  | 1 | 8 → ~263 Mo | 44-64 °C | mono-cœur |
| `claude -p "..."`  | 4 | 8 → ~297 Mo | 41-48 °C (fan) | 4 cœurs dispo |

### Profil CPU/threads pendant le démarrage (snapshot `ps -T` + `/proc/<pid>/task/*/stat`)
```
%CPU total du process ≈ 101 %             (= un cœur de travail ; 3 cœurs restent LIBRES)
TID    CŒUR  ÉTAT   %CPU   nom
<main>  x    R      ~98    qemu-aarch64    ← le thread qui porte le démarrage
<w1>    x    S       0.0   qemu-aarch64    ← worker en attente
<w2>    x    S       ~4    mi-scavenger    ← thread GC
```
Le thread de démarrage **migre** entre cœurs (htop montre 4 barres actives = migration).

### Nature de l'attente (`/proc`) , c'est une bonne nouvelle pour toi
- `voluntary_ctxt_switches` bas, `nonvoluntary_ctxt_switches` qui monte → **CPU-bound pur** :
  ça **calcule**, ce n'est **ni** bloqué sur un syscall/IO, **ni** en deadlock.
- La RSS se stabilise (~263-297 Mo) après chargement : le temps est ensuite du **calcul**
  (traduction/exécution du chemin de démarrage du runtime JS).

**Traduction actionnable** : c'est un problème de **débit de calcul émulé**, franc et mesurable
, exactement la classe de problème que les techniques ci-dessous attaquent bien.

---

## 3. Leviers à explorer (large et ouvert , rien n'est écarté)

**A. Traducteur TCG (attaque directe du coût d'émulation)**
- **Cache de traduction persistant / warm start** : réutiliser les Translation Blocks d'un run à
  l'autre au lieu de re-traduire à chaque démarrage. Le même chemin de boot est re-JIT à chaque
  fois , le mettre en cache (disque/mmap) est un gain direct et répétable.
- Réglages TCG : taille du buffer de TB (`-accel tcg,tb-size=`), chaînage de blocs, niveau
  d'optimisation sur les blocs chauds, meilleurs helpers pour les primitives fréquentes.
- **Profiler** le chemin chaud (`qemu -d op,op_opt,out_asm`, compteurs de TB, `perf` sur qemu ,
  côté pad ou dans l'env imbriqué Mac) : identifier les opérations invitées qui dominent et les
  optimiser spécifiquement.

**B. Runtime invité (réduire le travail au démarrage)**
- **Snapshot / cache bytecode de Bun/JSC** : démarrer depuis un heap/bytecode pré-compilé plutôt
  que tout re-JIT. Bun sait faire des snapshots ; JSC a des caches bytecode.
- Flags/env qui allègent le premier démarrage (désactiver des sous-systèmes non essentiels au
  premier rendu). Précompiler/geler l'état de démarrage et le réhydrater.

**C. Runtime alternatif / re-cible (langage libre)**
- Extraire le JS applicatif (le trailer du binaire Bun est lisible ; outils publics existants) et
  le faire tourner sous un moteur plus léger à émuler (Node aarch64, QuickJS, moteur interprété).
  Les APIs Bun-only se polyfillent , tâche d'ingénierie à cadrer.
- Ou re-cibler la partie critique du démarrage dans un langage/outil de ton choix.

**D. AOT / hors-ligne**
- Pré-traduire hors-ligne le chemin de démarrage (AOT du guest, ou fork instrumenté qui dumpe
  puis recharge la traduction).

**E. Backend arm du fork**
- Usage NEON, alignement, accès cross-page dans les chemins chauds : tout gain sur les primitives
  fréquentes se multiplie sur un warmup JIT.

**F. Parallélisme (3 cœurs libres + refroidissement dispo)**
- Le démarrage occupe **un** cœur ; 3 sont libres et le dual-fan autorise le plein régime.
  Toute technique qui **parallélise** une partie de la traduction, du warmup ou du travail invité
  exploiterait cette marge matérielle inutilisée.

---

## 4. Reproduire vite

```bash
# 1) build du fork (Mac + docker/colima)
cd ~/Documents/GitHub/qemu-64on32-smartpi
docker info >/dev/null 2>&1 || colima start
bash build/mkimage.sh && bash build.sh          # -> build-out/qemu-aarch64

# 2) mesurer le boot sur le pad (4 cœurs, borné, thermal-guardé) , note out_bytes/elapsed
CLAUDE_CPUS="0,1,2,3" CLAUDE_MEMMAX=800M CLAUDE_ABORT_TEMP=92000 \
  bash test/run-claude-pad.sh prompt 3600 "Reply with the single word OK and nothing else."

# 3) profiler SANS le pad (env imbriqué Mac) , traces de codegen sur le chemin de boot
docker run --rm -v $PWD/build-out:/g:ro nest-claude bash -c \
  'QEMU_LD_PREFIX=/guestroot qemu-arm-static /g/qemu-aarch64 -d op_opt,out_asm -L /guestroot /g/claude-native --version 2>&1 | head'

# 4) référence de correctness : torn64 vert sous le fork
CLAUDE_CPUS=0,1 bash test/run-pad.sh torn64 4 30
```

---

## 5. Artefacts & preuves
- `patches/` : les 4 patches (base). `build.sh` + `build/` : build. `test/run-claude-pad.sh`,
  `test/run-pad.sh`, `test/build-guests.sh` : harnais.
- `test/logs/` : `fixa/`+`baseline/` (torn64), `simd/`, `claude-native/` (runs de boot),
  `grok-tui/`.
- `docs/` : `AUDIT-ldst.md`, `AUDIT-simd-movi.md`, `REPRO.md`, `METHODOLOGY.md`.
- `GOAL.md`, `PROGRESS.md` : cadrage et journal détaillé (repro, chiffres, commandes).

**Départ conseillé** : lance le boot une fois pour prendre ta mesure de référence (§4-2), puis
profile le chemin de démarrage dans l'env imbriqué Mac (§4-3) pour voir où part le calcul, et
attaque le levier qui te parle (cache de traduction §3.A ou snapshot Bun/JSC §3.B sont des
points d'entrée à fort potentiel). Tu pars d'un fork qui exécute le binaire correctement , tout
le champ de la vitesse est à toi.
