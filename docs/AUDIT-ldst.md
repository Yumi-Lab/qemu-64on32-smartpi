# AUDIT-ldst, chemin d'atomicite 64-bit (Fix A, lot A1)

Audit du chemin d'atomicite des acces memoire 64-bit de l'invite aarch64 sous QEMU
v9.2.4, hote armv7 (Cortex-A7, arm-linux-gnueabihf), cible `aarch64-linux-user`,
`CONFIG_USER_ONLY`. Objectif : localiser EXACTEMENT ou un acces 64-bit aligne se
dechire, et decider si un patch est requis dans `accel/tcg/ldst_atomicity.c.inc`
(le chemin HELPER) ou ailleurs.

## Conclusion (TL;DR)

- Le chemin HELPER (`accel/tcg/ldst_atomicity.c.inc`) est CORRECT sur armv7 : pour un
  acces 64-bit aligne il passe par `__atomic_load_n` / `__atomic_store_n` (ldrexd/strexd),
  donc single-copy-atomic. AUCUN fallback dechirant n'y existe. **Pas de patch A1.**
- La dechirure vient du chemin RAPIDE INLINE emis par le backend
  `tcg/arm/tcg-target.c.inc` : pour un acces MO_64 ordinaire, il emet DEUX acces 32-bit
  hote (`ld32`/`st32`) au lieu de LDRD/STRD. Le helper atomique n'est meme JAMAIS atteint
  pour un acces aligne en user-mode.
- Cause racine, une phrase : le backend decide LDRD/STRD vs 2x32-bit sur
  `memop_alignment_bits(opc)` (bits d'ALIGNEMENT encodes dans le memop), qui vaut 0 pour un
  acces 64-bit aarch64 ordinaire, au lieu de decider sur l'ATOMICITE requise `h->aa.atom`
  (correctement calculee a MO_64). Le fix appartient donc aux lots A2 (load) et A3 (store),
  pas a A1.

## Faits hote (verifies sur le build courant)

| Fait | Valeur | Source |
|------|--------|--------|
| CONFIG_ATOMIC64 | defini | `build/config-host.h:24` (`#define CONFIG_ATOMIC64`) |
| HAVE_al8 | `true` | `ldst_atomicity.c.inc:15-19` (via CONFIG_ATOMIC64) |
| ATOMIC_REG_SIZE | `sizeof(void*)` = 4 | `include/qemu/atomic.h:73-77` (hote 32-bit) |
| HAVE_al8_fast | `false` (4 >= 8 faux) | `ldst_atomicity.c.inc:20` |
| tcg_use_softmmu | `false` en user-only | `include/tcg/tcg.h:559-562`, `tcg/tcg.c:235` (bool a zero, jamais reaffecte) |
| qatomic_read__nocheck(p8) | `__atomic_load_n(p, RELAXED)` -> ldrexd | `include/qemu/atomic.h:89-90` |
| qatomic_set__nocheck(p8) | `__atomic_store_n(p, RELAXED)` -> strexd | `include/qemu/atomic.h:98-99` |

Consequence de `HAVE_al8 == true` et `HAVE_al8_fast == false` : le helper SAIT faire un
acces 64-bit atomique (ldrexd/strexd), mais le sait via `__atomic_*_n`, pas via un simple
registre de la taille du bus. C'est exactement le levier decrit dans GOAL.md.

## 1. Chemin HELPER : les 4 fonctions demandees (CORRECT, pas de dechirure)

Ces fonctions ne sont appelees que par le SLOW-PATH (helper C `do_ld8_mmu` / `do_st8_mmu`),
c.-a-d. quand le fast-path inline a devie (miss TLB en softmmu, ou echec du test
d'alignement en user-mode). Voir section 3 pour savoir quand elles sont, ou ne sont pas,
atteintes.

### load_atomic8 (`ldst_atomicity.c.inc:132-138`)
```
qemu_build_assert(HAVE_al8);
return qatomic_read__nocheck(p);   // __atomic_load_n(p, 8) -> ldrexd, ATOMIQUE
```
Correct : 8 octets alignes lus atomiquement. Le `qemu_build_assert(HAVE_al8)` garantit qu'on
n'y entre jamais sans CONFIG_ATOMIC64.

### store_atomic8 (`ldst_atomicity.c.inc:624-630`)
```
qemu_build_assert(HAVE_al8);
qatomic_set__nocheck(p, val);      // __atomic_store_n(p, 8) -> strexd, ATOMIQUE
```
Correct, symetrique.

### load_atom_8 (`ldst_atomicity.c.inc:486-529`)
```
if (HAVE_al8 && likely((pi & 7) == 0)) {
    return load_atomic8(pv);       // CAS ALIGNE : atomique. Chemin pris sur armv7.
}
...
atmax = required_atomicity(cpu, pi, memop);   // cas non aligne
```
Sur armv7 (`HAVE_al8 == true`), tout acces 8 octets ALIGNE retourne immediatement
`load_atomic8` : atomique. Le cas non aligne descend vers `required_atomicity`, qui pour
`MO_ATOM_IFALIGN` non aligne rend `MO_8` (`ldst_atomicity.c.inc:46-49`), donc lecture par
octets : pas de dechirure garantie architecturalement, mais surtout PAS DE CRASH, ce qui est
l'exigence de GOAL.md pour le non aligne.

### store_atom_8 (`ldst_atomicity.c.inc:985-1041`)
```
if (HAVE_al8 && likely((pi & 7) == 0)) {
    store_atomic8(pv, val);        // CAS ALIGNE : atomique.
    return;
}
atmax = required_atomicity(cpu, pi, memop);   // cas non aligne, par parties, pas de crash
```
Correct, symetrique. Le cas `MO_64` non aligne (`:1030-1035`) tente `HAVE_CMPXCHG128` (faux
sur armv7) puis retombe sur `cpu_loop_exit_atomic` (stop-the-world serialise) : lent, correct,
c'est la landmine STXP/LDXP 128-bit connue de GOAL.md, on n'y touche pas.

**Verdict helper : aucun fallback dechirant sur armv7. Les 4 fonctions sont correctes.
Aucun patch n'est requis dans `ldst_atomicity.c.inc`.**

## 2. Comment `atom_and_align_for_opc` decide inline vs helper

`atom_and_align_for_opc` (`tcg/tcg.c:5508-5570`) calcule, pour le FAST-PATH inline, un couple
`{atom, align}` (type `TCGAtomAlign`) a partir du memop :

```
MemOp align = memop_alignment_bits(opc);   // bits MO_ALIGN encodes, 0 si pas de MO_ALIGN
...
case MO_ATOM_IFALIGN:  atmax = size;  break;   // pour MO_64 : atmax = MO_64
...
return (TCGAtomAlign){ .atom = atmax, .align = align };
```

Le backend arm l'appelle en `prepare_host_addr` (`tcg/arm/tcg-target.c.inc:1433`) :
```
h->aa = atom_and_align_for_opc(s, opc, MO_ATOM_IFALIGN, false);
a_mask = (1 << h->aa.align) - 1;
```

`a_mask` (le masque d'alignement) est ce qui pilote la deviation vers le helper :

- **Softmmu** (`tcg_use_softmmu == true`, PAS notre cas) : `a_mask` est integre au test de
  TLB (`:1499-1520`). Un acces mal aligne devie vers le slow-path (helper atomique). Un
  acces aligne qui hit le TLB reste inline.
- **User-only** (`tcg_use_softmmu == false`, NOTRE cas) : branche `else if (a_mask)`
  (`:1525-1536`). Si `a_mask != 0`, un label ldst est cree et un `tst addr, #a_mask` devie
  les acces mal alignes vers le helper. **Si `a_mask == 0`, AUCUN label, AUCUN test : on va
  DIRECTEMENT a l'emission inline `tcg_out_qemu_*_direct`.**

Le point cle : `atom` (l'atomicite REQUISE) sort correctement a `MO_64`, mais `align` reste 0
pour un acces ordinaire, donc `a_mask == 0`, donc en user-mode le helper n'est jamais atteint
pour un acces 64-bit aligne. Et `h->aa.atom` n'est ensuite JAMAIS relu par l'emetteur inline.

## 3. Le site de la dechirure : chemin RAPIDE INLINE (backend arm)

### 3.1 Le frontend aarch64 n'encode PAS d'alignement pour un acces ordinaire

`finalize_memop` (`target/arm/tcg/translate.h:706-725`) :
```
static inline MemOp finalize_memop_atom(DisasContext *s, MemOp opc, MemOp atom) {
    if (s->align_mem && !(opc & MO_AMASK)) opc |= MO_ALIGN;   // seulement si SCTLR.A
    return opc | atom | s->be_data;
}
// finalize_memop : atom = s->lse2 ? MO_ATOM_WITHIN16 : MO_ATOM_IFALIGN
```

Pour un `LDR x0,[x1]` / `STR x0,[x1]` ordinaire (AccType_NORMAL), `s->align_mem` est faux
(SCTLR.A = 0, cas normal sous Linux), donc **MO_ALIGN n'est PAS ajoute**. Le memop final vaut
`MO_64 | MO_ATOM_IFALIGN` (ou `| MO_ATOM_WITHIN16` si lse2), SANS bit d'alignement.
A comparer avec un acces exclusif ou atomique explicite qui, lui, force `MO_ALIGN` (ex.
`translate-a64.c:2433` : `MO_64 | MO_ALIGN | MO_ATOM_IFALIGN`, et `check_atomic_align`
`:377-399`). Ces derniers ne dechirent donc pas ; le probleme est les acces ORDINAIRES.

### 3.2 Le backend gate LDRD/STRD sur l'alignement, pas sur l'atomicite

`tcg_out_qemu_ld_direct`, cas `MO_UQ` (`tcg/arm/tcg-target.c.inc:1585-1626`) :
```
case MO_UQ:
    tcg_debug_assert((datalo & 1) == 0);      // paire de registres deja garantie
    tcg_debug_assert(datahi == datalo + 1);
    if (memop_alignment_bits(opc) >= MO_64) { // <-- 0 >= 3 => FAUX pour un acces ordinaire
        ... tcg_out_ldrd_8 / tcg_out_ldrd_r ...   // LDRD atomique, JAMAIS pris ici
    }
    ...
    tcg_out_ld32_12(s, h.cond, datalo, base, 0);  // DEUX ld32 32-bit = LECTURE DECHIREE
    tcg_out_ld32_12(s, h.cond, datahi, base, 4);
```

`tcg_out_qemu_st_direct`, cas `MO_64` (`:1689-1710`) : strictement symetrique,
`memop_alignment_bits(opc) >= MO_64` faux, donc deux `st32` (`:1701-1702`) = ECRITURE
DECHIREE. C'est exactement la valeur `0x1111111122222222` observee par `torn64` en baseline
(moitie haute de PATTERN_A + moitie basse de PATTERN_B, cf. `docs/REPRO.md`).

### 3.3 Chaine complete de la dechirure (acces 64-bit aligne ordinaire, user-mode)

1. Frontend : `finalize_memop(MO_64)` -> `MO_64 | MO_ATOM_IFALIGN`, sans MO_ALIGN.
2. `atom_and_align_for_opc` -> `h->aa = {atom = MO_64, align = 0}`.
3. `a_mask = 0` -> branche user-mode `else if (a_mask)` fausse -> pas de deviation helper.
4. `tcg_out_qemu_ld_direct` / `st_direct` : `memop_alignment_bits(opc) = 0 < MO_64`
   -> emission de 2x `ld32` / 2x `st32`.
5. Un autre thread hote observe l'etat intermediaire entre les deux acces 32-bit -> DECHIRURE.

Le helper atomique correct de la section 1 n'est jamais sollicite.

### 3.4 Pourquoi FEAT_LSE2 ne sauve rien

Avec `s->lse2`, `atom = MO_ATOM_WITHIN16`. Dans `atom_and_align_for_opc`
(`tcg/tcg.c:5531-5539`), comme le backend passe `host_atom = MO_ATOM_IFALIGN != MO_ATOM_WITHIN16`,
il fait `align = MAX(align, size) = MO_64`, donc `a_mask = 7` : les acces MAL alignes seraient
alors devies vers le helper. Mais `aa.align` n'est PAS reinjecte dans `opc` ; l'emetteur inline
teste toujours `memop_alignment_bits(opc)` (= 0) et emet 2x32-bit pour un acces ALIGNE. La
dechirure sur acces aligne persiste donc, lse2 ou pas, ce qui est coherent avec la repro rouge.

## 4. Verdict et hook pour A2/A3

- **A1 ne produit PAS de patch** : le chemin helper est correct, la landmine 128-bit est hors
  sujet. Le seul livrable A1 est cet audit.
- Le fix (lots A2 load, A3 store) est purement dans `tcg/arm/tcg-target.c.inc`. Deux points :

  1. **Emission** : `tcg_out_qemu_ld_direct` / `st_direct` recoivent deja `h` dont le champ
     `h.aa` (`HostAddress`, `:1350-1356`) porte `aa.atom` et `aa.align`. Il faut emettre
     LDRD/STRD quand l'ATOMICITE MO_64 est requise (`h.aa.atom >= MO_64`) et l'acces aligne,
     au lieu de gater sur `memop_alignment_bits(opc)`.
  2. **Deviation du non aligne** : dans `prepare_host_addr`, quand `h->aa.atom == MO_64`,
     forcer `h->aa.align = MAX(h->aa.align, MO_64)` (donc `a_mask = 7`) pour que le cas
     mal aligne parte au slow-path helper (correct, pas de crash) plutot que d'emettre un
     LDRD non aligne (qui faulterait) ou 2x32-bit (qui dechirerait).

- **De-risque pour A2** : la paire de registres necessaire au LDRD est DEJA garantie. Le
  constraint-set de `qemu_ld_a32_i64` est `C_O2_I1(e, p, q)` (`:2202`), ou `e` =
  `ALL_GENERAL_REGS & 0x5555` = registres pairs (`tcg-target-con-str.h:11`), et le store
  utilise `Q` = even qldst (`:14`). Les `tcg_debug_assert((datalo & 1) == 0)` /
  `datahi == datalo + 1` (`:1587-1588`) le confirment a la compilation (build `debug_tcg`).
  Il n'y a donc PAS de travail d'allocation de paires a faire : uniquement changer la
  CONDITION d'emission et la deviation du non aligne.

## 5. Preuve (build vert, audit committe)

```
$ ./build.sh
...
Found ninja-1.11.1 at /usr/bin/ninja
ninja: no work to do.
[build.sh] Build completed. Artifact: /workspace/build-out/qemu-aarch64

$ file build-out/qemu-aarch64
build-out/qemu-aarch64: ELF 32-bit LSB executable, ARM, EABI5 version 1 (GNU/Linux),
statically linked, ... not stripped

$ grep -n CONFIG_ATOMIC64 qemu/build/config-host.h
24:#define CONFIG_ATOMIC64
```

Aucune source qemu modifiee par ce lot (audit seul), le build reste identique a la baseline
B0.2/B0.3 verifiee. Next : A2 (`tcg/arm` qemu_ld MO_64 en LDRD garanti).

## 6. Addendum lot A4 : re-verification post A2/A3 + preuve empirique (dump-tb)

Apres A2/A3, `h.aa.atom >= MO_64` (au lieu de `memop_alignment_bits`) pilote l'emission
LDRD/STRD (`tcg/arm/tcg-target.c.inc:1610` load, `:1719` store). Ce lot verifie que la
chaine frontend qui alimente `h.aa.atom` (section 2 ci-dessus, `finalize_memop` ->
`atom_and_align_for_opc`) tient toujours a l'identique sur l'arbre patche, puis PROUVE
empiriquement (pas seulement par lecture de source) que le code hote emis contient bien
LDRD/STRD pour un acces 64-bit ORDINAIRE de l'invite.

### 6.1 Rien n'a change cote frontend (attendu, verifie a nouveau)

- `finalize_memop` (`translate.h:721-725`) : `atom = s->lse2 ? MO_ATOM_WITHIN16 :
  MO_ATOM_IFALIGN`, inchange. `trans_LDR_i`/`trans_STR_i` (`translate-a64.c:3351`, `:3369`,
  cas reel de ce lot, variante offset immediat non signee) appellent bien
  `finalize_memop(s, a->sz + ...)`, `a->sz = MO_64` pour un GPR 64-bit : chemin identique a
  celui audite en A1 pour `trans_LDR`/`trans_STR` (registre).
- `atom_and_align_for_opc` (`tcg/tcg.c:5508`), appel backend arm inchange
  (`tcg/arm/tcg-target.c.inc:1433` : `atom_and_align_for_opc(s, opc, MO_ATOM_IFALIGN, false)`) :
  `MO_ATOM_IFALIGN` -> `atmax = size = MO_64`, `MO_ATOM_WITHIN16` (si lse2) -> egalement
  `atmax = size = MO_64` (host_atom != MO_ATOM_WITHIN16 force l'alignement, cf section 3.4).
  Dans les deux cas `h.aa.atom` sort a `MO_64` pour un acces ordinaire : aucune regression.
  **Verdict : aucun patch requis, la chaine frontend est saine.**

### 6.2 Decouverte non documentee jusqu'ici : CF_PARALLEL conditionne l'atomicite

En ecrivant le guest minimal de preuve (`test/dump-tb.c`), un premier essai MONO-THREAD a
produit un memop `noat+un+leq` (`MO_ATOM_NONE`, pas `MO_ATOM_IFALIGN`) pour le meme
LDR/STR ordinaire, et donc 2x `ldr`/`str` 32-bit cote hote (pas de LDRD/STRD), MEME SUR
L'ARBRE PATCHE A2/A3. Cause : `tcg_canonicalize_memop` (generique, hors backend arm)
degrade toute exigence d'atomicite a `MO_ATOM_NONE` tant que le TB est compile SANS le
flag `CF_PARALLEL`. Ce flag n'est arme qu'au premier `clone(CLONE_VM)` reussi cote invite
(`linux-user/syscall.c:6605-6608`, avec un `tb_flush` immediat pour invalider les
traductions mono-thread deja en cache). Consequence directe : **un guest aarch64
mono-thread ne demande JAMAIS l'atomicite 64-bit, quel que soit l'alignement** ; c'est
attendu et correct (une dechirure invisible d'un seul thread envers lui-meme n'est pas un
bug), mais cela signifie que `torn64`/`torn64-load` (B0.3, A2) devaient deja etre
multithreades pour observer une dechirure, et que ce lot devait l'etre aussi pour
observer LDRD/STRD. Le guest de preuve a ete corrige : un thread compagnon (`pthread_create`
+ `pthread_join`, inactif) est cree AVANT l'appel de la fonction cible, pour que
`CF_PARALLEL` soit deja actif au moment ou son TB est traduit.

### 6.3 Preuve : `test/dump-tb.sh`

`test/dump-tb.c` isole une fonction `touch64` (un LDR x0,[x2,#0x50] + un STR x1,[x2,#0x50]
ordinaires sur un `volatile uint64_t` aligne) precedee de la creation/jointure d'un thread
compagnon. `test/dump-tb.sh` localise les bornes ELF exactes de `touch64` (`nm -S`,
docker), lance `qemu-aarch64 -dfilter <bornes> -d op,out_asm -D <log>` SUR LE PAD (reutilise
`run-pad.sh` : deploiement, verrou un seul qemu, temperature avant/apres), rapatrie le log
et `grep` `ldrd`/`strd`. La lecture humaine du code hote necessite un desassembleur ARM
(QEMU n'embarque plus de desassembleur arm/x86 interne depuis plusieurs versions) : le
Dockerfile de build embarque desormais `libcapstone-dev:armhf`, et `build.sh` passe
`--enable-capstone` a `configure` (`CONFIG_CAPSTONE` confirme dans `config-host.h`).

Extrait du dump obtenu (guest multithreade, memop `w16+un+leq` = `MO_ATOM_WITHIN16`,
cpu par defaut du binaire de test = LSE2 actif, atomicite requise dans les deux cas) :
```
  -- guest addr 0x0000000000400738
0x008e4af8:  e3170007  tst      r7, #7
0x008e4afc:  1b000016  blne     #0x8e4b5c
0x008e4b00:  e18700db  ldrd     r0, r1, [r7, fp]
  -- guest addr 0x000000000040073c
0x008e4b14:  e3170007  tst      r7, #7
0x008e4b18:  018700fb  strdeq   r0, r1, [r7, fp]
0x008e4b1c:  1b000016  blne     #0x8e4b7c
```
Le `tst addr,#7` + `blne` (deviation non aligne vers le helper) puis `ldrd`/`strd` (cas
aligne) sont exactement la logique posee en A2/A3 (section 4). Log complet committe dans
`test/logs/dump-tb/`.

**Verdict A4 : aucun patch frontend requis (confirme), preuve empirique du LDRD/STRD
obtenue et committee. Next : A5 (stress final Fix A, torn64 N=2/4/8 >= 30 min ou 10^9
iterations + variante non alignee).**
