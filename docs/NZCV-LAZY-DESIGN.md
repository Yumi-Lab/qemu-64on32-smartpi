# NZCV-LAZY-DESIGN, design du chantier NZCV paresseux (lot L0, phase L)

Design ecrit AVANT tout code, comme l'exige le lot L0 de PROGRESS.md. Toutes les references de
ligne pointent sur `qemu/` branche `nzcv-lazy`, commit `7b657c6` (HEAD au moment de l'audit) ;
a revalider (grep, pas de confiance aveugle au numero de ligne) avant chaque patch du lot L1.
Contexte GO deja etabli, ne pas re-deriver : ratio defs/reads = 2,74 (--version et --help,
commit 7b657c6), voir PROGRESS.md phase L et `docs/EFFICIENCY-HANDOFF.md`.

## 0. Perimetre du lot L1 (rappel)

Seul le SUB/CMP 64-bit (`gen_sub64_CC`, appele quand `sf==1` dans `gen_sub_CC`) devient
paresseux sous `QEMU_NZCV_LAZY=1`. Tout autre point de definition (ADD, ADC, logique, SUB
32-bit, MSR NZCV, tout side-effect de registre systeme) continue de materialiser NF/ZF/CF/VF
immediatement, comme aujourd'hui. Flag OFF (defaut) : zero instruction TCG supplementaire
emise, comportement bit-a-bit identique au publie. Aucune mesure de gain dans ce lot (L4).

## 1. Enum cc_op

```c
/* target/arm/tcg/translate.h ou un nouveau target/arm/tcg/cc_op.h partage */
typedef enum {
    CC_OP_FLAGS = 0,   /* NF/ZF/CF/VF a jour dans env, cc_src1/cc_src2 non significatifs */
    CC_OP_SUB64,       /* NF/ZF/CF/VF PAS a jour ; derivables de cc_src1 - cc_src2 (64 bit) */
    CC_OP_NB,
} ARMCCOp;
```

`CC_OP_FLAGS` reste la valeur 0 : un `CPUARMState` zero-initialise (etat de depart d'un CPU)
demarre donc materialise, aucune init explicite requise. Extension future (L2+, HORS
perimetre L1, ne pas commencer) : `CC_OP_ADD64`, `CC_OP_ADC64`, `CC_OP_LOGIC64`, variantes
32 bit, chacune avec sa formule dans `gen_compute_nzcv()` ; propagation compile-time du cc_op
connu inter-instructions dans un meme TB (voir section 3, simplification volontaire du L1).

## 2. Globals TCG et champs CPUARMState

Champs `CPUARMState` (`target/arm/cpu.h`, juste apres le bloc CF/VF/NF/ZF existant, ligne
~256) :

```c
uint32_t cc_op;      /* ARMCCOp, valide seulement en user-mode pour ce chantier */
uint64_t cc_src1;     /* SUB64 : minuende (t0) */
uint64_t cc_src2;     /* SUB64 : subtrahend (t1) */
```

Aucune entree dans `target/arm/machine.c` (VMStateDescription) : ces champs restent hors
migration, comme l'exige GOAL.md. Reconstructibles a tout instant (materialisation), et de
toute facon la migration n'existe pas en linux-user.

Globals TCG (`target/arm/tcg/translate.h`, a cote de `extern TCGv_i32 cpu_NF, cpu_ZF, cpu_CF,
cpu_VF;` ligne 184) :

```c
extern TCGv_i32 cpu_cc_op;
extern TCGv_i64 cpu_cc_src1, cpu_cc_src2;
```

Initialises dans `arm_translate_init()` (`target/arm/tcg/translate.c`, a cote des
`cpu_CF/NF/VF/ZF` lignes 69-72) via `tcg_global_mem_new_i32`/`_i64` vers les offsets
ci-dessus. Utiliser des globals TCG (pas des `tcg_gen_st_*` manuels) donne gratuitement la
dead-store elimination de l'optimiseur TCG quand le flag est OFF (aucune reference emise dans
ce cas, voir section 5).

Pas de champ `cc_op` compile-time dans `DisasContext` pour L1 (simplification volontaire, voir
section 3) : la propagation inter-instructions du cc_op connu statiquement est reportee a L2.

## 3. gen_compute_nzcv(), signature et emplacement

```c
/* target/arm/tcg/translate-a64.c, avant a64_test_cc (avant la ligne ~432),
   a cote de gen_set_NZ64 */
static void gen_compute_nzcv(void);
```

Pas de parametre `DisasContext *s` pour L1 : sans tracking compile-time du cc_op (section 2),
la fonction n'a besoin que d'emettre, sous flag ON, un appel helper inconditionnel :

```c
static void gen_compute_nzcv(void)
{
    if (!arm_nzcv_lazy_enabled()) {
        return;                      /* flag OFF : zero code emis, zero cout */
    }
    gen_helper_compute_nzcv(tcg_env);
}
```

`arm_nzcv_lazy_enabled()` : petite fonction cachee (`getenv("QEMU_NZCV_LAZY")` lu UNE fois,
meme style que `QEMU_KEEP_BTI`/`QEMU_KEEP_SVE` dans `target/arm/cpu.c` lignes 2111-2139),
declaree la ou `gen_compute_nzcv` en a besoin (translate.c, visible de translate-a64.c via
translate.h).

Cote C, le helper (`target/arm/tcg/op_helper.c` ou `helper-a64.c`, DEF_HELPER en `void, env`
dans `helper.h`) :

```c
void HELPER(compute_nzcv)(CPUARMState *env)
{
    if (env->cc_op == CC_OP_FLAGS) {
        return;                       /* deja materialise : idempotent, cout minimal */
    }
    /* CC_OP_SUB64 : meme formule que gen_sub64_CC, en C */
    uint64_t t0 = env->cc_src1, t1 = env->cc_src2;
    uint64_t result = t0 - t1;
    env->ZF = (uint32_t)result | (uint32_t)(result >> 32);
    env->NF = (uint32_t)(result >> 32);
    env->CF = t0 >= t1;
    env->VF = (uint32_t)(((result ^ t0) & (t0 ^ t1)) >> 32);
    env->cc_op = CC_OP_FLAGS;          /* appeler deux fois de suite est un no-op la 2e fois */
}
```

Note perf (hors perimetre de mesure L1, juste pour justifier le design) : le cout est un appel
helper par LECTURE reelle, pas par definition ; c'est deja le gain vise (2,74 defs pour 1 read
mesure, potentiellement plus vu la correction de la section 4.2). L'inline compile-time
(eviter l'appel helper quand le cc_op est connu statiquement dans le meme TB, cas frequent
SUBS immediatement suivi de B.cond) est un affinement L2, pas necessaire pour la correction du
L1.

## 4. Inventaire exhaustif

### 4.1 Points de DEFINITION (`target/arm/tcg/translate-a64.c`)

| Fonction | Ligne | Sous flag ON | Sous flag OFF |
|---|---|---|---|
| `gen_logic_CC` (AND/ORR/EOR avec S) | ~785 | eager, pose `cpu_cc_op=CC_OP_FLAGS` | inchange |
| `gen_add64_CC`/`gen_add32_CC` (via `gen_add_CC`) | ~798-846 | eager, pose `CC_OP_FLAGS` | inchange |
| `gen_sub32_CC` (via `gen_sub_CC`, `sf==0`) | ~871-888 | eager, pose `CC_OP_FLAGS` | inchange |
| `gen_sub64_CC` (via `gen_sub_CC`, `sf==1`) | ~849-869 | **LAZY** : stocke `cc_src1=t0, cc_src2=t1`, pose `CC_OP_SUB64`, n'ecrit PAS NF/ZF/CF/VF | inchange (chemin actuel) |
| `gen_adc_CC` | ~914-951 | eager, pose `CC_OP_FLAGS` | inchange |
| `gen_set_nzcv` (MSR NZCV, Xt -> PSTATE) | ~2238-2256 | ecrit les 4 flags directement, DOIT poser `CC_OP_FLAGS` juste apres (sinon un `CC_OP_SUB64` laisse par une SUBS anterieure dans le meme TB resterait pendant, cf. cas vicieux 6.5) | inchange |

Seul `gen_sub64_CC` change de comportement fonctionnel. Tous les autres points DEFINISSENT
mais doivent explicitement reposer `cpu_cc_op = CC_OP_FLAGS` sous flag ON, au cas ou un
`gen_sub64_CC` anterieur dans le MEME TB aurait laisse `CC_OP_SUB64` pendant.

### 4.2 Points de LECTURE frontend (doivent appeler `gen_compute_nzcv()` avant)

**Correction importante par rapport a l'instrumentation de reconnaissance (commit 7b657c6) :**
le profiler n'a instrumente que `a64_test_cc` (ligne 433), `gen_get_nzcv` (ligne 2219) et
`disas_cc` (lignes 8028/8030). Il a **omis `arm_gen_test_cc`**, qui est le chemin emprunte par
`trans_B_cond` (ligne 1532) : **B.cond, la branche conditionnelle directe la plus commune**
(closes de boucle du dispatch LLInt), n'a PAS ete comptee comme lecture. Le ratio 2,74 est
donc probablement une SOUS-estimation du nombre reel de lectures (encore plus de lectures que
mesure). Cela ne remet pas en cause le GO (memes avec des lectures sous-comptees, la majorite
des defines restent sans lecture immediate, cf. le TB chaud SUB/CMP suivi de branchement rare
dans `test/logs/dump-tb/hot-tbs-llint.dump`), mais cela CHANGE le point d'instrumentation
correct.

Audit exhaustif des appelants (`grep -rn "arm_test_cc(\|arm_gen_test_cc(\|arm_jump_cc(" target/arm/tcg/*.c`) :
tous les chemins de lecture de condition convergent SANS EXCEPTION vers `arm_test_cc()`
(`target/arm/tcg/translate.c:648`) :

- `a64_test_cc` (translate-a64.c:437) -> CSEL/CSINC/CSINV/CSNEG (`disas_cond_select`,
  ligne 8126) et FCSEL (`trans_FCSEL`, ligne 6678).
- `arm_gen_test_cc` (translate.c:734, appelle `arm_test_cc` puis `arm_jump_cc`) -> B.cond
  (`trans_B_cond`, ligne 1532) et FCCMP "no match" (ligne 8882, avant le `gen_set_nzcv` de la
  ligne 8884).
- `disas_cc` (CCMP, ligne 8031) appelle `arm_test_cc` directement pour son test EXTERIEUR
  (celui qui decide si on force `#nzcv` ou si on garde le resultat de la comparaison).
- `translate.c:3496` et `:7305` (`arm_gen_test_cc`/`arm_test_cc` cote A32) : voir 4.5, mort
  dans notre cible.

**Decision de design : instrumenter `arm_test_cc()` lui-meme** (un seul point, translate.c,
partage), pas chaque appelant. `arm_test_cc` ne prend pas de `DisasContext*` (signature
`void arm_test_cc(DisasCompare *cmp, int cc)`) ; comme `gen_compute_nzcv()` n'a pas besoin de
`DisasContext*` pour L1 (section 3), l'insertion est triviale :

```c
void arm_test_cc(DisasCompare *cmp, int cc)
{
    gen_compute_nzcv();   /* nouvelle ligne, tout en haut de la fonction */
    ...
}
```

Ce choix couvre B.cond, CSEL/CSINC/CSINV/CSNEG, FCSEL, FCCMP-nomatch ET le test exterieur de
CCMP en UNE seule insertion, sans avoir a lister/maintenir chaque appelant (DRY). Cote A32
(mort dans notre cible, 4.5), l'appel est un no-op de plus (le `cc_op` d'un TB A32 n'est
jamais mis a `CC_OP_SUB64` puisque le frontend A32 n'appelle jamais `gen_sub64_CC` de
translate-a64.c) : aucun risque fonctionnel, juste un test `env->cc_op == CC_OP_FLAGS`
supplementaire dans du code jamais execute.

Deux points RESTENT a instrumenter individuellement, non couverts par `arm_test_cc` :

1. `gen_get_nzcv` (MRS NZCV, Xt, ligne 2217) : lit directement `cpu_NF/ZF/CF/VF`, jamais via
   `arm_test_cc`. Ajouter `gen_compute_nzcv();` en tete de fonction (a cote du
   `tcg_tb_prof_note_nzcv_read()` existant ligne 2222).
2. **CCMP, lecture INTERNE** (`disas_cc`, entre la ligne 8046/8048 -
   `gen_sub_CC`/`gen_add_CC` - et la ligne 8062 - premier `tcg_gen_or_i32(cpu_NF, ...)`) :
   CCMP calcule une NOUVELLE comparaison puis, dans la MEME fonction, manipule directement
   `cpu_NF/CF/ZF/VF` bit a bit pour fusionner avec l'immediat `#nzcv` selon le resultat du
   test exterieur (deja materialise par le point precedent). Si `op==1` (SUB) et `sf==1`
   (64 bit), `gen_sub_CC` pose desormais `CC_OP_SUB64` (lazy) sous flag ON : le code de
   fusion qui suit IMMEDIATEMENT DOIT d'abord appeler `gen_compute_nzcv();` (insertion juste
   apres la ligne 8048, avant la ligne 8056) sinon il lit des `cpu_NF/CF/ZF/VF` perimes. C'est
   le cas vicieux le plus important du lot (section 6.1).

### 4.3 Definitions "generiques" hors des fonctions nommees

`handle_sys()` (`translate-a64.c:2288`), dispatch generique MRS/MSR vers un registre systeme
avec `readfn`/`writefn` personnalise (`gen_helper_get_cp_reg64`, ligne 2575). Trouve par grep
systematique de `env->NF|env->ZF|env->CF|env->VF` HORS translate-a64.c : `rndr_readfn`
(`target/arm/helper.c` ligne ~8269, MRS RNDR/RNDRRS, FEAT_RNG) pose NZCV=0000 (succes) ou
ZF=0 (echec) directement en C, en dehors de toute fonction `gen_*_CC` connue.

Regle de surete generique (le trans_* ne sait pas statiquement si le `readfn` du cpreg touche
NZCV, et une liste blanche casserait la regle DRY / serait fragile a une extension future de
QEMU) : **apres tout appel a un `readfn` de registre systeme via `handle_sys`, poser
`cpu_cc_op = CC_OP_FLAGS`** (un `tcg_gen_movi_i32`, sous flag ON uniquement). Couvre RNDR
aujourd'hui et tout cpreg similaire ajoute plus tard sans maintenance de liste.

### 4.4 Points de sortie C / hors TCG : le choke point `pstate_read`/`pstate_write`

Grep exhaustif des lecteurs/ecrivains C directs de NF/ZF/CF/VF en dehors du frontend TCG
(`grep -rln "env->NF\|env->ZF\|env->CF\|env->VF"`) : **tous les lecteurs multi-champs (les 4
flags ensemble) passent par `pstate_read()`/`pstate_write()`** (`target/arm/cpu.h:1505-1524`).
Modifier UNE FOIS ce choke point suffit a couvrir tous les appelants sans les toucher :

```c
static inline uint32_t pstate_read(CPUARMState *env)
{
    int ZF;
    arm_cc_materialize(env);   /* nouvelle ligne : no-op si deja CC_OP_FLAGS */
    ZF = (env->ZF == 0);
    return (env->NF & 0x80000000) | (ZF << 30)
        | (env->CF << 29) | ((env->VF & 0x80000000) >> 3)
        | env->pstate | env->daif | (env->btype << 10);
}

static inline void pstate_write(CPUARMState *env, uint32_t val)
{
    env->ZF = (~val) & PSTATE_Z;
    env->NF = val;
    env->CF = (val >> 29) & 1;
    env->VF = (val << 3) & 0x80000000;
    env->cc_op = CC_OP_FLAGS;   /* nouvelle ligne : ecrasement total, materialisation figee */
    ...
}
```

`arm_cc_materialize(env)` est la version C pure (pas de TCG) de la meme logique que le helper
de la section 3, reutilisable des deux cotes (un seul corps de formule, DRY) : un petit switch
sur `env->cc_op` sans passer par `tcg_env`/generation de code, appelable depuis n'importe quel
contexte C (elle EST ce que `HELPER(compute_nzcv)` appelle en interne).

Ce choix rend inutile toute instrumentation individuelle de : `linux-user/aarch64/signal.c`
(lignes 149 lecture au montage de la pile de signal, 273 ecriture au retour de signal, LE
chemin critique pour les cas vicieux d'exception), `linux-user/elfload.c:712` (core dump
`NT_PRSTATUS`), `target/arm/gdbstub64.c` (registre `g`/`G`/`P`, actif seulement avec `-g`),
`target/arm/cpu.c:1228` (`-d cpu` logging). Tous appellent deja `pstate_read`/`pstate_write`,
tous heritent de la correction gratuitement.

**Pourquoi c'est sur meme en cas d'interruption asynchrone/synchrone entre TB ou au milieu
d'une sequence lazy** : `env->cc_op`, `cc_src1`, `cc_src2` sont des champs `CPUARMState`
ordinaires, ecrits ATOMIQUEMENT (au sens "dans le meme TCG basic block, avec les operandes")
par la meme instruction qui les definit. Un signal synchrone (SIGSEGV sur un load fautif) ou
asynchrone (SIGINT) interrompt l'execution a une frontiere d'instruction ; `cc_op`/`cc_src1`/
`cc_src2` refletent alors exactement "l'etat des flags apres la derniere instruction qui les a
definis", ce qui est EXACTEMENT la semantique de NF/ZF/CF/VF eager qu'ils remplacent. Aucune
fenetre d'incoherence : c'est le meme argument qui rend le design `cc_op` de x86
(`target/i386/cpu.h:2557`, `cpu_cc_compute_all`) correct depuis des annees.

### 4.5 Code mort confirme (hors perimetre, NE PAS toucher)

- `target/arm/tcg/translate.c` (frontend A32/T32, `gen_add_CC`/`gen_sub_CC`/etc. propres, plus
  `arm_test_cc`/`arm_gen_test_cc` partages) : compile dans le binaire `aarch64-linux-user`
  (`arm_ss` commun, `target/arm/tcg/meson.build` ligne 22-28) mais JAMAIS execute : le binaire
  `qemu-aarch64` ne traduit que de l'A64, aucune voie d'entree vers le dispatch A32/T32 en
  linux-user. Les defines A32 propres a translate.c (distincts des fonctions A64 de la section
  4.1) ne touchent jamais `cpu_cc_op` : aucun risque, mais ne pas les instrumenter (inutile).
- `target/arm/tcg/op_helper.c` lignes 1155-1205 (`helper_shl_cc` et consorts, shifter carry-out
  A32) : meme raison, mort en linux-user.
- `target/arm/tcg/helper-a64.c`, ERET/`illegal_return` (lignes ~828-916, y compris les
  `pstate_read`/`pstate_write` internes lignes 854/908/909) : `trans_ERET`/`trans_ERETA`
  (translate-a64.c lignes 1705/1731) rejettent explicitement `s->current_el == 0`, TOUJOURS
  vrai en linux-user (EL0 systematique) -> `gen_helper_exception_return` n'est JAMAIS emis,
  code mort confirme par lecture, pas seulement suppose.
- `target/arm/machine.c`, `kvm.c`, `hvf.c` : fichiers systeme/accelerateur, non compiles pour
  `--target-list=aarch64-linux-user` (build.sh).

## 5. Strategie du flag `QEMU_NZCV_LAZY`

Meme convention que `QEMU_KEEP_BTI`/`QEMU_KEEP_SVE`/`QEMU_KEEP_LSE2` (`target/arm/cpu.c`
lignes 2111-2139) : lu UNE FOIS via `getenv("QEMU_NZCV_LAZY")`, mis en cache dans un bool
statique (pas de re-lecture par TB). Contrairement a ces trois flags (qui modifient l'ISAR
expose au guest, donc lus a la realisation du CPU), `QEMU_NZCV_LAZY` conditionne des choix de
TRADUCTION (`gen_sub_CC`, `arm_test_cc`, `gen_compute_nzcv`) : la fonction d'acces
`arm_nzcv_lazy_enabled()` vit dans `target/arm/tcg/translate.c` (visible de translate-a64.c),
initialisee paresseusement au premier appel ou explicitement dans `arm_translate_init()`.

Defaut OFF (variable absente) : chaque site d'insertion (section 4) se reduit a un `if
(!arm_nzcv_lazy_enabled()) return;` immediat, zero instruction TCG emise, zero branche prise
au runtime differente d'aujourd'hui. C'est ce qui rend le test de non-regression du L1G
(torn64 flag OFF) valide comme preuve de "comportement publie strictement inchange".

## 6. Plan de test, cas vicieux

Chaque cas ci-dessous doit avoir un test C dedie (guest statique aarch64, meme style que
`test/torn64.c`/`test/smc-alias.c`) ou un scenario documente pour le lot L1G ; certains sont
deja couverts par le harnais existant (torn64, simd-dup2, smc-alias, claude --version), les
autres sont NOUVEAUX et a ecrire au lot L1 (pas L0, mais lister ici pour que L1 sache quoi
prouver).

1. **CCMP immediatement apres SUBS 64-bit** (le cas le plus important, section 4.2 point 2) :
   `SUBS X0, X1, X2` suivi de `CCMP X3, X4, #nzcv, cond` dans le MEME bloc. Verifie
   l'insertion de `gen_compute_nzcv()` ENTRE `gen_sub_CC` et le bloc de fusion bit-a-bit
   (lignes 8046-8062). Sans elle : la fusion lit des `cpu_NF/CF/ZF/VF` perimes (le SUBS
   precedent n'a jamais materialise). Test attendu : le resultat de CCMP (utilise par un
   B.cond juste apres) doit etre identique flag ON et flag OFF pour toutes les combinaisons
   de `cond`/`op`/`#nzcv` couvrant au moins EQ/NE/GE/LT/HI/LS.
2. **MRS NZCV apres SUBS 64-bit** : `SUBS X0, X1, X2` puis `MRS X3, NZCV`. Verifie
   `gen_get_nzcv`. Comparer X3 flag ON vs flag OFF, pour des operandes couvrant les 4 bits
   (resultat nul, negatif, avec/sans retenue, avec/sans overflow signe).
3. **B.cond enchaines apres SUBS 64-bit**, plusieurs branchements conditionnels consecutifs
   SANS nouvelle definition entre eux (`SUBS X0,X1,X2 ; B.EQ L1 ; L1: B.LT L2 ; ...`) : verifie
   que le premier `arm_test_cc` materialise bien (pose `CC_OP_FLAGS`), et que les lectures
   SUIVANTES (deja materialisees) restent correctes ET bon marche (idempotence du helper,
   section 3). Couvre aussi CSEL enchaines (meme mecanisme via `a64_test_cc`).
4. **MSR NZCV puis lecture** : ecrit un NZCV arbitraire via `MSR NZCV, Xt` juste apres une
   `SUBS` 64-bit restee lazy, puis lit via `MRS NZCV` ou teste par B.cond. Verifie que
   `gen_set_nzcv` repose bien `CC_OP_FLAGS` (sinon le futur `gen_compute_nzcv()` ECRASERAIT le
   MSR avec un recalcul perime a partir de l'ancien `cc_src1/cc_src2` de la SUBS anterieure :
   cas vicieux CRITIQUE, silencieusement faux sans le reset explicite de la section 4.1).
5. **Exception/signal au milieu d'une sequence lazy** : provoquer un SIGSEGV (deref pointeur
   invalide) ou un SIGILL immediatement apres une `SUBS` 64-bit restee non lue (`CC_OP_SUB64`
   pendant au moment du fault). Le gestionnaire de signal du process de test lit
   `ucontext->uc_mcontext.pstate` (ce que remplit `target_setup_general_frame` via
   `pstate_read`, linux-user/aarch64/signal.c:149) et doit voir les flags CORRECTS de la SUBS,
   pas des valeurs perimees ou un crash de qemu. Nouveau guest de test dedie (pas couvert par
   torn64/smc-alias) : ecrire un petit `test/nzcv-signal.c` au lot L1 qui installe un handler
   SIGSEGV, execute `SUBS` (via asm inline ou un pattern C qui force le compilateur a emettre
   la sequence), deref un pointeur NULL, et verifie le NZCV recu dans le sigcontext contre la
   valeur attendue calculee en C standard.
6. **RNDR entre une SUBS lazy et sa lecture** (si `-cpu` expose FEAT_RNG, sinon documenter
   comme non applicable a la cible `-cpu cortex-a53`/`max` du harnais actuel) : `SUBS`, puis
   `MRS Xt, RNDR`, puis `MRS Xt2, NZCV`. Verifie la regle de surete generique de la section
   4.3 (le NZCV lu doit etre celui pose par RNDR, PAS un recalcul de la SUBS anterieure).
   Prioriser seulement si le CPU du harnais expose bien RNDR ; sinon noter "non teste, regle
   de surete generique appliquee par construction" au Journal du L1G.
7. **Non-regression flag OFF** : `torn64` court (deja dans le harnais, `test/run-pad.sh torn64
   4 30` sans `QEMU_NZCV_LAZY`) doit produire un binaire dont le comportement d'execution
   (nombre d'iterations pour un temps donne, a 5-10% pres, aucune exigence de vitesse stricte)
   et la CORRECTNESS (0 dechirure) sont inchanges par rapport au parent `yumi-64on32` avant ce
   chantier. Preuve exigee au L1G : un run flag OFF cote a cote avec un run pre-chantier.

Les cas 1, 2, 4 sont directement testables par un petit guest `test/nzcv-lazy-cases.c`
(sequences asm inline, comparaison de resultat via `printf`/`abort`, meme esprit que
`test/torn64.c`) execute SANS besoin du pad (correctness pure, reproductible dans l'env
imbrique Mac comme dans REPRO.md, puisqu'aucune mesure de temps n'est en jeu ici). Le cas 5
(signal) et le cas 3 (enchainement, pour la robustesse sous charge reelle) sont a valider sur
pad avec le harnais existant (torn64/simd-dup2/smc-alias/claude --version, deja lot L1G) PLUS
ce nouveau guest de cas vicieux, execute AVEC `QEMU_NZCV_LAZY=1`.

## 7. Delta v2, cc_op statique dans DisasContext (lot L1B-D, apres gate L4A rouge)

Ecrit apres le verdict L4A (PROGRESS.md, phase L) : la v1 ci-dessus (sections 1 a 6) reste
l'infrastructure de base et N'EST PAS remise en cause (enum `ARMCCOp`, champs `CPUARMState`,
globals TCG `cpu_cc_op/cc_src1/cc_src2`, squelette du helper, inventaire des sites, guest
`nzcv-lazy-cases`, tous les cas vicieux 6.1 a 6.7 restent valides tels quels et n'ont PAS
besoin d'etre rederives). Le seul defaut identifie est local a `gen_compute_nzcv()`
(`target/arm/tcg/translate.c:671`, section 3) : sous flag ON elle emet un appel helper
`gen_helper_compute_nzcv` INCONDITIONNEL a CHAQUE site de lecture traduit, meme quand
`cc_op == CC_OP_FLAGS` au runtime (rien a materialiser). Le profiler de reconnaissance
(section 4.2) comptait en plus les VISITES du wrapper de traduction, identiques ON et OFF,
donc aveugle au mecanisme (verdict L4A, cf. PROGRESS.md lignes 348-359). La v2 remplace
cette seule fonction et ses points d'appel par un suivi COMPILE-TIME du cc_op, exactement le
schema `s->cc_op` de `target/i386/tcg/translate.c` (`cc_op` dans `DisasContext`, valeur
`CC_OP_DYNAMIC` reservee au cas inconnu). Rien d'autre ne change : meme enum runtime
(etendue), memes globals, meme formule de calcul, memes 4 flags materialises ensemble a
chaque materialisation (pas de granularite par bit, hors perimetre v2).

Toutes les references de ligne ci-dessous pointent sur `qemu/` branche `nzcv-lazy`, commit
`33bb85d` (HEAD au moment de cet audit) ; a revalider par grep avant le lot L1B, comme pour
la section 0.

### 7.1 cc_op statique dans DisasContext

Ajout `target/arm/cpu.h:213-217` (etend l'enum runtime existant, ne le remplace pas) :

```c
typedef enum {
    CC_OP_FLAGS = 0,   /* NF/ZF/CF/VF valid; cc_src1/cc_src2 unused */
    CC_OP_SUB64,       /* flags derivable from (cc_src1 - cc_src2), 64-bit */
    CC_OP_DYNAMIC,     /* translate-time only: cc_op at TB entry is unknown at
                           compile time, must be resolved by a runtime helper.
                           NEVER stored into env->cc_op (assert-checked). */
    CC_OP_NB,
} ARMCCOp;
```

`CC_OP_DYNAMIC` fait partie du meme type `ARMCCOp` (comme dans i386, `CC_OP_DYNAMIC` cotoie
les valeurs runtime dans `CCOp` tout en n'etant jamais ecrit dans `env->cc_op`) mais
n'apparait QUE comme valeur de `DisasContext.cc_op`, jamais dans `CPUARMState.cc_op`.
Defense : `arm_cc_materialize()` (`cpu.h:1531`) et `HELPER(compute_nzcv)`
(`op_helper.c:304`) gagnent un `tcg_debug_assert(env->cc_op != CC_OP_DYNAMIC)` en tete, sous
`CONFIG_DEBUG_TCG` ou equivalent leger (cout nul en build release).

Ajout `target/arm/tcg/translate.h`, dans `DisasContext` (apres le bloc `bool aarch64; bool
thumb; bool lse2;` existant, translate.h:~156) :

```c
uint32_t cc_op;   /* ARMCCOp, valide seulement si QEMU_NZCV_LAZY : cc_op connu
                      statiquement a CE point de la traduction du TB courant. */
```

Init dans `aarch64_tr_init_disas_context()` (translate-a64.c:11730, apres `dc->lse2 = ...`
ligne 11796) :

```c
dc->cc_op = CC_OP_DYNAMIC;
```

Toujours DYNAMIC en entree de TB : AUCUNE propagation inter-TB (meme simplification
volontaire que le L0 v1, section 2, juste reconduite explicitement ici). Ce n'est pas une
regression de precision par rapport a v1 (v1 n'avait aucun suivi du tout, donc appelait
TOUJOURS le helper) : DYNAMIC en entree de TB degrade au pire au comportement v1 pour LA
PREMIERE lecture du TB, puis devient gratuit pour toutes les suivantes (section 7.2).
Propager le cc_op connu d'un TB au suivant (via un cache indexe par PC, ou en integrant
cc_op aux TB flags pour eviter la retraduction) est une piste v3 explicitement HORS
perimetre (comme la propagation inter-instructions l'etait deja pour L2 dans le L0).

### 7.2 Regles d'emission aux lectures

`gen_compute_nzcv()` (translate.c:671) change de signature pour recevoir le `DisasContext *`
et devient un dispatcher sur `s->cc_op` au lieu d'un appel helper inconditionnel :

```c
void gen_compute_nzcv(DisasContext *s)
{
    if (!arm_nzcv_lazy_enabled()) {
        return;                              /* flag OFF : inchange, zero cout */
    }
    switch (s->cc_op) {
    case CC_OP_FLAGS:
        return;                              /* connu materialise : RIEN emis */
    case CC_OP_SUB64:
        gen_materialize_sub64_flags(cpu_cc_src1, cpu_cc_src2);  /* inline TCG, zero call */
        tcg_tb_prof_note_nzcv_read();        /* compte une VRAIE materialisation (7.4) */
        break;
    default:                                 /* CC_OP_DYNAMIC */
        gen_helper_compute_nzcv(tcg_env);    /* seul point d'appel restant du schema */
        break;
    }
    s->cc_op = CC_OP_FLAGS;                  /* cache le resultat pour le reste du TB */
}
```

`gen_materialize_sub64_flags(TCGv_i64 t0, TCGv_i64 t1)` est une NOUVELLE fonction statique
extraite du corps actuel de la branche eager de `gen_sub64_CC` (translate-a64.c:870-884,
`result/flag/tmp` + les 4 `tcg_gen_*` qui remplissent `cpu_NF/ZF/CF/VF`) : reutilisee TELLE
QUELLE a la fois par `gen_sub64_CC` (appelee avec les operandes reels de la soustraction) et
par le nouveau chemin de lecture ci-dessus (appelee avec `cpu_cc_src1, cpu_cc_src2`, les
globals ou l'ancienne soustraction a laisse ses operandes). Une seule formule TCG au lieu de
deux copies : le meme principe DRY qui justifiait deja `arm_cc_materialize()` cote C (section
3 v1) s'applique maintenant aussi cote emission TCG. Le corps C de `arm_cc_materialize()` et
`HELPER(compute_nzcv)` restent INCHANGES (ils gardent leur propre formule, deja prouvee
identique par la note de la section 3 v1 ; DRY inter-langage TCG/C n'est pas atteignable
proprement, pas cherche).

`gen_cc_op_flags()` (translate.c:679) gagne le meme parametre et, en plus d'emettre
`tcg_gen_movi_i32(cpu_cc_op, CC_OP_FLAGS)`, met a jour `s->cc_op = CC_OP_FLAGS` (le renommer
`gen_set_cc_op_flags(DisasContext *s)` au passage clarifie qu'elle a un effet de bord
compile-time en plus de l'effet TCG runtime). `gen_sub64_CC` (via `gen_sub_CC`) gagne le
meme parametre et pose `s->cc_op = CC_OP_SUB64` explicitement dans sa branche lazy (au lieu
d'appeler `gen_set_cc_op_flags`).

Consequence mecanique (a verifier par grep exhaustif au L1B, pas a l'aveugle sur les numeros
de ligne) : TOUTE fonction qui definit ou lit NZCV gagne un parametre `DisasContext *s` si
elle ne l'a pas deja, pour pouvoir lire/ecrire `s->cc_op` :

| Fonction | A deja `s` ? | Delta v2 |
|---|---|---|
| `disas_cc` (CCMP, ~8037) | oui (parametre direct) | passe `s` a `gen_sub_CC`/`gen_add_CC`/`gen_compute_nzcv` |
| `handle_sys` (~2288) | oui | passe `s` a `gen_get_nzcv`/`gen_set_nzcv` |
| `arm_test_cc` (translate.c:687) | NON, signature `(DisasCompare*, int)` | ajouter `DisasContext *s` en 1er parametre ; 4 appelants A64 (translate-a64.c:437,1552,8063,8917 via `arm_gen_test_cc`) ont deja `s`/`dc` en portee locale, 2 appelants A32 morts (translate.c:3538,7347) idem |
| `arm_gen_test_cc` (translate.c:776) | NON | idem, wrapper direct de `arm_test_cc` |
| `gen_sub_CC`/`gen_sub64_CC`/`gen_sub32_CC` (~906,851,887) | NON | ajouter `s` ; PIEGE (voir note ci-dessous) |
| `gen_add_CC`/`gen_add64_CC`/`gen_add32_CC` (~839,800,822) | NON | idem, ecrit seulement `s->cc_op = CC_OP_FLAGS` (jamais lazy pour ADD) ; meme piege |
| `gen_logic_CC` (~785) | NON | idem |
| `gen_adc`/`gen_adc_CC` (~918,932) | NON | idem ; `gen_adc` (pas `_CC`) appelle deja `gen_compute_nzcv()` pour consommer la retenue entrante (ligne 921), devient `gen_compute_nzcv(s)` |
| `gen_get_nzcv`/`gen_set_nzcv` (~2240,2262) | NON | ajouter `s`, seul appelant `handle_sys` l'a deja |

`handle_sys`, cas RNDR generique (section 4.3 v1, regle de surete "poser `CC_OP_FLAGS` apres
tout `readfn` de cpreg") : devient `s->cc_op = CC_OP_FLAGS` en plus du `tcg_gen_movi_i32`
existant, meme regle, zero changement de perimetre.

**PIEGE decouvert en auditant les appelants (translate-a64.c:4363-4403, `gen_rri`), absent
de l'inventaire L0 v1 : `gen_sub64_CC`/`gen_sub32_CC`/`gen_add64_CC`/`gen_add32_CC` sont
appelees de DEUX facons distinctes**, pas juste via `gen_sub_CC`/`gen_add_CC` :

- forme registre-registre (SUBS/ADDS a registre) : via `gen_sub_CC`/`gen_add_CC`
  (`s` disponible, cf. tableau) ;
- forme immediate (`SUBS_i`/`ADDS_i`, translate-a64.c:4402-4403) : `TRANS(SUBS_i, gen_rri, a,
  0, 1, a->sf ? gen_sub64_CC : gen_sub32_CC)` passe `gen_sub64_CC` en POINTEUR DE FONCTION a
  `gen_rri` (typedef `ArithTwoOp`, translate-a64.c:4361, signature `(TCGv_i64, TCGv_i64,
  TCGv_i64)`, SANS `DisasContext*`), qui l'appelle directement (`fn(tcg_rd, tcg_rn,
  tcg_imm)`, ligne 4370) SANS PASSER PAR `gen_sub_CC` NI PAR AUCUN WRAPPER.
  Consequence deja vraie en v1, jamais remarquee : `tcg_tb_prof_note_nzcv_def()`, place dans
  le wrapper `gen_sub_CC`/`gen_add_CC`, NE COMPTE JAMAIS les SUBS/ADDS IMMEDIATS (ecart de
  reconnaissance non signale, independant du defaut de mecanisme du verdict L4A). En placant
  en v2 le compteur DANS `gen_sub64_CC`/`gen_add64_CC` elles-memes (7.4) plutot que dans le
  wrapper, ce trou se referme de lui-meme, gratuitement.
- Consequence sur la signature : `ArithTwoOp` doit gagner `DisasContext *s` en 1er parametre
  (`typedef void ArithTwoOp(DisasContext *s, TCGv_i64, TCGv_i64, TCGv_i64);`), et l'appel
  `fn(tcg_rd, tcg_rn, tcg_imm)` de `gen_rri` (ligne 4370) devient `fn(s, tcg_rd, tcg_rn,
  tcg_imm)` (`s` deja en portee, 1er parametre de `gen_rri`). Les deux AUTRES utilisateurs de
  `ArithTwoOp`, `TRANS(ADD_i, gen_rri, a, 1, 1, tcg_gen_add_i64)` et `TRANS(SUB_i, ...,
  tcg_gen_sub_i64)` (translate-a64.c:4399-4400, formes SANS mise a jour des flags), ne
  correspondent plus au type etendu : ajouter deux adaptateurs triviaux (`static void
  gen_add_i64_noflags(DisasContext *s, TCGv_i64 d, TCGv_i64 a, TCGv_i64 b) { tcg_gen_add_i64
  (d, a, b); }` et l'equivalent SUB) plutot que de sortir ADD_i/SUB_i du mecanisme `gen_rri`
  commun.

### 7.3 Invariants de sortie de TB

Choix : **ne rien materialiser explicitement a la sortie de TB**. `cpu_cc_op`, `cpu_cc_src1`,
`cpu_cc_src2` restent des globals TCG (section 2 v1, INCHANGE en v2) : le framework TCG les
synchronise deja vers `CPUARMState` a CHAQUE point de sortie du TB (`goto_tb`, exception,
`lookup_and_goto_ptr`), exactement le meme mecanisme QUI DEJA GARANTIT AUJOURD'HUI que
`cpu_NF/ZF/CF/VF` (et `cpu_PC`) sont a jour en memoire des la fin de la traduction d'une
instruction, sans code manuel. Si un TB se termine avec `s->cc_op == CC_OP_SUB64` jamais lu
(le cas majoritaire, 63 % mesure en reconnaissance), `env->cc_op` vaut `CC_OP_SUB64` en
sortie ; le TB SUIVANT (quel qu'il soit) demarre avec `s->cc_op = CC_OP_DYNAMIC` (7.1) et ne
materialise QUE s'il lit reellement (7.2). C'est le mecanisme normal, pas un cas particulier
a gerer.

Justification du rejet de l'alternative ("materialiser avant chaque `exit_tb`") : cela
annulerait le gisement mesure en reconnaissance (2,74 defs/reads, ~63 % jamais lus) en
forcant un cout de materialisation a la fin de PRESQUE CHAQUE TB qui contient une SUBS
64-bit, que le resultat soit lu ou non par la suite. C'est structurellement la MEME regression
que celle qui a tue la v1 (un cout paye systematiquement au lieu de a la demande), transposee
de "chaque lecture" a "chaque sortie de TB" : pas d'amelioration attendue, potentiellement pire
sur les TB courts et frequents (le TB chaud de reconnaissance, `hot-tbs-llint.dump`, est
precisement un SUB/CMP suivi d'un branchement RARE).

Surete deja etablie, pas a rederiver (section 4.4 v1, argument recyclable tel quel) : un
signal (synchrone ou asynchrone) ou une exception au milieu d'une sequence lazy, MEME a
travers plusieurs frontieres de TB, voit un `env->cc_op`/`cc_src1`/`cc_src2` coherent avec
"l'etat des flags apres la derniere instruction qui les a definis" (ecrit par l'instruction
qui definit, pas differe a la sortie du TB), et `pstate_read`/`pstate_write` materialisent a
la demande via `arm_cc_materialize()`. La v2 ne change NI le moment ou `cpu_cc_op`/
`cc_src1`/`cc_src2` sont ecrits (toujours au point de definition, section 7.2 inchangee sur
ce point par rapport a la v1 section 4.1) NI leur nature de globals TCG synchronisees : les 7
cas vicieux de la section 6 (v1) restent valides sans modification, seul le jeu de tests doit
etre REJOUE (pas reecrit) contre le binaire v2 au lot L1BG.

### 7.4 Correction du profiler

Diagnostic L4A (PROGRESS.md, verdict L4A) : `tcg_tb_prof_note_nzcv_def()` est appele dans les
WRAPPERS partages (`gen_sub_CC` ligne 908, `gen_add_CC` ligne 841, `gen_logic_CC` ligne 787,
`gen_adc_CC` ligne 934), donc une fois par site de traduction visite, IDENTIQUE que le flag
soit ON ou OFF (le wrapper est toujours appele, seul ce qu'il fait ensuite differe). Meme
defaut cote lecture : `tcg_tb_prof_note_nzcv_read()` (translate-a64.c:436, 2245, 8062) compte
la visite du site de lecture, pas si une materialisation a reellement eu lieu.

Correction, deux mecanismes distincts selon que l'evenement est connu au moment de la
traduction ou seulement au runtime :

1. **Defs (mecanisme translation-time inchange, RELOCALISE)** : `tcg_tb_prof_note_nzcv_def()`
   deplace des wrappers vers les branches qui materialisent REELLEMENT (celles qui restent
   inconditionnelles au flag) : corps de `gen_add64_CC`/`gen_add32_CC`, branche eager de
   `gen_logic_CC`, `gen_sub32_CC`, section d'ecriture des flags de `gen_adc_CC`,
   `gen_set_nzcv`, ET la branche EAGER (flag OFF) de `gen_sub64_CC` uniquement (jamais sa
   branche lazy). Sous flag ON, la contribution SUB64 disparait du total des defs ; sous
   flag OFF, rien ne change (identique a aujourd'hui). C'est directement la preuve de
   mecanisme cote definition, sans nouvelle infrastructure : le total "defs" doit baisser
   visiblement ON vs OFF, proportionnellement au poids des SUBS64 dans le mix d'instructions.
2. **Reads compile-time-connues (translation-time inchange, RELOCALISE)** :
   `tcg_tb_prof_note_nzcv_read()` deplace vers la branche `CC_OP_SUB64` de
   `gen_compute_nzcv()` (7.2) uniquement : compte une lecture SEULEMENT quand elle declenche
   reellement l'emission de `gen_materialize_sub64_flags`. La branche `CC_OP_FLAGS` (rien
   emis) ne compte plus rien : c'est exactement la correction que le verdict L4A demandait
   ("compter les MATERIALISATIONS effectives... pas les visites de wrapper").
3. **Reads dynamiques (NOUVEAU mecanisme runtime, pas de weighting)** : la branche
   `CC_OP_DYNAMIC` ne peut PAS etre comptee a la traduction (le meme site traduit une seule
   fois est visite par une infinite d'executions dont certaines trouveront `env->cc_op` deja
   `CC_OP_FLAGS` a runtime, d'autres non ; c'est une info dynamique, pas statique). Nouvelle
   fonction `tcg_tb_prof_note_nzcv_dynamic_materialize(void)` (`tcg/tcg.c`, meme fichier que
   les deux compteurs existants, meme style `__thread`), appelee DEPUIS `HELPER(compute_nzcv)`
   (op_helper.c:304) et `arm_cc_materialize()` (cpu.h:1531) mais SEULEMENT dans la branche qui
   fait le travail reel (apres le test `if (env->cc_op == CC_OP_FLAGS) return;`), donc a
   l'interieur du corps du helper comme l'exige le verdict L4A ("+ corps du helper"). Ce
   compteur est deja un total EXACT par construction (incremente au runtime, une fois par
   materialisation reelle) : PAS de multiplication par le compte d'execution du TB (a la
   difference des deux compteurs precedents), agrege directement dans un total cumulatif
   separe.
4. **Rapport final** (`tcg/tcg.c:~490-505`, fonction qui imprime `"NZCV (execution
   weighted)"`) : ajoute une troisieme ligne "NZCV (materialisations reelles)", somme des
   trois compteurs : (1, defs relocalises, pondere) + (2, reads SUB64-connus, pondere) +
   (3, reads dynamiques, exact). L'interpretation attendue au L4C : cette somme doit CHUTER
   nettement flag ON vs OFF (contrairement au v1 ou "defs" et "reads" restaient identiques a
   0,04 % pres, cf. verdict L4A) puisque la majorite des SUB64 jamais lues ne contribuent plus
   ni a (1) ni a (2) ni a (3).

### 7.5 Risques et perimetre L1B

- Le refactor de signature (7.2, tableau) touche ~10 fonctions et leurs appelants dans
  `target/arm/tcg/translate.c` et `translate-a64.c` : mecanique mais large. Un commit atomique
  PAR FAMILLE (comme L2 le prevoyait deja pour l'extension), pas un seul gros commit, pour
  garder les revues et un eventuel revert cibles.
- Flag OFF : chaque site continue de faire EXACTEMENT ce qu'il fait aujourd'hui (aucune des
  nouvelles branches n'est atteinte, `arm_nzcv_lazy_enabled()` reste le premier test partout
  ou c'est pertinent). Le non-regression flag OFF de L1BG reste la preuve de cette invariance,
  inchangee dans sa methode par rapport a L1G.
- `gen_materialize_sub64_flags` dupliquerait un bug si sa formule divergeait de
  `arm_cc_materialize()` (formule C) : les deux DOIVENT rester en synchronisation manuelle
  (pas de source unique possible entre TCG-emission et C pur), comme deja note pour
  `gen_sub64_CC` vs `arm_cc_materialize()` en v1 (section 3). Le test `nzcv-lazy-cases`
  (cas 1/2/4 de la section 6) couvre deja cette divergence potentielle : a rejouer au L1BG,
  pas a re-ecrire.
- Reutiliser l'infra v1 telle quelle : enum de base, champs `CPUARMState`, globals TCG,
  squelette du helper `HELPER(compute_nzcv)`/`arm_cc_materialize`, guest
  `test/nzcv-lazy-cases.c`. Seuls `gen_compute_nzcv`, `gen_cc_op_flags` et les signatures du
  tableau 7.2 changent ; le reste de L1 (section 4.1, 4.3, 4.4) reste la base factuelle.
