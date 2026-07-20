/*
 * simd-dup2.c : reproducteur minimal de l'assertion tcg_out_movi (lot V1-SIMD).
 *
 * But : provoquer de maniere DETERMINISTE le SIGABRT
 *   tcg/arm/tcg-target.c.inc:2437 tcg_out_movi: Assertion `ret < TCG_REG_Q0'
 * observe en exercant grok sous le fork (cf. docs/AUDIT-simd-movi.md, PROGRESS.md V1).
 *
 * Mecanisme (cf. audit) : sur hote 32 bits, un `DUP Vd.2D, Xn` est abaisse par
 * le frontend aarch64 en `INDEX_op_dup2_vec(ri, lo, hi)` ou lo/hi sont les deux
 * moities 32 bits de Xn. Si UNE seule moitie est une constante ENTIERE :
 *   - fold_dup2 (tcg/optimize.c) ne plie QUE si les DEUX moities sont constantes,
 *     donc l'op survit jusqu'au backend ;
 *   - la moitie constante est reecrite par copy_propagate en un temp tcg_constant
 *     NON adjacent, donc le chemin dedie tcg_reg_alloc_dup2 (tcg/tcg.c) echoue son
 *     test dupm (adjacence) ET son test dupi (les deux moities constantes) ;
 *   - repli sur le chemin generique : temp_load charge la constante entiere dans
 *     un registre VECTEUR force (contrainte C_O1_I2(w,w,w)) via tcg_out_movi(I32,
 *     Qreg) -> l'assert `ret < TCG_REG_Q0' avorte.
 *
 * Ordre des operandes : le frontend emet dup2_vec(ri, al = moitie BASSE, ah =
 * moitie HAUTE) et tcg_reg_alloc_op traite les entrees dans l'ordre. Pour que le
 * chemin qui avorte (tcg_out_movi sur la constante) soit atteint AVANT le chemin
 * de la moitie variable (un tcg_out_mov I32 inter-banc GPR->Q qui, lui, segfault
 * silencieusement), on met la CONSTANTE en moitie BASSE (al, entree n0 1) et la
 * VARIABLE en moitie HAUTE. On construit donc Xn = (variable << 32) | const_bas.
 *
 * Resultat attendu :
 *   - qemu SANS le fix (baseline 9.2.4 ET fork actuel, meme code upstream sur ce
 *     chemin) : SIGABRT `ret < TCG_REG_Q0', exit 134.
 *   - qemu AVEC le fix (prochain lot) : imprime la valeur et exit 0, chaque lane
 *     64 bits valant ((uint64_t)seed << 32) | LOW_CONST.
 */
#include <stdint.h>
#include <stdio.h>

/* Constante de la moitie basse. DOIT rester synchronisee avec l'immediat
   litteral `#0xff` de l'asm ci-dessous (immediat logique aarch64 valide). */
#define LOW_CONST 0xffu

int main(int argc, char **argv)
{
    (void)argv;

    /* seed : depend de argc, donc VARIABLE pour TCG (pas de repli en constante).
       32 bits : reste dans un W-registre, poids fort a zero. */
    uint32_t seed = 0x22222222u ^ (uint32_t)argc;

    uint64_t out[2] = { 0, 0 };

    /*
     * mov  w10, seed        -> x10 = zero_extend(seed) (poids fort = 0).
     * lsl  x9, x10, #32      -> x9 : poids faible = 0 (CONST), poids fort = seed (VAR).
     * orr  x9, x9, #LOW_CONST-> poids faible = LOW_CONST (CONST), poids fort inchange (VAR).
     * dup  v0.2d, x9         -> dup2_vec(al = LOW_CONST const, ah = seed variable).
     * st1  {v0.2d}, [out]    -> rapatrie les deux lanes pour verification.
     */
    __asm__ volatile(
        "mov   w10, %w[seed]\n\t"
        "lsl   x9, x10, #32\n\t"
        "orr   x9, x9, #0xff\n\t"
        "dup   v0.2d, x9\n\t"
        "st1   {v0.2d}, [%[dst]]\n\t"
        :
        : [seed] "r"(seed), [dst] "r"(out)
        : "w10", "x10", "x9", "v0", "memory");

    printf("dup2 out[0]=0x%016llx out[1]=0x%016llx (seed=0x%08x)\n",
           (unsigned long long)out[0], (unsigned long long)out[1],
           (unsigned)seed);

    /* Verification de CORRECTION (pertinente APRES le fix) : chaque lane 64 bits
       doit valoir ((uint64_t)seed << 32) | LOW_CONST. Un fix qui ne fait
       qu'eviter le crash sans corriger l'abaissement produirait ici une valeur
       fausse (exit 2), ce qui distingue "ne crashe plus" de "correct". */
    uint64_t expect = ((uint64_t)seed << 32) | LOW_CONST;
    if (out[0] != expect || out[1] != expect) {
        fprintf(stderr, "MISCOMPILE: attendu 0x%016llx dans les deux lanes\n",
                (unsigned long long)expect);
        return 2;
    }

    printf("OK: dup2_vec correct (les deux lanes = 0x%016llx)\n",
           (unsigned long long)expect);
    return 0;
}
