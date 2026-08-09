# PROFILE-HOTSPOTS, carte des couts HOTE ponderee execution (lot R1)

Ou partent reellement les cycles hote quand le fork qemu execute un invite aarch64 sur
le pad armv7 (Allwinner H3, Cortex-A7). C'est le levier 1 du handoff efficacite (profil des
ops chaudes, "a faire en premier, tout le reste en depend"), enfin fait au niveau HOTE : les
profils precedents (phases S, L) restaient au niveau IR/TB. Cette carte etablit la verite
terrain et sert de GATE pour choisir les prochains leviers.

Deux leviers ont deja ete tues par des instruments de reconnaissance defaillants (ratio NZCV
2,74 = artefact de compteur, vrai ratio 0,39 ; gate S0 qui a evite des jours de chirurgie a
2 %). Ici l'instrument est perf lui-meme (echantillonnage PMU materiel), pas un compteur
maison : la mesure est directe et l'overhead est chiffre (0,05 %).

## Methode

- **Outil** : `perf record` (paquet Debian linux-perf 6.12.95 installe sur le pad, justif.
  au Journal R1), evenement `cycles:P` du PMU materiel `armv7_cortex_a7` (present, verifie),
  frequence modeste `-F 99` a `-F 499`, fenetres courtes. perf tourne sous sudo (acces PMU +
  symboles noyau). Aucun patch ni rebuild : `QEMU_PERFMAP` est natif en 9.2.4
  (linux-user/main.c), il ecrit `/tmp/perf-<pid>.map` qui nomme chaque bloc traduit
  (`guest-0x<pc>`) pour que perf symbolise le code JIT.
- **Binaire profile** : le fork DEJA DEPLOYE sur le pad, sha
  `5424499e5bb3f6645088008582ab7f5ac61086132e24a0216fb3a1028a3fc9f8` (identique au local,
  verifie a chaque run). Non strippe (17382 symboles, debug_info) : perf nomme aussi les
  fonctions C de qemu (helpers, cpu_exec, tb_lookup). Le flag QEMU_NZCV_LAZY reste OFF
  (defaut publie) : ce profil est representatif de l'etat `yumi-64on32` publie.
- **Attribution** : `perf report --stdio` par DSO (split haut niveau, somme a 100 %) et par
  symbole (`test/bucket-perf.py` classe chaque symbole en buckets ponderes execution). Le
  split par DSO issu du rapport pris AU MOMENT du run (map presente) fait foi pour la part
  JIT ; les sous-buckets qemu-C viennent des symboles de l'ELF (toujours resolus). Somme des
  sous-buckets qemu-C = total DSO qemu-aarch64 a moins de 0,5 % pres sur les 4 runs (coherent).
- **Harnais** : `test/run-perf-pad.sh <torn64|claude-version|claude-help>` (sha verifie, un
  seul qemu, taskset, timeout, temperature avant/apres, artefacts dans
  `test/logs/perf-hotspots/`). Logs bruts : `*.dso` (buckets DSO), `*.sym` (symboles >0,1 %),
  `*.symfull` (tous symboles), `*.rec` (metadonnees), `*.out` (sortie invite + preuve de boot).

### Overhead de l'instrument (GATE : < 10 % du chrono nu)

torn64 N=4, 60 s, meme ligne de commande a `perf record` pres :

| condition | iterations 60 s | ecart |
| --- | --- | --- |
| nu (sans perf) | 437 086 699 | reference |
| sous `perf record -F 99` | 436 858 954 | **-0,052 %** |

Overhead 0,05 %, tres en dessous du seuil de 10 %. A `-F 99`, perf est essentiellement
gratuit sur ce workload ; on a donc pu monter a `-F 499`/`-F 299` sur les runs claude pour
la robustesse statistique (6K a 17K echantillons) sans souci d'overhead.

### Contamination par QEMU_PERFMAP (mesuree et corrigee)

QEMU_PERFMAP ecrit une ligne par TB (295 515 pour --version, 628 732 pour --help) via
`fprintf`. Cout mesure en comparant deux RUNS --version identiques, avec et sans le flag :

| bucket runtime (libc/IO) | --version AVEC perfmap | --version SANS perfmap | delta |
| --- | --- | --- | --- |
| runtime (dont `__vfprintf_internal`, `memset`, `malloc`) | 18,2 % | 13,0 % | **+5,2 %** |

Les profils PRIS AVEC perfmap sur-ponderent le bucket runtime d'environ 5 % (l'ecriture de la
map). La structure de cout CLEAN ci-dessous utilise le run de controle SANS perfmap ; le run
avec perfmap sert au detail des symboles JIT.

## Table d'attribution (cycles hote, ponderes execution)

Split haut niveau par DSO (fait foi, rapport pris map presente) :

| workload | freq | coeurs | echant. | JIT (code traduit) | qemu C | noyau |
| --- | --- | --- | --- | --- | --- | --- |
| **claude --version** (clean, sans perfmap) | 499 | 1 | 6K | **37,0 %** | 58,4 % | 4,6 % |
| claude --version (avec perfmap) | 499 | 1 | 6K | 34,1 % | 61,4 % | 4,5 % |
| **claude --help** (avec perfmap) | 299 | 2 | 17K | **57,6 %** | 40,4 % | 2,0 % |
| torn64 (controle atomicite) | 99 | 2 | 11K | 64,7 % | 35,0 % | 0,2 % |

Decomposition du bucket qemu C (en % du TOTAL des cycles hote) :

| sous-bucket qemu C | --version clean | --version perfmap | --help | torn64 |
| --- | --- | --- | --- | --- |
| **translator** (TCG codegen : liveness, tcg_gen_code, optimize, regalloc, disas) | **33,5 %** | 32,4 % | **16,0 %** | 0,1 % |
| **dispatch** (boucle exec + lookup de TB : helper_lookup_tb_ptr, tb_lookup, cpu_get_tb_cpu_state, qht) | **9,1 %** | 9,0 % | **11,9 %** | 0,0 % |
| **helpers** (instructions invite : shl/muluh i64, atomics softmmu) | 3,0 % | 2,3 % | 2,1 % | **34,9 %** |
| **runtime** (libc/glib/alloc + IO perfmap) | 13,0 % | 18,2 % | 10,9 % | 0,1 % |

(Sommes qemu C : --version clean 58,6 % vs DSO 58,4 % ; --help 40,9 % vs DSO 40,4 % ; torn64
35,0 % vs DSO 35,0 %. Coherence a moins de 0,5 %.)

### Top 20 des symboles (claude --version, run f499 symbolise)

| % cycles | bucket | symbole |
| --- | --- | --- |
| 8,09 | translator | liveness_pass_1 |
| 5,08 | translator | tcg_gen_code |
| 3,63 | dispatch | tb_lookup |
| 3,47 | dispatch | helper_lookup_tb_ptr |
| 2,98 | translator | tcg_optimize |
| 2,65 | runtime (perfmap) | __vfprintf_internal |
| 2,09 | translator | init_ts_info |
| 1,76 | runtime | memset |
| 1,20 | dispatch | cpu_get_tb_cpu_state |
| 1,14 | translator | liveness_pass_0 |
| 0,97 | translator | tcg_reg_alloc |
| 0,91 | translator | la_cross_call |
| 0,86 | runtime | _int_malloc |
| 0,77 | translator | tcg_op_alloc |
| 0,63 | translator | tcg_emit_op |
| 0,62 | runtime | __aeabi_uidiv |
| 0,57 | helpers | helper_atomic_fetch_addl_le |
| 0,53 | translator | temp_free_or_dead |
| 0,51 | dispatch | qht_lookup_custom |
| 0,50 | runtime | g_hash_table_lookup |

### Top symboles (claude --help, workload execution-bound)

| % cycles | bucket | symbole |
| --- | --- | --- |
| 4,81 | dispatch | tb_lookup |
| 4,40 | dispatch | helper_lookup_tb_ptr |
| 3,97 | translator | liveness_pass_1 |
| 2,57 | translator | tcg_gen_code |
| 1,54 | dispatch | cpu_get_tb_cpu_state |
| 1,38 | translator | tcg_optimize |
| 1,07 | runtime | memset |
| 0,66 | helpers | helper_shl_i64 |
| 0,52 | dispatch | tb_lookup_cmp / qht_lookup_custom |

## Interpretation : DEUX regimes

1. **--version = COLD, translation-bound.** Le binaire boote, traduit une grosse masse de
   code (295 K TB) et l'execute peu : le TRADUCTEUR TCG domine (33,5 % des cycles hote,
   liveness_pass_1 seul a 8 %). C'est un cout PAYE UNE FOIS par boot a froid.
2. **--help = plus WARM, execution-bound.** Beaucoup plus d'execution reelle (init CLI
   complete) : le code traduit (JIT) domine (57,6 %), le traducteur retombe a 16 %, et le
   DISPATCH (lookup de TB non chaines) monte a 11,9 %.
3. **torn64 = controle.** Sous stress atomique pur, tout le bucket qemu C EST le chemin
   atomique 64-bit de Fix A (helper_atomic_fetch_addq_le 24 % + atomic_mmu_lookup 11 %). Sur
   les workloads claude reels ce chemin ne pese que 2 a 3 % : les atomiques sont rares hors
   stress. Ce cout est mandate par la correctness, ce n'est PAS un levier.

Le code traduit (JIT, 37 a 58 %) est le PLANCHER structurel : le cout TCG de 8 a 20x par
instruction invite. Irreductible sans changer la QUALITE de traduction (meilleur code hote par
insn invite). Le reste (traducteur + dispatch + runtime) est la surcouche potentiellement
reductible.

## Leviers candidats et plafonds Amdahl (GATE R1)

Trois leviers designes, chiffres a l'appui. Le plafond Amdahl = part maximale du temps que le
levier peut supprimer (il ne l'atteindra jamais entierement).

### Levier 1, cache de traduction persistant comme recette PAR DEFAUT, plafond ~33 % (cold) / ~16 % (help)

Le traducteur est le plus gros bucket reductible sur boot a froid (33,5 % de --version). Or le
cache de traduction persistant (P3, commit qemu `ed94d61`, option `-tb-cache`/`QEMU_TB_CACHE`)
EST DEJA CONSTRUIT et valide : un boot warm recharge les TB au lieu de les retraduire, ce qui
supprime la quasi-totalite du bucket translator. P3 a deja mesure warm cache = -40 % sur
--version et -28 % sur --help : coherent avec ce profil (translator 33,5 % + IO/alloc de
traduction associes). **Plafond = le bucket translator entier** (33,5 % --version, 16 % --help).
Risque QUASI NUL : ce n'est pas de la chirurgie mais une recette (ajouter `QEMU_TB_CACHE` +
`setarch -R` au combo standard produit) plus une re-mesure warm en mediane. **Meilleur ratio
plafond/risque de la carte.** C'est le premier levier a poser.

### Levier 2, dispatch / jump-cache des branches indirectes, plafond ~9 % (version) / ~12 % (help)

Le bucket dispatch (helper_lookup_tb_ptr + tb_lookup + cpu_get_tb_cpu_state + qht_lookup) est la
surcouche execution reductible : 8,8 % sur --version, 11,9 % sur --help (ou il DOMINE le cote
qemu). C'est le cout des transitions de TB NON chainees : la phase S0 avait mesure 80,9 % des
transitions deja chainees (goto_tb gratuit) et ~10 a 12 % de branches INDIRECTES (retours,
sauts calcules) qui ne peuvent pas utiliser goto_tb et passent par le jump-cache puis la qht.
**Plafond = bucket dispatch (~9 a 12 %).** Pistes : agrandir/mieux hacher le jump-cache par
thread, memoiser cpu_get_tb_cpu_state (recalcule a chaque lookup). Risque MOYEN (reglage du
cache, pas de chirurgie du core traducteur). C'est la plus grosse opportunite NEUVE cote
execution, et la dominante sur le workload execution-bound (--help, le plus proche du travail
agent reel).

### Levier 3, qualite du code traduit pour les ops 64-bit, plafond structurel (part capturable modeste)

Le JIT est le plancher (37 a 58 %) mais une SLICE est capturable : la phase S a note ~26 % des
ops de TB en `mov_i32` issus du decoupage 64-bit sur hote 32-bit, plus le `save_globals` en fin
de TB. Reduire ce decoupage (plus d'ops 64-bit inlinees au backend arm au lieu de helpers, cf.
helper_shl_i64/muluh_i64) attaque une fraction du plancher. **Plafond pratique = quelques % du
bucket JIT, pas les 37 a 58 % entiers** (le gros du JIT est du code hote incompressible).
Risque ELEVE (chirurgie TCG core + backend, la limite des 2 slots goto_tb par TB reste dure).
Priorite BASSE : a n'ouvrir que si un profil post-levier-2 le rejustifie.

### Hors leviers

- **helpers/atomiques** : 2 a 3 % sur claude (34,9 % sur torn64 = correctness Fix A). Mandate,
  pas un levier.
- **noyau** : 2 a 4,6 % (mmap/mprotect du buffer JIT + pages invite, syscalls). Diffus, plafond
  ~2 a 4 %, recouvert en partie par le levier 1 (moins de mmap si moins de traduction).

## Verdict du GATE R1

La table designe, chiffres a l'appui, les 3 premiers leviers candidats et leurs plafonds :
levier 1 (cache warm par defaut, plafond ~33 %, risque quasi nul, deja construit), levier 2
(dispatch/jump-cache, plafond ~9 a 12 %, risque moyen, plus grosse opportunite neuve), levier 3
(qualite code traduit 64-bit, plafond structurel modeste, risque eleve, priorite basse). Le
prochain chantier sera pose par l'orchestrateur au vu de ces chiffres. Recommandation : levier 1
d'abord (verifier que le combo standard active bien le cache warm, gain deja mesure a P3), puis
levier 2 comme premier vrai chantier d'optimisation execution.

## Reproduction

```
source test/pad.env
# provisionner perf sur le pad (une fois)
sshpass -p "$PAD_PASS" ssh "$PAD_USER@$PAD_HOST" "echo \"$PAD_PASS\" | sudo -S apt-get install -y linux-perf"
# profils (chaque run : sha verifie, un seul qemu, timeout, temp avant/apres)
bash test/run-perf-pad.sh torn64 60                          # controle atomicite + overhead
PERF_FREQ=499 PERF_TAG=version-f499 bash test/run-perf-pad.sh claude-version 240
PERF_FREQ=499 PERF_NO_MAP=1 PERF_TAG=version-nomap bash test/run-perf-pad.sh claude-version 240
PERF_FREQ=299 PERF_TAG=help bash test/run-perf-pad.sh claude-help 360
# buckets d'attribution depuis un rapport plein
python3 test/bucket-perf.py test/logs/perf-hotspots/<base>.symfull --top 20
```

Les captures binaires `perf.data` et les maps JIT (jusqu'a 17 Mo) ne sont pas versionnees
(macOS ne les relit pas, elles sont specifiques au pad et a la map d'un run) : seuls les
rapports texte sont conserves dans `test/logs/perf-hotspots/`. Elles se regenerent avec les
commandes ci-dessus.
