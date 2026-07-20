# AUDIT V1-SIMD : cause racine de l'assertion `tcg_out_movi: ret < TCG_REG_Q0`

Diagnostic PRECIS du crash SIMD observe en exercant grok sous le fork (cf. PROGRESS.md V1,
log `test/logs/grok-tui/v1-grok-fork-crash-tcg-movi-assert.log`). Etabli par lecture de source
(aucune source qemu modifiee pour cet audit), references ligne a ligne.

## Symptome

```
qemu-aarch64: /workspace/qemu/tcg/arm/tcg-target.c.inc:2437: tcg_out_movi: Assertion `ret < TCG_REG_Q0' failed.
FORK900_EXIT=134   (128 + 6 = SIGABRT)
```

`tcg_out_movi` (materialisation d'un immediat ENTIER) recoit un registre destination
`ret >= TCG_REG_Q0`, c.-a-d. un registre VECTEUR NEON (Q). Un entier ne doit jamais etre
place dans un registre vecteur par ce chemin : les deux asserts de la fonction l'interdisent
(`tcg/arm/tcg-target.c.inc:2436-2437`).

```c
static void tcg_out_movi(TCGContext *s, TCGType type, TCGReg ret, tcg_target_long arg)
{
    tcg_debug_assert(type == TCG_TYPE_I32);   /* 2436 : passe (type entier) */
    tcg_debug_assert(ret < TCG_REG_Q0);        /* 2437 : ECHOUE (ret est un Q) */
    tcg_out_movi32(s, COND_AL, ret, arg);
}
```

## Chaine exacte (localisee de bout en bout)

Le seul opcode dont un operande accepte a la fois entier ET vecteur est `dup_vec`
(`C_O1_I1(w, wr)`), mais il possede un chemin d'allocation dedie (`tcg_reg_alloc_dup`,
`tcg/tcg.c:4697`) qui traite le cas constant proprement (`4717-4725`, `tcg_reg_alloc_do_movi`
sur la sortie VECTEUR). Ce n'est donc PAS `dup_vec`.

La coupable est `INDEX_op_dup2_vec` (assemble une V128 a elements 64 bits a partir de deux
moities de 32 bits, hote 32 bits uniquement) :

1. Contrainte de l'opcode (`tcg/arm/tcg-target.c.inc:2260,2275`) :
   ```
   case INDEX_op_dup2_vec:
       ... return C_O1_I2(w, w, w);
   ```
   Les DEUX entrees sont contraintes `w` = `ALL_VECTOR_REGS` (`0xffff0000`, cf.
   `tcg-target-con-str.h:16` et `tcg-target.c.inc:351`). Vecteur SEULEMENT, aucun registre
   general possible pour ces operandes.

2. Chemin d'allocation dedie `tcg_reg_alloc_dup2` (`tcg/tcg.c:5205`). Il ne traite QUE deux
   cas rapides, puis rend `false` :
   - les deux moities constantes -> promotion en `dupi_vec` (`5243-5257`) ;
   - les deux moities formant une valeur 64 bits contigue en memoire -> `dupm_vec`
     (`5260-5272`) ;
   - sinon `return false` (`5274-5275`).

3. Repli sur le chemin GENERIQUE (`tcg/tcg.c:6237-6248`) :
   ```c
   case INDEX_op_dup2_vec:
       if (tcg_reg_alloc_dup2(s, op)) { break; }
       /* fall through */
   default:
       tcg_reg_alloc_op(s, op);
   ```

4. Dans `tcg_reg_alloc_op`, chaque entree est chargee via `temp_load` avec le masque de la
   contrainte, ici `w` (vecteur seulement). Pour une moitie qui est une CONSTANTE ENTIERE
   (`TEMP_VAL_CONST`, `ts->type == I32`), `temp_load` (`tcg/tcg.c:4437-4441`) fait :
   ```c
   case TEMP_VAL_CONST:
       reg = tcg_reg_alloc(s, desired_regs /* = w, vecteur seul */, ...);  /* -> un Q */
       if (ts->type <= TCG_TYPE_I64) {
           tcg_out_movi(s, ts->type, reg, ts->val);   /* tcg_out_movi(I32, Qreg) -> ABORT */
       } else {
           tcg_out_dupi_vec(...);
       }
   ```
   `desired_regs` ne contient QUE des registres vecteur, donc `tcg_reg_alloc` renvoie
   forcement un Q ; comme le temp est de type entier (`<= TCG_TYPE_I64`), la branche
   `tcg_out_movi` est prise avec `reg >= TCG_REG_Q0` : l'assert `2437` saute.

## Quand la moitie est-elle une constante ?

`dup2_vec` avec UNE SEULE moitie constante n'est PAS repliee par l'optimiseur : `fold_dup2`
(`tcg/optimize.c`) ne plie que si les DEUX moities sont constantes (sinon, si elles sont
copies l'une de l'autre, il reecrit en `dup_vec` ; sinon `return false`). Le cas
"une moitie constante, l'autre variable" survit donc jusqu'au backend.

Motif typique du code JIT (JSC/V8/Bun, donc grok) : broadcast d'une valeur 64 bits dont les
32 bits de poids fort sont une constante connue (souvent 0 par extension de zero d'un 32 bits,
ou un tag/NaN-boxing a poids fort constant) et les 32 bits de poids faible variables :
`DUP Vd.2D, Xn` avec `Xn = zero_extend(Wn)` -> `dup2_vec(lo = variable, hi = const 0)` ->
repli generique -> `tcg_out_movi(I32=0, Qreg)` -> SIGABRT. Cela explique le caractere
"non deterministe" cote grok : le crash est deterministe DES QU'un `dup2_vec` a moitie
constante est emis, mais seuls certains tours JIT de grok emettent ce motif.

## Independance vis-a-vis de Fix A (atomicite 64 bits)

La chaine ci-dessus est integralement en code UPSTREAM 9.2.4 non modifie :
`tcg/tcg.c` (`temp_load`, `tcg_reg_alloc_dup2`, dispatch), `tcg/optimize.c` (`fold_dup2`),
et la contrainte `C_O1_I2(w, w, w)` de `dup2_vec`.

Les deux commits de Fix A ne touchent AUCUN de ces fichiers ni aucun chemin vecteur :

```
$ git -C qemu show --stat f3cc256 1ba623b
commit f3cc256... tcg/arm: emit LDRD ...   tcg/arm/tcg-target.c.inc | 28 (+26 -2)
commit 1ba623b... tcg/arm: emit STRD ...   tcg/arm/tcg-target.c.inc | 12 (+10 -2)
```

Leurs hunks sont confines a `tcg_out_qemu_ld_direct` / `tcg_out_qemu_st_direct` /
`prepare_host_addr` (emission des acces memoire 64 bits ENTIERS). Ni l'allocation de
registres, ni les contraintes de paire (deja en 9.2.4), ni `dup2_vec`, ni `temp_load`, ni
l'optimiseur. Le bug SIMD preexiste donc en baseline 9.2.4 (verifiable en rejouant le repro
minimal sous un qemu non patche, cf. lot V1-SIMD).

## Correction appliquee (commit `tcg/arm: lower dup2_vec from core registers ...`)

Une piste initiale (router la constante vers `tcg_out_dupi_vec` dans `temp_load`) a ete
ECARTEE : elle eviterait l'assertion mais MISCOMPILERAIT. Le repli generique appelle
`tcg_out_dup2_vec` (`tcg-target.c.inc`), qui copie deux registres D ENTIERS (VMOV Dd+1,Dh ;
VMOV Dd,Dl) : il traite ses deux entrees comme des lanes 64 bits, pas comme les deux
moities 32 bits d'UNE valeur. Charger un demi mot 32 bits dans un registre vecteur ne suffit
donc pas ; l'autre ordre d'operandes (moitie variable en registre general) fait meme
echouer `tcg_out_mov(I32, Qreg, GPR)` (renvoie `false`) puis segfaute.

Le fix retenu contraint les deux entrees a des registres GENERAUX et assemble la valeur
64 bits cote entier avant de la diffuser :

1. `tcg-target.c.inc`, `tcg_target_op_def` : `INDEX_op_dup2_vec` passe de
   `C_O1_I2(w, w, w)` a `C_O1_I2(w, r, r)` (nouvel ensemble ajoute a `tcg-target-con-set.h`).
   Le repli generique charge donc chaque moitie dans un GPR (`tcg_out_movi(I32, GPR)` pour la
   constante, aucune assertion), plus dans un registre vecteur.
2. Nouveau lowering `tcg_out_dup2_vec_r(type, rd, rl, rh)` : `VMOV Dd, rl, rh`
   (`INSN_VMOV_D_R2 = 0xec400b10`, deux registres coeur vers un doubleword : `rl` -> `Dd[31:0]`,
   `rh` -> `Dd[63:32]`), donc `Dd = (rh << 32) | rl` = lane 0 ; puis, pour un V128,
   `tcg_out_dup2_vec(rd, rd, rd)` diffuse la lane basse dans la lane haute. Le handler
   `INDEX_op_dup2_vec` de `tcg_out_vec_op` appelle ce nouveau chemin.

Les deux chemins rapides de `tcg_reg_alloc_dup2` (deux moities constantes -> `dupi_vec`,
deux moities contigues en memoire -> `dupm_vec`) sont INCHANGES : seul le repli, qui
avortait, devient correct. Encodage `VMOV Dd, Rt, Rt2` verifie a l'assembleur
(`vmov d0,r0,r1` -> `0xec410b10`, `vmov d2,r3,r4` -> `0xec443b12`, conformes a la formule
`INSN | rh<<16 | rl<<12 | encode_vm(Qreg)`).

Reproducteur `test/simd-dup2.c` : ROUGE avant le fix (SIGABRT, baseline 9.2.4 ET fork),
VERT apres (exit 0, `out[0] == out[1] == ((seed << 32) | 0xff)`, verification de CORRECTION
et pas seulement d'absence de crash). Non-regression Fix A : `torn64` N=4 sans dechirure sur
le binaire rebati a froid. Logs `test/logs/simd/simd-dup2-fix-*-cold.log`.
