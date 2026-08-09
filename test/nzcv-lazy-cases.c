/*
 * nzcv-lazy-cases.c : test differentiel de correctness du NZCV paresseux (lot L1).
 *
 * But : exercer les sequences vicieuses du design (docs/NZCV-LAZY-DESIGN.md,
 * section 6) ou une SUBS/CMP 64 bit definit les flags mais ne les materialise
 * qu'a la lecture sous QEMU_NZCV_LAZY=1. Chaque cas compare le NZCV (ou le
 * resultat) OBSERVE par de l'asm aarch64 reel contre une REFERENCE calculee en
 * C portable (la verite terrain). Le meme binaire doit passer flag ON comme
 * flag OFF ; toute divergence = ABORT avec le cas et les valeurs fautives.
 *
 * Couvre :
 *   1. MRS NZCV apres SUBS 64 bit         -> materialisation des 4 flags (gen_get_nzcv)
 *   2. B.cond (via CSET) apres SUBS        -> chemin arm_test_cc (les 14 conditions)
 *   3. CCMP apres SUBS                      -> materialisation interne de disas_cc
 *   4. MSR NZCV apres SUBS lazy             -> reset CC_OP_FLAGS (gen_set_nzcv)
 *   5. SBC apres SUBS (chaine de retenue)   -> lecture du carry entrant (gen_adc)
 *
 * Zero mesure de temps : correctness pure, reproductible en env imbrique comme
 * sur le pad. Exit 0 = tout passe, 1 = divergence (message explicite).
 */
#include <stdint.h>
#include <stdio.h>

/* ----- References en C portable ----- */

/* NZCV (4 bits N Z C V) d'une soustraction 64 bit a - b, semantique aarch64. */
static unsigned ref_sub_nzcv(uint64_t a, uint64_t b)
{
    uint64_t r = a - b;
    unsigned N = (unsigned)(r >> 63) & 1u;
    unsigned Z = (r == 0);
    unsigned C = (a >= b);                             /* carry = pas d'emprunt */
    unsigned V = (unsigned)(((a ^ b) & (a ^ r)) >> 63) & 1u;
    return (N << 3) | (Z << 2) | (C << 1) | V;
}

/* Evalue une condition aarch64 (cc 0..15) sur un champ NZCV (N Z C V). */
static int eval_cond(unsigned cc, unsigned nzcv)
{
    unsigned N = (nzcv >> 3) & 1, Z = (nzcv >> 2) & 1;
    unsigned C = (nzcv >> 1) & 1, V = nzcv & 1;
    int r = 0;

    switch (cc >> 1) {
    case 0: r = Z; break;                 /* EQ / NE */
    case 1: r = C; break;                 /* CS / CC */
    case 2: r = N; break;                 /* MI / PL */
    case 3: r = V; break;                 /* VS / VC */
    case 4: r = C && !Z; break;           /* HI / LS */
    case 5: r = (N == V); break;          /* GE / LT */
    case 6: r = (N == V) && !Z; break;    /* GT / LE */
    case 7: r = 1; break;                 /* AL (14/15) */
    }
    /* Bit bas inverse la condition, sauf le couple "always" (14/15). */
    if ((cc & 1) && (cc >> 1) != 7) {
        r = !r;
    }
    return r;
}

/* ----- Sequences asm reelles (forcent SUBS 64 bit + lecture) ----- */

/* SUBS xzr, a, b ; MRS out, NZCV. Renvoie le champ NZCV (4 bits). */
static unsigned asm_subs_mrs(uint64_t a, uint64_t b)
{
    uint64_t nzcv;
    __asm__ volatile(
        "subs xzr, %1, %2\n\t"
        "mrs  %0, nzcv\n\t"
        : "=r"(nzcv)
        : "r"(a), "r"(b)
        : "cc");
    return (unsigned)((nzcv >> 28) & 0xFu);
}

/* SUBS xzr, a, b ; CSET out, <cc>. Renvoie 0/1. Un cas par condition pour que
 * le mnemonic soit un litteral (contrainte de l'asm inline). */
static int asm_subs_cset(uint64_t a, uint64_t b, unsigned cc)
{
    uint64_t o = 0;
    switch (cc) {
    case 0:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,eq":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 1:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,ne":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 2:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,cs":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 3:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,cc":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 4:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,mi":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 5:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,pl":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 6:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,vs":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 7:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,vc":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 8:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,hi":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 9:  __asm__ volatile("subs xzr,%1,%2\n\tcset %0,ls":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 10: __asm__ volatile("subs xzr,%1,%2\n\tcset %0,ge":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 11: __asm__ volatile("subs xzr,%1,%2\n\tcset %0,lt":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 12: __asm__ volatile("subs xzr,%1,%2\n\tcset %0,gt":"=r"(o):"r"(a),"r"(b):"cc"); break;
    case 13: __asm__ volatile("subs xzr,%1,%2\n\tcset %0,le":"=r"(o):"r"(a),"r"(b):"cc"); break;
    }
    return (int)o;
}

/* SUBS xzr, a, b ; CCMP n, m, #imm, <cond=NE(1)> ; MRS out. Le CCMP lit le
 * NZCV de la SUBS (test exterieur), puis fusionne bit a bit : c'est le cas 1 du
 * design (materialisation interne de disas_cc). cond=NE fixe en litteral. */
static unsigned asm_subs_ccmp_ne(uint64_t a, uint64_t b,
                                 uint64_t n, uint64_t m, unsigned imm)
{
    uint64_t nzcv;
    switch (imm & 0xF) {
    case 0x0: __asm__ volatile("subs xzr,%1,%2\n\tccmp %3,%4,#0,ne\n\tmrs %0,nzcv":"=r"(nzcv):"r"(a),"r"(b),"r"(n),"r"(m):"cc"); break;
    case 0x6: __asm__ volatile("subs xzr,%1,%2\n\tccmp %3,%4,#6,ne\n\tmrs %0,nzcv":"=r"(nzcv):"r"(a),"r"(b),"r"(n),"r"(m):"cc"); break;
    case 0xF: __asm__ volatile("subs xzr,%1,%2\n\tccmp %3,%4,#15,ne\n\tmrs %0,nzcv":"=r"(nzcv):"r"(a),"r"(b),"r"(n),"r"(m):"cc"); break;
    default:  __asm__ volatile("subs xzr,%1,%2\n\tccmp %3,%4,#0,ne\n\tmrs %0,nzcv":"=r"(nzcv):"r"(a),"r"(b),"r"(n),"r"(m):"cc"); break;
    }
    return (unsigned)((nzcv >> 28) & 0xFu);
}

/* SUBS xzr, a, b (lazy) ; MSR NZCV, val ; MRS out. Doit rendre le NZCV de val,
 * jamais un recalcul de la SUBS : valide le reset CC_OP_FLAGS de gen_set_nzcv. */
static unsigned asm_subs_msr_mrs(uint64_t a, uint64_t b, unsigned val_nzcv)
{
    uint64_t in = (uint64_t)(val_nzcv & 0xFu) << 28;
    uint64_t out;
    __asm__ volatile(
        "subs xzr, %1, %2\n\t"
        "msr  nzcv, %3\n\t"
        "mrs  %0, nzcv\n\t"
        : "=r"(out)
        : "r"(a), "r"(b), "r"(in)
        : "cc");
    return (unsigned)((out >> 28) & 0xFu);
}

/* SUBS lo, aL, bL ; SBC hi, aH, bH : soustraction 128 bit, le SBC consomme le
 * carry entrant de la SUBS (cas gen_adc). Valide la lecture du carry lazy. */
static void asm_subs_sbc(uint64_t aL, uint64_t aH, uint64_t bL, uint64_t bH,
                         uint64_t *rL, uint64_t *rH)
{
    __asm__ volatile(
        "subs %0, %2, %4\n\t"
        "sbc  %1, %3, %5\n\t"
        : "=&r"(*rL), "=&r"(*rH)
        : "r"(aL), "r"(aH), "r"(bL), "r"(bH)
        : "cc");
}

/* ----- Harnais ----- */

static const uint64_t POOL[] = {
    0, 1, 2, 0x7fffffffffffffffULL, 0x8000000000000000ULL,
    0xffffffffffffffffULL, 0x100000000ULL, 0xdeadbeefULL,
    0x00000000ffffffffULL, 0x123456789abcdef0ULL, 0x8000000000000001ULL,
};
#define NPOOL (sizeof(POOL) / sizeof(POOL[0]))

static int failures;
static long checks;

static void fail(const char *what, uint64_t a, uint64_t b,
                 unsigned got, unsigned want)
{
    failures++;
    printf("FAIL %-14s a=%016llx b=%016llx got=%x want=%x\n",
           what, (unsigned long long)a, (unsigned long long)b, got, want);
}

int main(void)
{
    size_t i, j;
    unsigned cc, imm;

    for (i = 0; i < NPOOL; i++) {
        for (j = 0; j < NPOOL; j++) {
            uint64_t a = POOL[i], b = POOL[j];
            unsigned ref = ref_sub_nzcv(a, b);

            /* Cas 2 : MRS NZCV apres SUBS. */
            unsigned mrs = asm_subs_mrs(a, b);
            checks++;
            if (mrs != ref) {
                fail("mrs-nzcv", a, b, mrs, ref);
            }

            /* Cas 3 (B.cond) : les 14 conditions via CSET. */
            for (cc = 0; cc <= 13; cc++) {
                int got = asm_subs_cset(a, b, cc);
                int want = eval_cond(cc, ref);
                checks++;
                if (got != want) {
                    fail("cset", a, b, (unsigned)got, (unsigned)want);
                }
            }

            /* Cas 4 : MSR NZCV apres SUBS lazy, doit ecraser. */
            for (imm = 0; imm <= 15; imm++) {
                unsigned got = asm_subs_msr_mrs(a, b, imm);
                checks++;
                if (got != imm) {
                    fail("msr-nzcv", a, b, got, imm);
                }
            }
        }
    }

    /* Cas 1 : CCMP apres SUBS (test exterieur NE + fusion). */
    for (i = 0; i < NPOOL; i++) {
        for (j = 0; j < NPOOL; j++) {
            uint64_t a = POOL[i], b = POOL[j];
            uint64_t n = POOL[(i + 3) % NPOOL], m = POOL[(j + 5) % NPOOL];
            unsigned subs = ref_sub_nzcv(a, b);
            unsigned imms[3] = {0x0, 0x6, 0xF};
            size_t k;

            for (k = 0; k < 3; k++) {
                unsigned im = imms[k];
                /* cond = NE (cc 1) evaluee sur le NZCV de la SUBS. */
                unsigned want = eval_cond(1, subs) ? ref_sub_nzcv(n, m) : im;
                unsigned got = asm_subs_ccmp_ne(a, b, n, m, im);
                checks++;
                if (got != want) {
                    fail("ccmp", a, b, got, want);
                }
            }
        }
    }

    /* Cas 5 : SBC apres SUBS (chaine de retenue 128 bit). */
    for (i = 0; i < NPOOL; i++) {
        for (j = 0; j < NPOOL; j++) {
            uint64_t aL = POOL[i], aH = POOL[j];
            uint64_t bL = POOL[j], bH = POOL[i];
            uint64_t rL = 0, rH = 0;
            unsigned __int128 A = ((unsigned __int128)aH << 64) | aL;
            unsigned __int128 B = ((unsigned __int128)bH << 64) | bL;
            unsigned __int128 R = A - B;
            asm_subs_sbc(aL, aH, bL, bH, &rL, &rH);
            checks++;
            if (rL != (uint64_t)R || rH != (uint64_t)(R >> 64)) {
                printf("FAIL sbc a=%016llx:%016llx b=%016llx:%016llx "
                       "got=%016llx:%016llx want=%016llx:%016llx\n",
                       (unsigned long long)aH, (unsigned long long)aL,
                       (unsigned long long)bH, (unsigned long long)bL,
                       (unsigned long long)rH, (unsigned long long)rL,
                       (unsigned long long)(uint64_t)(R >> 64),
                       (unsigned long long)(uint64_t)R);
                failures++;
            }
        }
    }

    printf("nzcv-lazy-cases: %ld checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
