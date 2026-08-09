# I64-INLINE-RECON — Reconnaissance chiffrée du gisement 64-bit (GATE Y0)

Levier 3 de la carte R1 (`docs/PROFILE-HOTSPOTS.md`) : qualité du code hôte émis pour
les opérations 64-bit. Ce document est le livrable du gate d'ouverture **Y0**. Il
classe les cycles du bucket JIT en catégories nommées et prononce le gate AVANT toute
chirurgie, conformément à la règle d'or (juger le CODE HÔTE et les CYCLES perf, jamais
l'IR — `mov_i32` est un mirage prouvé M2/M3).

## Méthode (double source, croisée)

1. **Code hôte réel** des TB les plus chauds (profil `QEMU_TB_EXEC_PROFILE`), dumpé au
   moment de la traduction sur le pad secteur via le hook `CLAUDE_QEMU_OPTS` de
   `test/run-claude-pad.sh` :
   `-dfilter <PC chauds> -d op,out_asm` → `test/logs/i64-recon/y0-dump-version.log`
   (claude --version, 5071 lignes, taskset mono-cœur, pad 40 °C).
2. **Cycles perf** pondérés exécution, symboles complets, campagnes du 2026-07-21 :
   `test/logs/perf-hotspots/perf-version-nomap-*.symfull` (régime froid/traduction,
   le plus propre) et `perf-help-*.symfull` (régime chaud/exécution).

Les pourcentages perf ci-dessous sont déjà des **% de cycles TOTAUX** (perf report sur
la totalité des samples du process qemu-aarch64).

## Table — décomposition du gisement 64-bit

| Catégorie | Contenu | Preuve | % cycles totaux | Verdict |
|---|---|---|---|---|
| **(a) Décomposition 64-bit ÉVITABLE** | sites d'appel helpers i64 inlinables (`shl/shr/sar/muluh/udiv`) | perf symfull | **version 1,07 % / help 0,88 %** | seul bucket capturable |
| (a bis) paires `adds/adc` + `subs/sbc` (`add2_i32`/`sub2_i32`) | déjà optimales | dump hôte (voir §preuve) | **0 % évitable** | intouchable (optimal) |
| (b) Accès mémoire / ldst | `helper_ld*_mmu`, atomiques | LANDMINE Fix A | — | intouchable |
| (c) Flags NZCV | `ZF/NF/CF/VF`, `setcond2_i32` | chantier fermé (nzcv-lazy archivé) | gros de l'enflure autour de sub2 | fermé |
| (d) Reste irréductible | `helper_lookup_tb_ptr` (3,86–4,40 %), goto_tb, prologue | R1 dispatch (levier 2 fermé X0) | — | hors périmètre |

### Détail catégorie (a) — perf, par pattern nommé

| Symbole | version-nomap | help | Plafond réaliste (max des deux) |
|---|---|---|---|
| `helper_shl_i64` | 0,46 % | 0,66 % | **0,66 %** |
| `helper_muluh_i64` | 0,57 % | 0,10 % | **0,57 %** |
| `helper_shr_i64` | 0,02 % | 0,08 % | 0,08 % |
| `helper_sar_i64` | 0,02 % | 0,02 % | 0,02 % |
| `helper_udiv64` | — | 0,02 % | 0,02 % |
| **Somme (a)** | **1,07 %** | **0,88 %** | **~1,1 % au mieux** |

## Preuve host-code : `add2/sub2` sont déjà optimaux (pas de gisement)

TB chaud `0x2eadb94` (claude --version), guest `SUBS x4,x16,#0x30` puis compare 64-bit.
Le SOUSTRACTEUR 64-bit pur `sub2_i32 x4,x4,$0x30,$0x0` se lowerise en **exactement
2 instructions hôtes**, déjà LPAE-optimales, sans helper ni décomposition gaspillée :

```
0xa6c74adc:  e2555030  subs  r5, r5, #0x30      ; low word + flags
0xa6c74ae0:  e2c77000  sbc   r7, r7, #0         ; high word + carry
```

Sur les 68 `add2_i32`/`sub2_i32` du dump, on compte **118 paires hôtes `adds/adc` /
`subs/sbc` inline** et **zéro** appel helper arithmétique (`grep 'call'` ne remonte que
`lookup_tb_ptr` et `atomic_fetch_addl` — hors périmètre). L'enflure visible autour de
`sub2_i32` dans l'IR (`ZF/NF/CF/VF`, `setcond2_i32`, `xor/and`) est de la
**matérialisation de flags NZCV = catégorie (c), chantier FERMÉ**, pas de
l'arithmétique 64-bit capturable par le levier 3.

Corroboration IR pondérée (`test/logs/dispatch-recon/help-run-1.tcg`) : `add2_i32`
6,2 %, `sub2_i32` 0,6 %, `setcond2_i32` 1,0 % de l'IR — mais l'IR est un mirage (M2/M3)
et le code hôte ci-dessus prouve que ces ops ne coûtent que 2 instructions chacune. Les
shifts 32-bit glue (`shl/shr/sar/extract2_i32`) pèsent 0,2–0,3 % d'IR chacun, cohérent
avec le ~1 % perf des helpers i64.

## Esquisse de lowering de remplacement (pour mémoire, NON retenue)

Le seul pattern non trivial serait `helper_shl_i64` (décalage 64-bit à quantité
variable) : inlinable en ~6–8 instructions arm32 (décalage conditionné par `shift<32`
vs `>=32`, branche + `lsl/lsr/orr`). Gain théorique plafonné à **0,66 %** des cycles,
au prix d'un risque correctness (bord `shift==0`, `shift>=64`) sur un chemin déjà
couvert par un helper correct. `muluh_i64` (0,57 %) demanderait `umull`/`umlal` — même
ordre de grandeur, même risque.

## GATE Y0 — VERDICT : **NO-GO / STOP DÉFINITIF**

Critère (PROGRESS Y0) : *somme des patterns évitables ≥ 3 % des cycles totaux ET au
moins un pattern nommé ≥ 1,5 %*.

- Somme catégorie (a) évitable : **1,07 % (version) / 0,88 % (help)** → **< 3 %**. ❌
- Meilleur pattern nommé : `helper_shl_i64` **0,66 %** → **< 1,5 %**. ❌
- `add2/sub2` : gisement **nul** (déjà optimal, prouvé host-code). ❌

**Les deux conditions du gate échouent avec marge (facteur ~3×).** Conformément au
protocole (fermeture chiffrée, modèle S0), le **levier 3 est fermé** et, comme c'était
le dernier levier de la carte R1, **la campagne d'optimisation est close**. Aucune
chirurgie (Y1/Y1G/Y2) n'est engagée : elle plafonnerait mathématiquement à ~1 % de
gain brut pour un risque correctness élevé sur des chemins aujourd'hui corrects.

Ce résultat confirme la thèse de fond du fork : le coût dominant n'est pas
l'arithmétique 64-bit (LPAE `adds/adc` la rend quasi gratuite) mais le **dispatch**
(`helper_lookup_tb_ptr` ~4 %, levier 2 déjà fermé en X0) et les **flags** (chantier
NZCV fermé). Le code hôte 64-bit émis est déjà proche de l'optimal atteignable.
