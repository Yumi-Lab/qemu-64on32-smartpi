#!/usr/bin/env python3
# V4-1H, ou part l'espace d'adressage HOTE dans le processus qemu au moment du trap.
# Lit un `/proc/PID/maps` du qemu 32 bits (snapshot pris par diag-claude-sigtrap.sh)
# et repond aux deux questions que le Journal laisse ouvertes :
#   1. quels mappings consomment la VA (attribution par proprietaire) ;
#   2. la plus grande plage LIBRE, qui decide si un mmap de taille N pouvait passer.
#
# Le point qui tranche : le guest ne demande PAS la VA totale, il demande UN bloc
# contigu. Un echec ENOMEM se juge donc contre le plus grand TROU, jamais contre la
# somme des trous. Ce script imprime les deux, et ne conclut que sur le trou.
#
# Buckets (proprietaire de la VA, dans l'ordre de specificite) :
#   qemu-host   = l'emulateur lui-meme (image, heap hote, buffer de code TB)
#   guest-image = le binaire invite et ses segments (mappes par le loader qemu)
#   guest-anon  = reservations anonymes du runtime invite (les gros blocs JSC/Bun)
#   sysroot     = interpreteur/bibliotheques musl de l'invite
#   kernel      = vdso/vvar/sigpage/vectors, place par le noyau hote
#
# Usage : va-budget.py <maps.snap> [--ceiling 0xc0000000] [--want-mb N]
#         va-budget.py --selftest
import os
import re
import sys
import tempfile

MAP_LINE = re.compile(r'^([0-9a-f]+)-([0-9a-f]+) (\S{4})\s+\S+ \S+ \S+\s*(.*)$')
MB = 1 << 20

# Plafond de VA utilisateur d'un noyau armv7 VMSPLIT_3G. Le reste appartient au noyau.
DEFAULT_CEILING = 0xC0000000

KERNEL_NAMES = ('[vdso]', '[vvar]', '[sigpage]', '[vectors]')


def classify(name, perms):
    """Attribue un mapping a son proprietaire. `name` est le champ pathname de maps."""
    if name in KERNEL_NAMES:
        return 'kernel'
    if name in ('[heap]', '[stack]'):
        return 'qemu-host'
    # Sur le basename, jamais sur le chemin : le repertoire de travail du pad
    # s'appelle `qemu-fork-test`, un test de sous-chaine y rangerait l'invite
    # dans qemu-host.
    base = name.rsplit('/', 1)[-1]
    if base.startswith('ld-musl') or base.startswith('libc.musl'):
        return 'sysroot'
    if base.startswith('qemu-'):
        return 'qemu-host'
    if name:
        return 'guest-image'
    # Anonyme : le buffer de code TB de qemu est la seule grosse plage executable.
    if 'x' in perms:
        return 'qemu-host'
    return 'guest-anon'


def parse(path, ceiling):
    rows = []
    with open(path) as fh:
        for line in fh:
            m = MAP_LINE.match(line.rstrip('\n'))
            if not m:
                continue
            start, end = int(m.group(1), 16), int(m.group(2), 16)
            if start >= ceiling:
                continue
            rows.append((start, min(end, ceiling), m.group(3), m.group(4).strip()))
    rows.sort()
    return rows


def holes(rows, ceiling):
    """Plages libres sous le plafond, dans l'ordre des adresses."""
    out, prev = [], 0
    for start, end, _, _ in rows:
        if start > prev:
            out.append((prev, start))
        prev = max(prev, end)
    if prev < ceiling:
        out.append((prev, ceiling))
    return out


SELFTEST_MAPS = """\
00010000-00020000 r-xp 00000000 b3:02 129068     /root/qemu-fork-test/qemu-aarch64
00100000-00300000 rwxp 00000000 00:00 0 
01000000-02000000 rw-p 00000000 b3:02 129074     /root/qemu-fork-test/claude-native
10000000-30000000 rw-p 00000000 00:00 0 
b5d34000-b5d44000 r--p 00000000 b3:02 129069     /root/qemu-fork-test/sysroot/lib/ld-musl-aarch64.so.1
bec5b000-bec5d000 r-xp 00000000 00:00 0          [vdso]
ffff0000-ffff1000 r-xp 00000000 00:00 0          [vectors]
"""


def selftest():
    """Verifie l'attribution et l'arithmetique des trous sur une carte connue."""
    fd, path = tempfile.mkstemp(suffix='.snap')
    with os.fdopen(fd, 'w') as fh:
        fh.write(SELFTEST_MAPS)
    try:
        rows = parse(path, DEFAULT_CEILING)
        owners = {}
        for start, end, perms, name in rows:
            owners.setdefault(classify(name, perms), 0)
            owners[classify(name, perms)] += end - start
        checks = [
            # [vectors] est au-dessus du plafond 3 Go : il doit etre exclu.
            ('mapping au-dessus du plafond exclu', len(rows), 6),
            # Le chemin contient "qemu-fork-test" : l'invite ne doit PAS y etre range.
            ('invite classe guest-image', owners.get('guest-image'), 0x1000000),
            # Image qemu (64 Ko) + buffer de code TB anonyme executable (2 Mo).
            ('qemu-host = image + buffer TB', owners.get('qemu-host'), 0x210000),
            ('musl classe sysroot', owners.get('sysroot'), 0x10000),
            ('reservation anonyme = guest-anon', owners.get('guest-anon'), 0x20000000),
            ('vdso classe kernel', owners.get('kernel'), 0x2000),
        ]
        free = holes(rows, DEFAULT_CEILING)
        biggest = max(e - s for s, e in free)
        # Le plus grand trou est 0x30000000..0xb5d34000, pas la somme des trous.
        checks.append(('plus grand trou', biggest, 0xb5d34000 - 0x30000000))
        bad = [(n, got, want) for n, got, want in checks if got != want]
        for name, got, want in checks:
            print(f'  {"ok  " if got == want else "FAIL"} {name}: got={got} want={want}')
        if bad:
            print(f'SELFTEST: ECHEC, {len(bad)} verification(s)')
            return 1
        print(f'SELFTEST: OK, {len(checks)} verifications')
        return 0
    finally:
        os.unlink(path)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit('usage: va-budget.py <maps.snap> [--ceiling 0xc0000000] [--want-mb N]')
    if args[0] == '--selftest':
        return selftest()
    path = args[0]
    ceiling, want_mb = DEFAULT_CEILING, None
    for i, a in enumerate(args):
        if a == '--ceiling':
            ceiling = int(args[i + 1], 0)
        elif a == '--want-mb':
            want_mb = int(args[i + 1])

    rows = parse(path, ceiling)
    if not rows:
        sys.exit(f'va-budget: aucun mapping lisible dans {path}')

    used = sum(e - s for s, e, _, _ in rows)
    free = holes(rows, ceiling)
    free_total = sum(e - s for s, e in free)
    biggest = max(free, key=lambda h: h[1] - h[0])
    biggest_sz = biggest[1] - biggest[0]

    print(f'=== BUDGET VA HOTE, {path} ===')
    print(f'plafond utilisateur : {ceiling / MB:.0f} Mo (0x{ceiling:08x})')
    print(f'occupe              : {used / MB:.1f} Mo en {len(rows)} mappings')
    print(f'libre (somme)       : {free_total / MB:.1f} Mo en {len(free)} trous')
    print(f'libre (plus grand)  : {biggest_sz / MB:.1f} Mo '
          f'a 0x{biggest[0]:08x}   <-- le seul chiffre qui decide d un mmap')

    print('\n--- attribution de la VA occupee ---')
    per = {}
    for start, end, perms, name in rows:
        per.setdefault(classify(name, perms), [0, 0])
        per[classify(name, perms)][0] += end - start
        per[classify(name, perms)][1] += 1
    for owner, (size, count) in sorted(per.items(), key=lambda kv: -kv[1][0]):
        print(f'  {owner:12s} {size / MB:8.1f} Mo  ({count} mappings, '
              f'{100 * size / used:.1f} % de l occupe)')

    print('\n--- plus gros mappings (>= 32 Mo) ---')
    for start, end, perms, name in sorted(rows, key=lambda r: r[0] - r[1]):
        if end - start < 32 * MB:
            break
        print(f'  0x{start:08x}-0x{end:08x} {(end - start) / MB:8.1f} Mo {perms} '
              f'{classify(name, perms):12s} {name}')

    print('\n--- trous libres (>= 16 Mo) ---')
    for start, end in sorted(free, key=lambda h: h[0] - h[1]):
        if end - start < 16 * MB:
            break
        print(f'  0x{start:08x}-0x{end:08x} {(end - start) / MB:8.1f} Mo')

    if want_mb is not None:
        ok = biggest_sz >= want_mb * MB
        print(f'\n=== VERDICT pour une demande de {want_mb} Mo d un seul tenant ===')
        print(f'  plus grand trou = {biggest_sz / MB:.1f} Mo -> '
              f'{"TIENT" if ok else "NE TIENT PAS"}')
        if not ok:
            deficit = want_mb * MB - biggest_sz
            print(f'  deficit = {deficit / MB:.1f} Mo. Defragmenter parfaitement la VA '
                  f'donnerait {free_total / MB:.1f} Mo,')
            print(f'  {"ce qui SUFFIRAIT" if free_total >= want_mb * MB else "ce qui NE SUFFIRAIT TOUJOURS PAS"} '
                  f': le compactage est '
                  f'{"une piste" if free_total >= want_mb * MB else "arithmetiquement inutile"}.')
        return 0 if ok else 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
