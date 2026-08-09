# Passation : efficacite d'EXECUTION du fork QEMU 64-on-32

Document pour une instance fraiche qui reprend le sujet avec un contexte minimal.
Lis-le en entier avant d'agir. Tout ce qui est note ETABLI est prouve et source :
ne le re-derive pas, ne le re-teste pas, construis dessus.

## La mission, en une phrase

Le PRODUIT est l'emulateur : ce fork de QEMU 9.2.4 est le dernier emulateur
user-mode 64-on-32 vivant (aarch64 sur armv7, supprime upstream en 10.0/11.0),
il est deja CORRECT, et ta mission est de rendre son EXECUTION la plus rapide
possible. Le binaire Claude Code natif (Bun/JSC, 247 Mo) n'est PAS le but :
c'est le banc d'essai le plus brutal qu'on connaisse pour cet emulateur.

## Regle d'or (non negociable)

"C'est structurellement impossible" n'est PAS une conclusion recevable.
Le livrable est une serie d'EXPERIENCES MESUREES : chaque idee se termine par
un chiffre sur le banc de reference, jamais par un raisonnement seul. Si une
idee ne donne rien, le chiffre le dira et tu passes a la suivante. L'histoire
recente de ce repo donne raison a cette regle : le build tournait en -O0
depuis le debut (--enable-debug jamais revisite) et personne ne l'avait vu ;
le cache TB etait fige a 32 MiB et transformait le boot en tempete de
retraductions. Les evidences non regardees existent. Trouve les suivantes.

## ETABLI (prouve, source, ne pas re-deriver)

1. CORRECTNESS acquise : 7 patches sur v9.2.4 (patches/), atomicite 64-bit
   (torn64 ~550 M iterations, 0 dechirure), SIMD dup2_vec, termios2, SMC W^X.
   Details : docs/METHODOLOGY.md.
2. Cache TB 32 MiB fige = LA pathologie historique : tempete de tb_flush,
   retraduction perpetuelle. Corrige par -tb-size / QEMU_TB_SIZE (patch 0005).
   Boot du benchmark : jamais-fini en 4 h -> 513 s (mono-coeur, 1 seul flush).
3. La TRADUCTION ne coute ~RIEN en une passe : cache persistant (-tb-cache,
   patch 0007) mesure sur pad, reload 100 % (83 031 TBs, 38 Mo de code hote),
   boot chaud = boot froid = 513 s. TOUT le temps est dans l'EXECUTION du code
   traduit. C'est ta cible unique.
4. Ratio d'execution mesure : ~1500-2000x vs natif sur du JS interprete
   (LLInt sous TCG, H3 1 GHz). claude --help natif ~2 s -> ~60 min emule.
5. Cote invite, la recette qui a produit les 513 s : QEMU_TB_SIZE=256 +
   BUN_JSC_useJIT=0 (LLInt-only, zero code auto-modifiant) + GC calme.
   L'attribution montre que ces flags invites COMPTENT (tb256 seul avec JIT
   actif est nettement plus lent que le combo). Les runs -p (tour agent
   complet) durent des heures : c'est un benchmark long, pas un objectif UX.
6. Layout deterministe : ASLR hote varie guest_base entre runs ; le harnais
   sait lancer sous setarch -R (override CLAUDE_SETARCH=1). Requis par
   -tb-cache, utile pour toute mesure reproductible.
7. Le build etait en -O0 (--enable-debug) jusqu'au 2026-07-20 ; build.sh est
   passe en release -O2. GAIN MESURE : torn64 x15,6 (56-63 M -> 873,6 M
   iterations/180 s, 0 dechirure : Fix A intact), --version combo x4,8
   (513 s -> 106 s). PIEGE appris au passage : l'env imbrique ne peut PAS
   tester l'atomicite (qemu-arm 7.2 exterieur traduit LDRD en deux acces
   32 bits : rouge/vert n'y est que du timing) ; torn64 se juge sur pad.
8. Attribution des leviers du boot (--version, mono-coeur, -O0) :
   baseline 32 MiB = jamais fini ; tb256 seul (JIT invite actif) = 1176 s
   (1 flush) ; tb256 + BUN_JSC_useJIT=0 + GC calme = 513 s. La taille du
   cache tue la pathologie ; les flags invites apportent encore x2,3.
9. FEAT_LSE2 du cpu par defaut `max` etait LA pathologie residuelle du boot
   (2026-07-20, profil pondere execution QEMU_TB_EXEC_PROFILE, commit
   c055f30) : sous LSE2 tout LDP/STP aligne 16 (prologue de CHAQUE fonction)
   exige l'atomicite 16 octets, impossible sur hote armv7 -> ~17 M de pas
   atomiques stop-the-world par boot (18,6 % des entrees de TB via la boucle
   principale, jump cache sature). `-cpu cortex-a53` (pre-LSE2) : --version
   106 s -> 13 s (x8,2), batterie correctness verte. Le profil sous a53
   donne 80,9 % d'entrees chainees, 19 % goto_ptr (99,2 % de hits jmp
   cache), 0,1 % boucle : le dispatch goto_ptr ne pese plus que ~3-5 %.
   CONSEQUENCE sur les leviers : l'inline du probe jmp cache retrograde
   (2-4 % estimes) ; re-tester le JIT invite MONTE (la mesure historique
   "JIT actif = x2,3 plus lent" etait polluee par la tempete LSE2 : les
   prologues du code JIT trappaient tous).
10. FAIT depuis (2026-07-20 soir, commits d798702 + 4831b42) : probe inline
   du jump cache aux branches indirectes (valide par constantes de
   traduction, insight : au DISAS_JUMP le tuple cpu == tuple du TB courant)
   + BTI et SVE/SME caches par defaut en user-mode hote 32-bit
   (echappatoires QEMU_KEEP_BTI / QEMU_KEEP_SVE). Resultat : torn64 +49 %,
   --version DEFAUT 10 s froid / 6 s warm. JIT invite : perd au boot
   (17 vs 12 s) mais GAGNE x1,55 sur un tour -p reel (166 vs 257 s), 0
   flush : recommandation usage agent = JIT actif. Le -p a RENDU (jalon V2,
   result success). Echec instructif documente : la v1 du probe (tuple
   canonique + flush par cpu) etait x2 plus lente (815 k changements de
   tuple par boot, les tuples alternent entre communautes de code) ; ne
   jamais gater le jump cache sur un tuple global.
11. Leviers restants, par promesse : (a) re-mesurer --help et -p sur le
   build final (attendus ~50 s et ~140-230 s) ; (b) reduction des mov_i32
   (25,7 % du mix pondere : paires 64-bit, la vraie reponse est le rebase
   10.2 carry-opcodes + o_bits, 1-2 semaines) ; (c) backports isoles
   (TSTNE 35020629914b, extract arm 802ef65b5f8d, TB auto-lie
   03fe6659803f) ; (d) superblocs a travers le computed goto (tres lourd) ;
   (e) balayage fin des seuils JIT invite pour l'usage agent.
12. `-tb-cache` (persistance du cache de traduction) MESURE et TRANCHE
    (2026-07-21) : le rechargement chaud FONCTIONNE (setarch -R + amorce froide)
    et restaure 94-98 % des TBs -- --version reloaded 85074/85520 TBs (~39 MiB
    de code traduit), --help 173569/184031 TBs (~83 MiB). GAIN wall-clock = ZERO :
    --version 15 s froid = 15 s chaud (delta 0,0 %), --help 60 s froid / 61 s
    chaud (delta +1,7 %, bruit). CONFIRME le point 3 de facon directe : tout le
    temps est dans l'EXECUTION du code traduit, pas dans sa TRADUCTION -- eviter
    de re-traduire ne rend rien. `-tb-cache` reste utile UNIQUEMENT comme sonde
    (prouver "0 % du temps = traduction") et pour des mesures deterministes ; ce
    n'est PAS un levier de perf. Ne pas y revenir. Combo warm exact (reproducteur) :
    `CLAUDE_SETARCH=1 CLAUDE_EXTRA_ENV="QEMU_TB_SIZE=256 BUN_JSC_useConcurrentGC=0`
    `BUN_JSC_numberOfGCMarkers=1 QEMU_TB_CACHE=<pad>/tbcache-<mode>.bin"` via
    `run-claude-pad.sh` ; campagne complete `test/warm-recipe.sh 3 300` (medianes de
    3, amorce cold-save, rejette tout run "stale or foreign"). Logs :
    `test/logs/warm-recipe/`. RECOMMANDATION (decision defaut = gate humain) : NE PAS
    activer QEMU_TB_CACHE par defaut dans le wrapper produit (gain nul, cout disque).
13. Levier DISPATCH ferme par la mesure (2026-07-21 soir, X0, test/logs/dispatch-recon/
    X0-FINDINGS.md) : le bucket dispatch (9,1 % --version / 11,9 % --help des cycles
    hote, carte docs/PROFILE-HOTSPOTS.md) est a 86-91 % du chemin de HIT du jump cache,
    deja quasi minimal (6,2 M hits / ~113 k miss sur --version) ; le chemin de MISS
    entier = 0,8-1,7 % ; memoisation cpu_get_tb_cpu_state < 1 %. Aucun sous-levier
    >= 3 % : STOP. ETAT DE LA CAMPAGNE apres la carte R1 : TOUS les postes reductibles
    au-dessus du plancher JIT (37-58 % de code traduit) sont mesures incompressibles ou
    quasi nuls (traducteur : tb-cache gain nul ; dispatch : hit-path minimal ; NZCV
    lazy : rien a elider, ratio reel 0,39 ; superblocs : plafond 2-3 % ; seuils JIT
    invite : plat). Le fork publie est a l'OPTIMUM PRATIQUE de cette architecture ;
    seul reste le levier 3 de la carte (qualite codegen 64-bit inline au backend arm),
    plafond de quelques %, risque eleve, a n'ouvrir que sur decision humaine explicite.

## Le banc de mesure (dans cet ordre)

- RAPIDE, pour iterer : debit torn64 sur pad, `./test/run-pad.sh torn64 2 60`
  -> iterations/minute (proxy direct du debit TCG, resultats en ~1 min).
- MOYEN, le chiffre officiel : `CLAUDE_CPUS=0 CLAUDE_MEMMAX=750M
  CLAUDE_EXTRA_ENV="QEMU_TB_SIZE=256 BUN_JSC_useJIT=0 BUN_JSC_useConcurrentGC=0
  BUN_JSC_numberOfGCMarkers=1" bash test/run-claude-pad.sh version 2400`
  -> elapsed (reference historique -O0 : 513 s).
- LONG, seulement pour valider un gros gain : `--help` (~60 min en -O0) ou un
  `-p` (heures). Ne jamais iterer la-dessus.
- L'env imbrique Mac (docker nest-claude) est ~25x plus lent que le pad et
  JIT-sous-JIT : CORRECTNESS uniquement, jamais de chrono.
- Regles pad : alimentation SECTEUR verifiee (deux runs ont ete tues par la
  batterie), un seul qemu a la fois, MemoryMax, garde thermique (le harnais
  fait tout ca). Build toujours dans docker sur le Mac, jamais sur le pad.

## Benchmarks de reference (a maintenir a chaque gain)

| Date | Build | torn64 iter/180s | --version combo | note |
|---|---|---|---|---|
| 2026-07-18 | -O0 debug | ~56-63 M | jamais fini (32 MiB) | avant tb-size |
| 2026-07-19 | -O0 debug | ~56-63 M | 513 s | reference tb256+jitoff |
| 2026-07-20 | -O2 release | 873,6 M (x15,6) | 106 s (x4,8) | release + tb256 + jitoff |
| 2026-07-20 | -O2 release | 756,7 M (a53) | 13 s (x8,2) | + `-cpu cortex-a53` (LSE2 off) |
| 2026-07-20 | -O2 + 95a465e | (idem) | 12 s SANS option | LSE2 off par DEFAUT ; --help 66 s mono-coeur |
| 2026-07-20 | -O2 + 95a465e | (idem) | `-p` complet 257 s | PREMIER rendu d'un tour agent (result success, "OK") ; 166 s avec JIT invite |
| 2026-07-20 | -O2 + probe d798702 + 4831b42 | 1 306,4 M (+49 %) | 10 s froid / 6 s warm SANS option | probe inline jmp cache + BTI/SVE off par defaut |
| 2026-07-21 | idem | (idem) | 15 s froid = 15 s chaud (`-tb-cache`) | tb-cache recharge ~39 MiB (85074/85520 TBs) : delta 0,0 % -> traduction != goulot. --help 60/61 s (+1,7 %), recharge ~83 MiB |

## Premier profilage (2026-07-20, QEMU_OP_HISTOGRAM sur claude --version)

Histogramme d'opcodes a la TRADUCTION (frequence statique, PAS ponderee execution),
2 915 169 ops sur tout le boot. Top : mov_i32 27,4% ; insn_start 14,4% ;
add2_i32 7,2% ; and_i32 6,7% ; exit_tb 5,7% ; sextract_i32 5,7% ; st8_i32 5,1% ;
set_label 4,1% ; brcond_i32 3,7% ; ld_i32 3,5% ; call 2,7% ; goto_tb 2,3% ;
qemu_ld/st_a64_i64 ~3,9% ; goto_ptr 1,2% ; brcond2/setcond2_i32 ~0,8% ; sub2_i32 0,2%.

Lectures actionnables (a confirmer en ponderation execution) :
- TB TRES PETITS : ~421k insn_start / ~167k exit_tb = ~2,5 instructions invitees par
  TB. Pattern "interpreteur sous JIT" (LLInt = computed-goto, chaque handler finit sur
  une branche indirecte goto_ptr -> nouveau TB). Le cout dominant est le DISPATCH /
  CHAINAGE des TB, pas une op de calcul. Levier le plus prometteur : reduire le cout des
  transitions TB (jump cache, chainage des branches indirectes goto_ptr, superblocs).
- NEON-i64 (ancien levier 3) AFFAIBLI par les donnees : add2+sub2 = 7,4% seulement,
  entrelaces avec du 32-bit, add2 = deja 2 instructions hote (adds+adc). Le cout de
  transfert coeur<->NEON mangerait le gain. NE PAS commencer par la.
- Mix domine par des ops 32-bit simples (mov 27%, and, sextract, ld/st, brcond) : pas
  d'op chaude unique. sextract_i32 5,7% = candidat concret (verifier le lowering arm32).
- mov_i32 27% est eleve : une partie vient du split des valeurs 64-bit en paires ; une
  meilleure gestion 64-bit / allocation de registres reduirait le nombre de mov.
LIMITE : statique, pas execution-weighted. Etape suivante pour l'instance : obtenir le
mix PONDERE EXECUTION (build non-static + plugin howvec/libinsn, ou instrumentation du
code genere), qui peut deplacer les priorites (la boucle chaude != moyenne statique).

## Leviers non explores (graines, par ordre de promesse estimee)

1. PROFIL DES OPS CHAUDES, a faire EN PREMIER : tout le reste en depend.
   Options : perf hote sur le pad + option -perfmap de qemu-user (les regions
   JIT apparaissent symbolisees), ou patch compteur d'ops dans le traducteur.
   Question a trancher : ou partent les cycles ? (arithmetique i64 en paires
   adds/adc, calcul des flags NZCV, dispatch LLInt de l'invite, helpers,
   load/store, chainage TB).
2. Backports selectifs de l'optimiseur TCG de QEMU 10.x/11.x : l'optimiseur
   COMMUN a continue de progresser apres 9.2.4 et la suppression du 64-on-32
   ne touche que le backend arm 32 hote et une partie du frontend ; des
   ameliorations de tcg/optimize.c peuvent se cherry-picker. Inventorier
   `git log v9.2.4..v11.0 -- tcg/optimize.c` et trier ce qui s'applique.
3. NEON pour l'arithmetique i64 SCALAIRE : sur arm32, VADD.I64/VSUB.I64/
   VSHL.I64 font en 1 instruction ce que le backend emet en paires de
   registres coeur avec propagation de retenue. Obstacles reels : cout des
   transferts coeur<->NEON (rentable seulement sur des chaines qui restent en
   NEON), pas de flags cote NEON. A ne tenter QUE si le profil (levier 1)
   montre l'arithmetique i64 dominante.
4. Qualite du lowering des flags NZCV aarch64 : les comparaisons/branches
   64-bit sur hote 32-bit sont un poste classique. Verifier ce que le
   frontend genere (setcond2, brcond2) et ce que le backend en fait.
   VERDICT 2026-07-21 : LEVIER "NZCV PARESSEUX" FERME PAR LA MESURE, ne pas
   re-creuser (branche qemu/nzcv-lazy, Journal PROGRESS.md phase L). Deux
   variantes testees derriere QEMU_NZCV_LAZY=1 : v1 helper au point de lecture
   = torn64 -26,3 % ; v2 cc_op statique dans DisasContext facon i386 = torn64
   -2,3 %, --version/--help plats. CAUSE RACINE : le ratio de reconnaissance
   2,74 (~63 % de defs jamais lus) etait un ARTEFACT d'instrument (compteur de
   groupes au site de definition, aveugle au mecanisme) ; le compteur corrige
   (materialisations reelles) mesure defs/reads = 0,39 sur le workload reel :
   la grande majorite des flags definis SONT relus, volume de materialisation
   ON = OFF a 0,15 % pres, il n'y a RIEN a elider. Sous-produits reutilisables
   sur la branche : guest differentiel test/nzcv-lazy-cases (4 235 checks),
   harnais A/B test/ab-nzcv.sh, profiler de materialisations corrige.
5. Superblocs / regions chaudes : moins de transitions TB->TB (prologue/
   epilogue, lookup). Mesurer d'abord la taille moyenne des TB et le cout des
   transitions (compteurs), avant toute chirurgie.
6. Veneers pour le chainage au-dela de +-32 Mo (aujourd'hui saut indirect via
   cellule memoire). Gain probablement petit ; mesurable via torn64 avec un
   buffer artificiellement grand.
7. Cote invite (benchmark) : balayage FIN des seuils JSC (useJIT retarde
   vs coupe, thresholdForJITAfterWarmUp 5k/20k/50k/200k) : l'espace entre
   "tout interpreter" et "tout compiler" n'a ete que grossierement explore.
8. Idees nouvelles bienvenues : la seule contrainte est un CHIFFRE au bout.

## Infra (fixe, ne pas redecouvrir)

- Repo : ~/Documents/GitHub/qemu-64on32-smartpi ; sous-repo qemu/ branche
  yumi-64on32 (7 commits au-dessus de v9.2.4, exportes dans patches/).
- Build : `bash build.sh` (docker via colima ; `colima start` si docker mort).
- Pad H3 : voir test/pad.env ; harnais test/run-claude-pad.sh (overrides
  CLAUDE_CPUS/MEMMAX/EXTRA_ENV/ARGS_EXTRA/SETARCH) et test/run-pad.sh.
- Journal de bord : PROGRESS.md (phase P). Chaque experience = une entree
  avec la commande et le chiffre, verifiable.
- Hygiene commits : jamais de mention d'outil IA, pas de tirets cadratins.
