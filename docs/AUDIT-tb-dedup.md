# AUDIT-tb-dedup, recon de faisabilite V4-0 (dedup des templates JIT par contenu)

Objet : trancher le GATE V4-0 (parties b et c) avant toute chirurgie. La partie a (taux de
dedup NET) est deja mesuree et franchie (69,8 %, cf. Journal V4-0 recon et
`test/logs/v4-dedup/`). Ce document couvre la partie b (AUDIT SOURCE des dependances du code
hote emis a l'adresse invitee) et la partie c (estimation chiffree du cout d'installation d'un
hit face au cout d'une traduction froide), puis prononce le gate.

Toutes les references de lignes pointent le clone `qemu/` (v9.2.4, branche `tb-dedup`).

## Rappel du mecanisme vise

Re-indexer les TB par HACHAGE DU CONTENU des octets invites (cle `net` = octets source +
flags/cflags/cs_base, insensible au PC) plutot que par adresse, pour qu'un template emis des
milliers de fois a des adresses differentes par le JIT invite devienne un HIT (installation
d'une copie relocaliseee) au lieu d'une retraduction complete.

## Partie b, AUDIT SOURCE : ce que le code hote emis encode de l'adresse invitee

Point de depart decisif : **`CF_PCREL` n'est PAS arme en user-mode**. Il n'est pose que dans
`arm_cpu_realizefn` sous `!CONFIG_USER_ONLY` (`target/arm/cpu.c:1983-1986`), et aucun chemin
linux-user ne le pose (grep `CF_PCREL` dans `linux-user/`, `bsd-user/`, `accel/tcg/user-exec*`
: zero occurrence). Consequence directe : le frontend aarch64 materialise l'adresse invitee en
ABSOLU dans le code hote, pas en relatif a `cpu_pc`.

### b.1, adresse invitee absolue baked dans le code hote (le point dur)

`gen_pc_plus_diff` (`target/arm/tcg/translate-a64.c:174-182`) :
```
if (tb_cflags(s->base.tb) & CF_PCREL) {
    tcg_gen_addi_i64(dest, cpu_pc, (s->pc_curr - s->pc_save) + diff);  // relatif (system)
} else {
    tcg_gen_movi_i64(dest, s->pc_curr + diff);                          // ABSOLU (user)  <-- notre cas
}
```
En user-mode, chaque materialisation de PC invite est une constante 64 bits absolue. Sites
appelants dans le frontend a64 : 28 appels a `gen_a64_update_pc` / `gen_pc_plus_diff`
(grep, `translate-a64.c`), couvrant : sortie de TB hors goto_tb (`gen_a64_update_pc` avant
`tcg_gen_exit_tb`, l.508-517), lien de retour BL/BLR (`gen_pc_plus_diff(s, cpu_reg(s,30),
curr_insn_len(s))`, l.1578/1644), ADR/ADRP (l.1546 et voisins). Une constante 64 bits est
abaissee cote hote armv7 en DEUX mots (lo/hi), chacun via `tcg_out_movi32`
(`tcg/arm/tcg-target.c.inc:784`).

CORRECTION 2026-07-23 (mesure de terrain, pas litterature) : un premier jet de cet audit
supposait que ces mots tombaient en literal pool (`R_ARM_PC13`). Le dump hote reel
(`test/logs/dump-tb/hot-tbs-llint.dump`) le REFUTE pour armv7. La forme dominante d'une
constante 32 bits non encodable en immediat rotatif y est la paire **movw/movt** IN-STREAM :

    0xa6ac3e8c:  e30c4678  movw  r4, #0xc678   ; PC invite bas
    0xa6ac3e90:  e3404194  movt  r4, #0x194    ; PC invite haut  (=> 0x0194c678)

La valeur vit DANS les mots d'instruction (imm4 en [19:16] + imm12 en [11:0]), pas dans une
region de pool separee. Consequence pour l'installateur : un memcpy du template emporte la
valeur avec lui, et le patch se fait EN PLACE sur les deux champs imm16 de la paire (pas de
pool a relocaliser). Le codec partage `tb_dedup_movw_set/get_imm16` + `tb_dedup_patch_pair`
(include/exec/tb-dedup.h) est l'unique source de verite de ce patch, epinglee par
`test/tb-dedup-key.c` contre les mots verbatim du dump. Le literal pool
(`tcg_out_movi_pool`, l.777-782) n'est qu'un FALLBACK residuel (valeur ni immediat rotatif,
ni movw/movt sur un hote non-armv7) : hors perimetre de la cible armv7, a ignorer.

Le PC invite d'un guest user aarch64 tient sur 32 bits (l'espace user est sous 4 Go dans ces
workloads) : le mot HAUT de la constante 64 bits s'abaisse en un `mov #0` trivial, rien a
patcher, seul le mot bas (la paire movw/movt) porte une reloc.

Deux TB a octets source identiques mais a PC invite different produisent donc un code hote
qui DIFFERE exactement sur ces paires movw/movt. C'est la seule (mais reelle) raison pour
laquelle un hit `net` ne peut pas etre un memcpy nu : il faut PATCHER ces paires a
l'installation.

PIEGE d'encodage a neutraliser cote EMETTEUR (sous-lot emetteur de V4-1, PAS ici) :
`tcg_out_movi32` choisit la forme par la VALEUR, pas par le slot. Une valeur encodable en un
seul MOV/MVN immediat s'abaisse en UN mot, pas deux ; le pointeur de TB proche s'abaisse en
`sub rN, pc, #imm` (cf. b.2). Un patch in-place a deux mots ne peut pas rattraper ces formes
courtes. Quand la dedup est active, ces mots baked doivent donc etre FORCES a la paire
movw+movt de largeur fixe, pour que chaque template offre un slot patchable de deux mots quelle
que soit la valeur.

### b.2, pointeur du TB lui-meme baked par exit_tb (2,33 sites/TB mesures)

`tcg_gen_exit_tb` (`tcg/tcg-op.c:3295-3320`) encode `val = (uintptr_t)tcg_splitwx_to_rx(tb) +
idx`, c.-a-d. le POINTEUR ABSOLU du TB courant, puis `tcg_out_exit_tb`
(`tcg/arm/tcg-target.c.inc:1779-1783`) l'emet via `tcg_out_movi(R0, arg)`. Sur un hit, les
octets reutilises portent le pointeur de l'ANCIEN TB : il faut patcher ce mot vers le pointeur
du NOUVEAU TB. Frequence mesuree en session boot claude JIT-active
(`test/logs/claude-native/op-histogram-boot.txt`) : `exit_tb` 167 474 pour ~71 741 TB, soit
**2,33 sorties/TB** (2 sorties de conditionnelle etant le cas courant).

CORRECTION 2026-07-23 (meme dump reel) : deux formes coexistent pour ce pointeur, et l'une est
un DANGER pour un template relocalisable :

    0xa6ac3ec8:  e3030dc1  movw  r0, #0x3dc1
    0xa6ac3ecc:  e34a06ac  movt  r0, #0xa6ac   ; pointeur TB 0xa6ac3dc1, paire patchable
    ...
    0xa6ac3ea0:  e24f00e8  sub   r0, pc, #0xe8 ; pointeur TB via PC-relatif, DEPEND DU PLACEMENT

La forme `sub r0, pc, #imm` (le TB est juste avant son code, `tcg_out_movi32` l.802-817 prend
le raccourci PC-relatif) encode une DISTANCE au PC hote courant, pas une valeur absolue : un
memcpy du template a une AUTRE adresse hote la laisserait pointer a cote. Elle doit donc, elle
aussi, etre forcee a la paire movw/movt fixe cote emetteur quand la dedup est active (cf. piege
d'encodage en b.1). La forme movw/movt, elle, se patche exactement comme un mot de PC invite
via `tb_dedup_patch_pair`.

### b.3, goto_tb : deja position-independant, RIEN a relocaliser (bonne nouvelle)

`tcg_out_goto_tb` (`tcg/arm/tcg-target.c.inc:1785-1814`) n'ecrit PAS une adresse absolue : il
pose un NOP patchable et charge la cible via `get_jmp_target_addr` = `&s->gen_tb->
jmp_target_addr[which]` (`tcg/tcg.c:792-799`), un SLOT DANS la struct TB. Le patch se fait par
`tb_target_set_jmp_target` (l.1816-1833) a partir de `tb->jmp_target_addr[n]`, pose au lien par
`tb_set_jmp_target` (`accel/tcg/cpu-exec.c:637-651`). A l'installation d'une copie il suffit de
`tb_reset_jump` (deja fait par le patch 0007 du cache persistant,
`patches/0007-*.patch:186-191`). Frequence : `goto_tb` 68 083 = **0,95/TB**, tous gratuits
cote relocation. Le jump-cache (`tb_jmp_cache`, keye sur PC invite) enregistre le hit
normalement : aucun impact.

### b.4, recap des dependances a l'adresse invitee

| source encodee dans le code hote | site | reloc a l'install ? | sites/TB |
| --- | --- | --- | --- |
| PC invite absolu (update_pc, BL/BLR, ADR/ADRP) | frontend a64 (movi_i64, non CF_PCREL) | OUI, patch imm16 de la paire movw/movt (mot bas ; mot haut = mov #0) | variable, borne par les branches/adr du TB |
| pointeur du TB (exit_tb) | `tcg_out_exit_tb` (paire movw/movt, forcee) | OUI, patch imm16 de la paire | 2,33 |
| cible goto_tb | slot `jmp_target_addr` dans le TB | NON, relink (tb_reset_jump) | 0,95 |
| guest_base | prologue, hors TB | NON (identique tout le run) | 0 |

Conclusion partie b : la relocation necessaire est BORNEE et LOCALE (patch in-place des paires
movw/movt de PC invite + pointeur exit_tb, aucune region de pool a deplacer). Elle exige DEUX
choses cote emetteur/traduction que QEMU ne fait pas aujourd'hui : (1) FORCER la paire movw/movt
de largeur fixe pour ces mots quand la dedup est active (sinon `tcg_out_movi32` peut emettre une
forme courte ou PC-relative non patchable, cf. pieges b.1/b.2) ; (2) enregistrer une TABLE de
relocation par template (offset du mot movw de chaque paire + genre), que QEMU JETTE aujourd'hui
apres emission. V4-1 doit livrer les deux a la traduction froide. Le patch lui-meme est deja
factorise et teste : `tb_dedup_patch_pair` (include/exec/tb-dedup.h, epingle par
test/tb-dedup-key.c). Alternative de conception (a trancher en V4-1, PAS ici) : armer `CF_PCREL`
en user-mode rendrait le code hote position-independant vis-a-vis du PC invite (materialisation
relative a `cpu_pc`), reduisant le hit a un quasi-memcpy, mais au prix d'un surcout runtime sur
CHAQUE TB (add au lieu de movi) et d'une revalidation correctness large. A evaluer, ne pas
prejuger.

## Partie c, estimation chiffree du cout d'installation d'un hit

Base de mesure : `docs/PROFILE-HOTSPOTS.md` (perf PMU materiel, ponderation execution, overhead
0,05 %). Decomposition du cout de TRADUCTION FROIDE (bucket translator, en % du total des
cycles hote), workload claude --version JIT-actif clean :

| etape de la traduction froide | part du total hote | skippee par un hit ? |
| --- | --- | --- |
| liveness_pass_1 | 8,44 % | OUI |
| tcg_gen_code (emission des octets) | 5,42 % | OUI (remplacee par memcpy) |
| tcg_optimize | 2,98 % | OUI |
| la_cross_call | 1,47 % | OUI |
| tcg_reg_alloc (+ pair/bb_end) | ~1,5 % | OUI |
| liveness_pass_0 | 0,99 % | OUI |
| temp_load + tcg_out_* divers | ~1,0 % | OUI |
| disas frontend (translator_loop, decode) | inclus translator | OUI |
| **total translator** | **33,5 %** | quasi-integralement skippe |

Cout UNIQUE d'un hit (ce qui reste a payer) :
- `memcpy` des octets hote du template (taille d'un TB, quelques centaines d'octets) : moins
  cher que `tcg_gen_code` qui les GENERE mot par mot (5,42 %). Majorant : 5,42 %.
- patch des relocations : ~2,33 mots exit_tb + les mots de PC invite (poignee par TB), soit
  quelques dizaines d'ecritures de mot. Negligeable devant liveness/optimize. Majorant genereux
  : < 1 %.
- `tb_link_page` + insertion QHT : PAYE AUSSI par la traduction froide (cout partage, s'annule
  dans le rapport install/froid). Contribution nette au rapport : ~0.

Le cout d'installation UNIQUE (memcpy + patch relocs) est donc borne par ~la part de
`tcg_gen_code` seule, tout le reste du bucket translator (28 % du total hote : liveness,
optimize, regalloc, disas) etant purement economise. Rapport install/froid :

    install_unique / cold_total  ~=  (memcpy + relocs) / translator_bucket
                                 <~  (5,4 % + <1 %) / 33,5 %  ~=  19 %

**Estimation : ~15 a 25 % du cout d'une traduction froide, < 30 %.** Le majorant retenu (memcpy
aussi cher que l'emission, relocs genereusement chiffrees) reste sous le seuil ; le cas typique
est plus favorable car un memcpy lineaire est bien moins cher que l'emission op-par-op avec
allocation de registres.

Reserve d'honnetete : ce chiffre est une ESTIMATION de recon fondee sur la decomposition perf
mesuree, PAS une mesure in vivo de l'installateur (qui n'existe pas avant V4-1). La confirmation
reelle est le role de V4-1G (correctness) et surtout V4-2 (WALL-CLOCK, seul juge). Le PIEGE de
la phase reste entier : moins de traductions ne garantit PAS plus vite ; si la dedup marche mais
ne rend pas de secondes en A/B, la voie se ferme comme le cache persistant.

## VERDICT GATE V4-0

- Critere 1, dedup NET >= 15 % : **FRANCHI** (69,8 % mesure, 4,6x le seuil ; source
  `test/logs/v4-dedup/netkey-dedup-20260723.txt`, passage src->net ne perd que 0,1 pt donc pas
  d'artefact de cle courte).
- Critere 2, cout d'installation < 30 % du cout de traduction : **FRANCHI (estimation recon)**,
  ~19 % (borne 15-25 %), car un hit skippe liveness/optimize/regalloc/disas/emission (33,5 % du
  cout hote) et ne paie que memcpy + patch de quelques dizaines de mots.

**GATE V4-0 = GO.** V4-1 est autorise, avec trois exigences d'implementation issues de l'audit
(la 1 corrigee 2026-07-23 apres verification sur dump hote reel) :
1. cote emetteur, FORCER la paire movw/movt de largeur fixe pour les mots de PC invite absolu
   et le pointeur exit_tb quand la dedup est active (sinon `tcg_out_movi32` emet des formes
   courtes/PC-relatives non patchables, cf. pieges b.1/b.2), puis enregistrer a la traduction
   froide une table de relocation (offset du mot movw de chaque paire + genre) que QEMU jette
   aujourd'hui ; le patch a l'installation reutilise `tb_dedup_patch_pair` ;
2. relink goto_tb via `tb_reset_jump` (deja disponible via le patch 0007), aucun octet a
   relocaliser.
Alternative CF_PCREL user-mode a evaluer en V4-1 (position-independance native contre surcout
par TB). Defaut du flag QEMU_TB_DEDUP strictement OFF, identique au publie. Le juge final reste
V4-2 (wall-clock), jamais le compteur de dedup.
