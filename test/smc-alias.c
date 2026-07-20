/*
 * smc-alias.c : caracterisation du piege #2 (Fix B), code JIT auto-modifiant via
 * un alias dual-mappe W^X (lot B1).
 *
 * Contexte (cf. GOAL.md Fix B, bug upstream #1034) : JSC/V8/Bun ecrivent leur code
 * JIT via un alias WRITABLE d'une page W^X (memfd) et l'executent via l'alias
 * EXECUTABLE. En user-mode, qemu protege en ecriture la page GUEST d'ou un TB a
 * ete traduit (l'alias X) : une ecriture sur CETTE page virtuelle faute et
 * invalide le TB. Mais l'ecriture passe par une AUTRE page virtuelle (l'alias W) :
 * aucune faute, aucune invalidation. La memoire physique (memfd MAP_SHARED) change
 * bien, mais le TB de l'alias X reste tel quel -> risque d'executer du code perime.
 *
 * DECOUVERTE de ce lot (verifiee en source, cf. Journal B1) : la premisse "IC IVAU
 * est un NOP en user-mode" est FAUSSE des qemu 9.2.4. Le backend implemente
 * `ic_ivau_write` (target/arm/helper.c, CONFIG_USER_ONLY) qui appelle
 * `tb_invalidate_phys_range` sur la plage de la ligne de cache visee, ET clear
 * CTR_EL0.DIC (target/arm/cpu.c) pour FORCER les JIT a emettre IC IVAU. C'est
 * exactement le correctif que "Fix B / B2" visait : il est deja present upstream.
 *
 * Ce test le PROUVE en deux modes, pour isoler le seul IC IVAU comme facteur :
 *   - mode "nosync"  : ecrit le nouveau code via l'alias W, DSB (visibilite de la
 *                      store), PAS de IC IVAU, puis execute via l'alias X.
 *                      Attendu : ROUGE (STALE) -> qemu manque l'ecriture via
 *                      l'alias, le TB de X n'est pas invalide, code perime execute.
 *                      Demontre la faille SMC-via-alias sous-jacente.
 *   - mode "sync" (defaut) : ecrit via W, DC CVAU, DSB, IC IVAU sur X, DSB, ISB
 *                      (la maintenance de cache exacte qu'emet un JIT correct via
 *                      __builtin___clear_cache), puis execute via X.
 *                      Attendu : VERT (FRESH) -> IC IVAU invalide le TB, code frais
 *                      execute a chaque tour. Confirme que 9.2.4 corrige deja #1034.
 *
 * Deroulement commun : boucle ROUNDS fois en ALTERNANT deux versions du code
 * (GOAL : "boucle avec code change"). Chaque tour ecrit `movz w0,#marker ; ret`
 * via l'alias W, applique la maintenance du mode, appelle la fonction via l'alias
 * X, verifie la valeur. Le tour 0 cree la premiere traduction (MARKER1, OK) ; des
 * le tour 1 (code reecrit MARKER2), si la valeur rendue est encore MARKER1, c'est
 * du CODE PERIME.
 *
 * Sorties :
 *   - exit 0 : SUCCESS, code FRAIS a chaque tour (attendu en mode sync).
 *   - exit 3 : STALE, code perime execute (attendu en mode nosync).
 *   - exit 2 : valeur inattendue (ni le code frais ni le precedent).
 *   - exit 1 : erreur de mise en place (memfd/mmap/ftruncate) ou argument invalide.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

/* Deux marqueurs distincts, <= 0xFFFF pour tenir dans l'immediat de MOVZ Wd,#imm16. */
#define MARKER1 0x1111u
#define MARKER2 0x2222u

#define ROUNDS 8

typedef uint32_t (*fn_t)(void);

/*
 * Ecrit `movz w0, #marker ; ret` (deux mots aarch64) a l'adresse dst (alias W).
 *   movz w0, #imm16 = 0x52800000 | (imm16 << 5) | Rd(=0)   (verifie a l'assembleur)
 *   ret (x30)       = 0xd65f03c0
 * dst volatile : la store ne doit pas etre elidee ni reordonnee par le compilateur.
 */
static void write_fn(volatile uint32_t *dst, uint32_t marker)
{
    dst[0] = 0x52800000u | (marker << 5);  /* movz w0, #marker */
    dst[1] = 0xd65f03c0u;                  /* ret              */
}

/*
 * Maintenance de cache pour code auto-modifiant.
 *   ic_ivau != 0 (mode sync) : sequence complete qu'emet un JIT correct
 *     (equivalent __builtin___clear_cache) : DC CVAU sur l'alias W, DSB, IC IVAU
 *     sur l'alias X, DSB, ISB. C'est le IC IVAU qui, en 9.2.4 user-mode, invalide
 *     le TB (tb_invalidate_phys_range).
 *   ic_ivau == 0 (mode nosync) : DSB seule (rend la store visible), AUCUN IC IVAU.
 *     Isole l'effet du seul IC IVAU : sans lui, qemu ne voit pas l'ecriture via
 *     l'alias -> code perime.
 * Tailles de ligne lues dans CTR_EL0 (Imin/DminLine = log2 du nb de mots de 4o).
 */
static void sync_icache(void *wr, void *ex, size_t len, int ic_ivau)
{
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    size_t dline = (size_t)4u << ((ctr >> 16) & 0xf);  /* DminLine -> octets */
    size_t iline = (size_t)4u << (ctr & 0xf);          /* IminLine -> octets */
    uintptr_t w = (uintptr_t)wr, e = (uintptr_t)ex;

    if (!ic_ivau) {
        __asm__ volatile("dsb ish" ::: "memory");
        return;
    }

    for (uintptr_t p = w & ~(dline - 1); p < w + len; p += dline)
        __asm__ volatile("dc cvau, %0" :: "r"(p) : "memory");
    __asm__ volatile("dsb ish" ::: "memory");

    for (uintptr_t p = e & ~(iline - 1); p < e + len; p += iline)
        __asm__ volatile("ic ivau, %0" :: "r"(p) : "memory");
    __asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

int main(int argc, char **argv)
{
    int ic_ivau = 1;                 /* defaut : mode sync (avec IC IVAU) */
    const char *mode = "sync";
    if (argc >= 2) {
        if (strcmp(argv[1], "nosync") == 0) {
            ic_ivau = 0;
            mode = "nosync";
        } else if (strcmp(argv[1], "sync") == 0) {
            ic_ivau = 1;
            mode = "sync";
        } else {
            fprintf(stderr, "usage: %s [sync|nosync]\n", argv[0]);
            return 1;
        }
    }

    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0)
        ps = 4096;

    int fd = memfd_create("smc-alias", 0);
    if (fd < 0) {
        perror("memfd_create");
        return 1;
    }
    if (ftruncate(fd, ps) != 0) {
        perror("ftruncate");
        return 1;
    }

    /* Alias W (ecriture) et alias X (execution) de la MEME page physique memfd. */
    void *w = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    void *x = mmap(NULL, (size_t)ps, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    if (w == MAP_FAILED || x == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    if (w == x) {
        fprintf(stderr, "SETUP: les deux alias ont la meme adresse, dual-map non obtenu\n");
        return 1;
    }
    printf("mode=%s (IC IVAU %s) | memfd dual-map W^X : w_alias=%p (RW) x_alias=%p (RX), page=%ld\n",
           mode, ic_ivau ? "emis" : "OMIS", w, x, ps);

    fn_t fn = (fn_t)x;
    const uint32_t markers[2] = { MARKER1, MARKER2 };
    int stale_round = -1;
    uint32_t got = 0, want = 0;

    for (int i = 0; i < ROUNDS; i++) {
        want = markers[i & 1];
        write_fn((volatile uint32_t *)w, want);   /* ecrit le nouveau code via W */
        sync_icache(w, x, 8, ic_ivau);              /* maintenance selon le mode   */
        got = fn();                                 /* execute via X               */
        printf("round %d : want=0x%04x got=0x%04x %s\n",
               i, want, got, got == want ? "OK" : "MISMATCH");
        if (got != want) {
            stale_round = i;
            break;
        }
    }

    if (stale_round < 0) {
        printf("SUCCESS: code frais execute a chaque tour (%d tours) [mode=%s]\n",
               ROUNDS, mode);
        return 0;
    }

    /* Le code du tour precedent est l'autre marqueur ; s'il est rendu, c'est du
       code PERIME (le TB n'a pas ete invalide). Sinon, defaut different. */
    uint32_t prev = markers[(stale_round & 1) ^ 1];
    if (got == prev) {
        printf("STALE au round %d : code perime execute (got=0x%04x = code du tour precedent, "
               "attendu 0x%04x) [mode=%s]\n", stale_round, got, want, mode);
        printf("l'ecriture via l'alias W n'a pas invalide le TB de l'alias X, et sans "
               "IC IVAU qemu ne le detecte pas\n");
        return 3;
    }

    printf("UNEXPECTED au round %d : got=0x%04x (ni le code frais 0x%04x ni le precedent 0x%04x) [mode=%s]\n",
           stale_round, got, want, prev, mode);
    return 2;
}
