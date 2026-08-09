# X0 : Reconnaissance du dispatch indirect (goto_ptr / jump cache)

Objectif : mesurer, en compteurs **execution-weighted**, ce que coûte réellement le
dispatch indirect, et décider si un travail d'optimisation (X1) peut franchir le seuil
GATE de **3 % des cycles hôtes totaux**.

Méthode : `QEMU_TB_EXEC_PROFILE=1` sur le binaire déployé (yumi-64on32), combo standard,
2 CPU / 750 M, boot à froid. 3 runs `version` + 3 runs `help`, médianes (n=3).
Données brutes : `*.tcg`, agrégat : `summary.txt`.

## 1. Compteurs (médianes n=3)

| Métrique | version | help |
|---|---|---|
| tb executions (weighted) | 68 871 841 | 256 697 569 |
| goto_ptr helper calls | 6 343 374 | 26 447 380 |
| main loop lookups | 99 469 | 220 368 |
| jump cache **HIT** | 6 212 255 | 25 138 126 |
| jump cache **MISS** (htable hit) | 112 433 | 1 289 454 |
| **HIT % des lookups** | **98,22 %** | **95,12 %** |
| **MISS % des lookups** | **1,78 %** | **4,88 %** |
| entrées chaînées (goto_tb) | 90,7 % | 89,6 % |
| entrées goto_ptr (indirect) | 9,2 % | 10,3 % |
| entrées main loop | 0,1 % | 0,1 % |

Classes de fin de TB (execution-weighted) : ~83 % `other (cond/sys/exit)`, ~11 %
`indirect (goto_ptr)`, ~5 % branches same-page, <1 % cross-page. Le dispatch indirect
concerne donc **~10 % des entrées de TB**, le reste est déjà chaîné en dur.

## 2. Décomposition du coût (modèle X0 × poids perf R1)

Bucket « dispatch » selon symbolisation R1 (% des cycles hôtes **totaux**) :

| | version | help |
|---|---|---|
| bucket dispatch total | 9,07 % | 11,92 % |
| , symboles MISS-only (qht + cmp + get_page_addr) | 0,67 % | 1,17 % |
| , per-dispatch (helper_lookup + cpu_get_tb_cpu_state) | 5,01 % | 5,94 % |
| , tb_lookup (probe inline) | 3,39 % | 4,81 % |
| **→ chemin HIT** | **~8,25 % (91 % du bucket)** | **~10,23 % (86 % du bucket)** |
| **→ chemin MISS** | **~0,82 % (9 % du bucket)** | **~1,69 % (14 % du bucket)** |

## 3. Verdict GATE

- Le coût du dispatch est **dominé par le chemin HIT** (86–91 % du bucket). Le HIT est
  déjà quasi-minimal : sonde du jump cache (lecture tableau + 4 compares) + prologue
  `helper_lookup_tb_ptr` + `cpu_get_tb_cpu_state`. Rien à « réparer », c'est du travail
  incompressible par dispatch.
- Le chemin **MISS ne pèse que 0,8 % (version) à 1,7 % (help)** des cycles totaux.
  L'améliorer (meilleur hachage, cache plus grand) est **structurellement sous le seuil
  de 3 %**, même en éliminant 100 % des misses.
- `cpu_get_tb_cpu_state` (1,15–1,54 %) est le seul candidat « per-dispatch » réductible,
  mais sur le chemin A64 chaud il est déjà minimal (`hflags` mis en cache, un feature
  check, store du PC). Une mémoïsation exigerait un garde presque aussi coûteux que la
  fonction. Gain attendu : **< 1 %**.

**Conclusion : aucun sous-levier du dispatch ne peut atteindre seul 3 % des cycles
totaux.** Le chemin HIT est incompressible, le chemin MISS est trop petit, et la
mémoïsation de `cpu_get_tb_cpu_state` reste sous 1 %. **X1 (optimisation dispatch) ne
franchit pas le GATE, recommandation : ne pas poursuivre ce levier.**
