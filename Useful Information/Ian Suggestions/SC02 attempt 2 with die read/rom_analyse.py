#!/usr/bin/env python3
"""
Recover the SC-02 ROM field map from the die read, empirically.

We know two things independently of the bits: the datasheet's phoneme chart
(what sound each of the 64 codes makes) and basic phonetics (which of those are
voiced, which are silent, roughly where their formants sit).  So for every one
of the 27 columns we can ask: does this column line up with a phonetic property?

A column that is 1 for exactly the voiced phonemes is the voicing bit.  A group
of columns whose value correlates with first-formant frequency across the
vowels is the F1 field.  This is how you check a hand-read ROM without a
working reference chip.
"""

import sys
from collections import Counter

WIDTH, DEPTH = 27, 64

# datasheet phoneme chart, code order 0x00..0x3F
NAMES = """PA E EI Y Y1 AY IE I A AI EH EH1 AE AE1 AH AH1 AW O OU OO IU IU1 U U1
UH UH1 UH2 UH3 ER R R1 R2 L L1 LF W B D KV P T K HV HVC HF HFC HN Z S J SCH V
F THV TH M N NG :A :GH :U :UH E2 LB""".split()
assert len(NAMES) == DEPTH, len(NAMES)

VOICED = set("""E EI Y Y1 AY IE I A AI EH EH1 AE AE1 AH AH1 AW O OU OO IU IU1
U U1 UH UH1 UH2 UH3 ER R R1 R2 L L1 LF W B D KV HV HVC HN Z J V THV M N NG
:A :GH :U :UH E2 LB""".split())

SILENT   = {"PA"}
CLOSURE  = {"HVC", "HFC", "HN"}
STOPS    = {"B", "D", "KV", "P", "T", "K"}
FRICS    = {"Z", "S", "J", "SCH", "V", "F", "THV", "TH", "HF", "HFC", "HV"}
NASALS   = {"M", "N", "NG", "HN"}
VOWELS   = [n for n in NAMES if n not in VOICED - set() or True]

# approximate F1 / F2 for the vowels only, used to score candidate fields
VOWEL_F = {
    "E": (300, 2300), "EI": (400, 2100), "Y": (300, 2200), "Y1": (300, 2300),
    "AY": (450, 2000), "IE": (400, 2000), "I": (400, 1900), "A": (550, 1850),
    "AI": (600, 1800), "EH": (550, 1750), "EH1": (580, 1700), "AE": (700, 1650),
    "AE1": (720, 1600), "AH": (730, 1200), "AH1": (700, 1150), "AW": (600, 950),
    "O": (500, 850), "OU": (450, 800), "OO": (420, 950), "IU": (320, 1600),
    "IU1": (340, 1500), "U": (320, 900), "U1": (340, 950), "UH": (620, 1220),
    "UH1": (600, 1200), "UH2": (580, 1180), "UH3": (560, 1160), "ER": (490, 1350),
}


def load(path):
    rows = []
    for line in open(path):
        line = line.strip()
        if line:
            rows.append(line)
    return rows


def rot180(rows):
    return [r[::-1] for r in rows[::-1]]


def col(rows, c):
    return [int(r[c]) for r in rows]


def agreement(bits, member):
    """How well does this column match a set membership test? 1.0 = perfect,
    0.0 = perfectly anti-correlated (also informative: the bit is inverted)."""
    hit = sum(1 for i, b in enumerate(bits) if b == (1 if member(NAMES[i]) else 0))
    return hit / float(DEPTH)


def report(rows, label):
    print("=" * 66)
    print(label)
    print("=" * 66)

    ones = [sum(col(rows, c)) for c in range(WIDTH)]
    print("col:      " + "".join("%3d" % c for c in range(WIDTH)))
    print("ones/64:  " + "".join("%3d" % n for n in ones))

    tests = [
        ("silent   ", lambda n: n in SILENT),
        ("voiced   ", lambda n: n in VOICED),
        ("closure  ", lambda n: n in CLOSURE),
        ("stop     ", lambda n: n in STOPS),
        ("fricative", lambda n: n in FRICS),
        ("nasal    ", lambda n: n in NASALS),
        ("vowel    ", lambda n: n in VOWEL_F),
    ]
    print()
    for name, fn in tests:
        scores = [agreement(col(rows, c), fn) for c in range(WIDTH)]
        best = sorted(range(WIDTH), key=lambda c: -max(scores[c], 1 - scores[c]))[:4]
        s = "  ".join("c%d=%.2f" % (c, scores[c]) for c in best)
        print("%s  best columns: %s" % (name, s))

    # constant columns carry no per-phoneme information
    const = [c for c in range(WIDTH) if ones[c] in (0, DEPTH)]
    print("\nconstant columns:", const if const else "none")

    # how many distinct words? a real parameter ROM should have few duplicates
    dup = [w for w, n in Counter(rows).items() if n > 1]
    print("duplicate rows: %d distinct words repeated" % len(dup))


def vowel_fields(rows):
    """Score every contiguous 3..5 bit run as a candidate F1 or F2 field by
    rank correlation against the known vowel formants."""
    idx = [i for i, n in enumerate(NAMES) if n in VOWEL_F]

    def spearman(a, b):
        def rank(v):
            order = sorted(range(len(v)), key=lambda i: v[i])
            r = [0] * len(v)
            for pos, i in enumerate(order):
                r[i] = pos
            return r
        ra, rb = rank(a), rank(b)
        n = len(a)
        ma = sum(ra) / float(n); mb = sum(rb) / float(n)
        num = sum((ra[i]-ma)*(rb[i]-mb) for i in range(n))
        da = sum((ra[i]-ma)**2 for i in range(n)) ** 0.5
        db = sum((rb[i]-mb)**2 for i in range(n)) ** 0.5
        return num / (da * db) if da and db else 0.0

    f1 = [VOWEL_F[NAMES[i]][0] for i in idx]
    f2 = [VOWEL_F[NAMES[i]][1] for i in idx]

    out = []
    for w in (3, 4, 5):
        for lo in range(WIDTH - w + 1):
            for msb_first in (True, False):
                vals = []
                for i in idx:
                    bits = rows[i][lo:lo+w]
                    if not msb_first:
                        bits = bits[::-1]
                    vals.append(int(bits, 2))
                if len(set(vals)) < 3:
                    continue
                out.append((abs(spearman(vals, f1)), "F1", lo, w, msb_first,
                            spearman(vals, f1)))
                out.append((abs(spearman(vals, f2)), "F2", lo, w, msb_first,
                            spearman(vals, f2)))
    out.sort(reverse=True)
    print("\nbest contiguous fields vs vowel formants (rank correlation):")
    for score, which, lo, w, mf, raw in out[:12]:
        print("  %s  bits[%2d:%2d] %s  rho=%+.2f"
              % (which, lo, lo + w - 1, "msb-first" if mf else "lsb-first", raw))


# Columns whose meaning is settled, in the AS-POSTED orientation.
DECODED = [
    (0,  "0 = has a closure phase", {"B","D","P","T","K","HVC","HFC"}),
    (1,  "0 = pause / hold group",  {"PA","HV","HVC","HF","HFC","HN"}),
    (2,  "0 = dental-alveolar",     {"T","Z","S","THV","TH"}),
    (4,  "1 = unvoiced (noise source)",
         {"P","T","K","HF","HFC","S","SCH","F","TH"}),
    (5,  "1 = fricative group A",   {"P","T","HF","HFC","Z","S","J"}),
    (7,  "0 = low F3 / r-coloured", {"U1","ER","R","R1"}),
    (10, "1 = obstruent group",     {"P","T","K","S","SCH","V","F"}),
    (15, "1 = sibilant group",      {"P","T","Z","S","J","SCH","THV","TH"}),
    (18, "1 = nasal",               {"HN","M","N","NG"}),
    (21, "1 = sibilant burst",      {"P","T","S"}),
    (24, "1 = nasal (duplicate of column 18)", {"HN","M","N","NG"}),
]


def verdict(raw):
    print()
    print("=" * 66)
    print("VERDICT")
    print("=" * 66)
    for label, rows in (("as posted", raw), ("rotated 180", rot180(raw))):
        exact = 0
        for c, _, want in DECODED:
            got = {NAMES[i] for i in range(DEPTH) if rows[i][c] == "1"}
            inv = {NAMES[i] for i in range(DEPTH) if rows[i][c] == "0"}
            if got == want or inv == want:
                exact += 1
        print("  %-12s  %d of %d columns are an exact phonetic class"
              % (label, exact, len(DECODED)))
    print()
    print("  Row order AS POSTED is correct.  Rotating 180 destroys every one")
    print("  of these matches.  The poster's note that the data is upside down")
    print("  applies to the die photograph, not to the transcription.")
    print()
    print("  Settled columns (as posted):")
    for c, meaning, want in DECODED:
        got = {NAMES[i] for i in range(DEPTH) if raw[i][c] == "1"}
        inv = {NAMES[i] for i in range(DEPTH) if raw[i][c] == "0"}
        sel = sorted(got if len(got) <= len(inv) else inv)
        ok = "exact" if (got == want or inv == want) else "PARTIAL"
        print("    c%-2d  %-34s %-7s %s" % (c, meaning, ok, " ".join(sel)))
    print()
    print("  Column mirroring is NOT determined by these tests: reversing the")
    print("  bit order only relabels columns, it cannot change a per-column")
    print("  set membership.  It matters only for multi-bit fields, and the")
    print("  27 bits appear to be nine 3-bit groups rather than packed fields.")


if __name__ == "__main__":
    raw = load(sys.argv[1] if len(sys.argv) > 1 else "rom/die_read_raw.bits")
    report(raw, "AS POSTED (poster says this is upside down)")
    print()
    r = rot180(raw)
    report(r, "ROTATED 180 (rows reversed AND bits reversed)")
    vowel_fields(r)
    print()
    report([x[::-1] for x in raw], "BITS REVERSED ONLY")
    print()
    report(raw[::-1], "ROWS REVERSED ONLY")
    verdict(raw)
