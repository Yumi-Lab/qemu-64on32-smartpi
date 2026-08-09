/*
 * tb-dedup-guest.c : exerciseur DETERMINISTE de la memoisation par contenu
 * (phase V4, item 5 du RESTE de V4-1). Force la MEME fonction invitee traduite
 * a N ADRESSES distinctes = N traductions froides de meme cle de contenu
 * (net_key), donc N-1 occasions d'installation d'un hit dedup.
 *
 * Pourquoi ce guest, et pas claude --version : la sonde d'install (sous-lot 13)
 * ne peut reporter probe_ok que si un template ANTERIEUR de meme net_key existe
 * ET si l'installateur rebase correctement les octets qui encodent l'ADRESSE
 * invitee. claude fabrique bien de tels templates mais de facon non
 * deterministe (le hit rate depend du JIT invite). Ici la reutilisation est
 * GARANTIE et CHIFFREE : N copies byte-identiques de la source invitee, une par
 * page, donc l'orchestrateur peut exiger probe_ok == N-1 (une seule froide) et
 * probe_mismatch == 0.
 *
 * Le corps de chaque copie contient un `adr x0, .` : sur la config user-mode
 * aarch64 (non CF_PCREL), le frontend materialise l'ADRESSE INVITEE ABSOLUE de
 * l'instruction (gen_pc_plus_diff -> movw/movt cote hote), qui DIFFERE d'une
 * copie a l'autre. C'est exactement la relocation GUEST_PC que le sous-lot 14
 * enregistre : si le rebase la reproduit a l'octet pres, probe_ok ; sinon
 * probe_mismatch (repli froid, jamais d'install faux). Le guest exerce donc le
 * maillon precis que V4-1 doit prouver.
 *
 * Les octets SOURCE des N copies sont identiques (meme `adr x0,.` + `ret`), donc
 * meme src_key ; flags/cflags/cs_base d'un TB non-CF_PCREL a la meme frontiere
 * de page sont identiques -> meme net_key. La seule difference hote legitime est
 * l'adresse invitee absolue baked, couverte par la reloc GUEST_PC.
 *
 * Sortie machine (derniere ligne) :
 *   RESULT=<OK|MISMATCH|SETUP> copies=<N> calls_ok=<n>
 *   OK       = les N copies se sont executees et ont rendu leur propre adresse.
 *   MISMATCH = une copie a rendu une adresse != la sienne (bug d'execution guest,
 *              pas un verdict dedup : le verdict dedup est la ligne tb-dedup-index
 *              emise par qemu sous QEMU_TB_DEDUP_LOG a la sortie).
 *   SETUP    = echec mmap / mise en place.
 *
 * Ce binaire ne LIT PAS les compteurs dedup (ils vivent dans qemu) : il se
 * contente de GARANTIR N traductions froides de meme net_key. Le juge est la
 * ligne `tb-dedup-index: ... probe_ok=.. probe_mismatch=..` de qemu.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

/*
 * Corps invite, DEUX mots aarch64, source byte-identique dans chaque copie :
 *   adr x0, .   = 0x10000000  (immhi=0, immlo=0, Rd=0 : x0 <- PC de l'adr)
 *   ret         = 0xd65f03c0
 * `adr x0, .` charge l'ADRESSE INVITEE de l'instruction elle-meme : la valeur
 * rendue est propre a chaque copie (sa page), ce qui verifie que le rebase a
 * bien produit du code correct et pas le PC d'une autre copie.
 */
#define ADR_X0_HERE 0x10000000u
#define RET_X30     0xd65f03c0u
#define FN_WORDS    2

typedef uint64_t (*fn_t)(void);

/* Nombre de copies par defaut : > 1 pour au moins une install, borne modeste
 * pour rester leger sur le pad (une page par copie). Surchargeable en argv[1]. */
#define DEFAULT_COPIES 64
#define MAX_COPIES     4096

static void write_body(volatile uint32_t *dst)
{
    dst[0] = ADR_X0_HERE;
    dst[1] = RET_X30;
}

int main(int argc, char **argv)
{
    long copies = DEFAULT_COPIES;
    if (argc >= 2) {
        char *end = NULL;
        long v = strtol(argv[1], &end, 10);
        if (end == argv[1] || *end != '\0' || v < 2 || v > MAX_COPIES) {
            fprintf(stderr, "usage: %s [copies:2..%d]\n", argv[0], MAX_COPIES);
            return 1;
        }
        copies = v;
    }

    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        ps = 4096;
    }

    printf("tb-dedup-guest: %ld copies byte-identiques de `adr x0,. ; ret`, "
           "une par page de %ld o\n", copies, ps);

    fn_t *fns = calloc((size_t)copies, sizeof(*fns));
    if (fns == NULL) {
        fprintf(stderr, "SETUP: calloc\n");
        printf("RESULT=SETUP copies=%ld calls_ok=0\n", copies);
        return 1;
    }

    /*
     * Une page RWX privee par copie : ecrire le corps puis synchroniser les
     * caches (le code frais doit etre visible du I-side ; sur un guest reel un
     * JIT ferait __builtin___clear_cache, ce qui emet DC CVAU + IC IVAU). Chaque
     * page est une ADRESSE INVITEE distincte, donc une traduction froide
     * distincte du meme corps.
     */
    for (long i = 0; i < copies; i++) {
        void *p = mmap(NULL, (size_t)ps, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            fprintf(stderr, "SETUP: mmap copie %ld\n", i);
            printf("RESULT=SETUP copies=%ld calls_ok=%ld\n", copies, i);
            return 1;
        }
        write_body((volatile uint32_t *)p);
        __builtin___clear_cache((char *)p, (char *)p + FN_WORDS * 4);
        fns[i] = (fn_t)p;
    }

    /*
     * Appeler chaque copie une fois. Le premier appel de CHAQUE page force une
     * traduction froide (adresse invitee inedite) ; sous QEMU_TB_DEDUP=1 la
     * sonde d'install cherche un template anterieur de meme net_key : absent
     * pour la 1re copie (probe_skip), present pour les copies 2..N (probe_ok si
     * le rebase GUEST_PC reproduit les octets froids, probe_mismatch sinon).
     * Chaque copie doit rendre SA propre adresse (adr x0,.).
     */
    long calls_ok = 0;
    int mismatch = 0;
    for (long i = 0; i < copies; i++) {
        uint64_t got = fns[i]();
        uint64_t want = (uint64_t)(uintptr_t)fns[i];
        if (got == want) {
            calls_ok++;
        } else {
            mismatch = 1;
            fprintf(stderr,
                    "MISMATCH copie %ld : got=0x%016llx want=0x%016llx\n",
                    i, (unsigned long long)got, (unsigned long long)want);
            break;
        }
    }

    if (mismatch) {
        printf("RESULT=MISMATCH copies=%ld calls_ok=%ld\n", copies, calls_ok);
        return 2;
    }

    printf("RESULT=OK copies=%ld calls_ok=%ld\n", copies, calls_ok);
    printf("juge dedup : lire la ligne `tb-dedup-index: ... probe_ok probe_mismatch` "
           "emise par qemu sous QEMU_TB_DEDUP=1 QEMU_TB_DEDUP_LOG=1 ; "
           "attendu probe_mismatch=0 et probe_ok>0 (idealement copies-1)\n");
    return 0;
}
