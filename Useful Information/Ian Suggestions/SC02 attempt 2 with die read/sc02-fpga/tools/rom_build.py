#!/usr/bin/env python3
"""
sc02 phoneme ROM builder.

Two jobs:

  1. Emit a BOOTSTRAP 64x27 bit matrix from acoustic parameters, so the core
     makes speech-like noise before the real die read is available.
  2. Pack ANY 64x27 bit matrix (e.g. the community die-shot read) into the
     $readmemb hex/bin file the RTL loads, with orientation flags so the
     "might be flipped 180 degrees" question is a command-line switch.

FIELD MAP  (27 bits, MSB..LSB of each ROM word)
-----------------------------------------------
  [26:23] F1     first formant code        (4b)
  [22:18] F2     second formant code       (5b)
  [17:15] F2Q    second formant bandwidth  (3b)
  [14:11] F3     third formant code        (4b)
  [10:7]  FA     fricative (noise) amp     (4b)
  [6:3]   VA     voiced (glottal) amp      (4b)
  [2]     CL     closure - mute excitation (1b)
  [1]     VD     voiced flag               (1b)
  [0]     PA     pause / silent            (1b)

This field map is a HYPOTHESIS. It is chosen to (a) total exactly 27 bits and
(b) mirror the parameter set MAME's votrax.cpp recovered from the decapped
SC-01/SC-01A (fa, va, f1, f2, f2q, f3, closure, vd, pause). The SC-02 needs no
duration field because duration comes from the DR1/DR0 register bits, which
frees the width the SC-01 spent on it. If the real read disagrees, change
FIELDS below and rerun -- nothing else in the design hardcodes the layout.
"""

import argparse
import sys

from sc02_maps import F1_MAP, F2_MAP, F3_MAP, bw_code, nearest

WIDTH = 27
DEPTH = 64

# (name, msb, lsb) -- must tile [26:0] exactly
FIELDS = [
    ("F1",  26, 23),
    ("F2",  22, 18),
    ("F2Q", 17, 15),
    ("F3",  14, 11),
    ("FA",  10, 7),
    ("VA",  6, 3),
    ("CL",  2, 2),
    ("VD",  1, 1),
    ("PA",  0, 0),
]

# ---------------------------------------------------------------------------
# Bootstrap acoustic table.
#
# 64 SC-02 phonemes in datasheet order (hex 00..3F).  Values are:
#   f1,f2,f3 in Hz, bw2 = F2 bandwidth in Hz, va/fa = 0..15 amplitudes,
#   flags: 'v' voiced, 'c' closure, 'p' pause.
#
# These are NOT the die read.  They are ordinary formant targets for the
# English/German/French sounds named in the datasheet phoneme chart, good
# enough to be intelligible and to prove the signal path, and deliberately
# easy to throw away.
# ---------------------------------------------------------------------------
BOOT = [
    ("PA",   0,    0,    0,   200,  0,  0, "p"),
    ("E",    300, 2300, 3000,  90, 14,  0, "v"),
    ("EI",   400, 2100, 2800, 100, 14,  0, "v"),
    ("Y",    300, 2200, 3000, 110, 12,  0, "v"),
    ("Y1",   300, 2300, 3100, 110, 12,  0, "v"),
    ("AY",   450, 2000, 2700, 110, 14,  0, "v"),
    ("IE",   400, 2000, 2600, 110, 13,  0, "v"),
    ("I",    400, 1900, 2550, 120, 14,  0, "v"),
    ("A",    550, 1850, 2500, 110, 14,  0, "v"),
    ("AI",   600, 1800, 2450, 120, 13,  0, "v"),
    ("EH",   550, 1750, 2450, 120, 14,  0, "v"),
    ("EH1",  580, 1700, 2400, 120, 13,  0, "v"),
    ("AE",   700, 1650, 2400, 120, 14,  0, "v"),
    ("AE1",  720, 1600, 2380, 130, 13,  0, "v"),
    ("AH",   730, 1200, 2450, 110, 14,  0, "v"),
    ("AH1",  700, 1150, 2400, 110, 13,  0, "v"),
    ("AW",   600,  950, 2500, 100, 14,  0, "v"),
    ("O",    500,  850, 2450, 100, 14,  0, "v"),
    ("OU",   450,  800, 2400, 100, 13,  0, "v"),
    ("OO",   420,  950, 2350, 100, 13,  0, "v"),
    ("IU",   320, 1600, 2400, 110, 13,  0, "v"),
    ("IU1",  340, 1500, 2350, 110, 12,  0, "v"),
    ("U",    320,  900, 2300,  90, 14,  0, "v"),
    ("U1",   340,  950, 2300,  90, 13,  0, "v"),
    ("UH",   620, 1220, 2550, 110, 14,  0, "v"),
    ("UH1",  600, 1200, 2500, 110, 13,  0, "v"),
    ("UH2",  580, 1180, 2500, 110, 12,  0, "v"),
    ("UH3",  560, 1160, 2480, 110, 11,  0, "v"),
    ("ER",   490, 1350, 1690, 120, 14,  0, "v"),
    ("R",    350, 1050, 1600, 130, 13,  0, "v"),
    ("R1",   360, 1100, 1650, 130, 12,  0, "v"),
    ("R2",   380, 1250, 1700, 140, 11,  0, "v"),
    ("L",    380, 1050, 2800, 120, 13,  0, "v"),
    ("L1",   390, 1100, 2800, 120, 12,  0, "v"),
    ("LF",   400,  900, 2700, 130, 11,  0, "v"),
    ("W",    300,  700, 2300,  90, 13,  0, "v"),
    ("B",    250, 1000, 2300, 130,  8,  0, "v"),
    ("D",    280, 1700, 2600, 130,  8,  0, "v"),
    ("KV",   280, 2100, 2500, 140,  8,  0, "v"),
    ("P",    300, 1000, 2200, 200,  0,  5, ""),
    ("T",    320, 1800, 2700, 200,  0,  6, ""),
    ("K",    320, 1900, 2400, 200,  0,  6, ""),
    ("HV",   500, 1500, 2500, 200,  6,  4, "v"),
    ("HVC",  500, 1500, 2500, 200,  0,  0, "vc"),
    ("HF",   500, 1600, 2600, 250,  0,  6, ""),
    ("HFC",  500, 1600, 2600, 250,  0,  0, "c"),
    ("HN",   300, 1100, 2300, 150,  9,  0, "v"),
    ("Z",    300, 1900, 5500, 200,  6,  8, "v"),
    ("S",    320, 2000, 6500, 250,  0, 12, ""),
    ("J",    300, 1800, 3000, 200,  6,  8, "v"),
    ("SCH",  330, 1900, 3200, 250,  0, 12, ""),
    ("V",    280, 1200, 2400, 180,  6,  6, "v"),
    ("F",    300, 1300, 2600, 250,  0,  8, ""),
    ("THV",  300, 1500, 2800, 180,  6,  5, "v"),
    ("TH",   320, 1600, 2900, 250,  0,  7, ""),
    ("M",    250,  900, 2200, 150, 12,  0, "v"),
    ("N",    250, 1500, 2400, 150, 12,  0, "v"),
    ("NG",   250, 1900, 2300, 150, 12,  0, "v"),
    (":A",   600, 1400, 2500, 130, 13,  0, "v"),
    (":GH",  450, 1350, 2300, 130, 12,  0, "v"),
    (":U",   350, 1650, 2200, 110, 13,  0, "v"),
    (":UH",  400, 1500, 2200, 120, 12,  0, "v"),
    ("E2",   400, 1900, 2500, 120, 11,  0, "v"),
    ("LB",   400, 1000, 2700, 130, 11,  0, "v"),
]
assert len(BOOT) == DEPTH


def build_bootstrap():
    rows = []
    for name, f1, f2, f3, bw2, va, fa, flags in BOOT:
        vals = {
            "F1":  nearest(F1_MAP, f1),
            "F2":  nearest(F2_MAP, f2),
            "F2Q": bw_code(bw2),
            "F3":  nearest(F3_MAP, f3),
            "FA":  fa & 0xF,
            "VA":  va & 0xF,
            "CL":  1 if "c" in flags else 0,
            "VD":  1 if "v" in flags else 0,
            "PA":  1 if "p" in flags else 0,
        }
        word = 0
        for fname, msb, lsb in FIELDS:
            w = msb - lsb + 1
            word |= (vals[fname] & ((1 << w) - 1)) << lsb
        rows.append(word)
    return rows


def read_bits_raw(path):
    """Return the die read as a list of 64 27-character strings."""
    out = []
    for line in open(path):
        line = line.split("#")[0].strip().replace("_", "").replace(" ", "")
        if line:
            out.append(line)
    if len(out) != DEPTH or any(len(r) != WIDTH for r in out):
        sys.exit("die read must be %d rows of %d bits" % (DEPTH, WIDTH))
    return out


# --- decoded die-read columns -------------------------------------------
# Column indices are in the AS-POSTED orientation, which tools/rom_analyse.py
# shows is the correct row order (NOT rotated 180 -- see README).
COL_STOP   = 0    # 0 for  B D P T K HVC HFC     (has a closure phase)
COL_HOLD   = 1    # 0 for  PA HV HVC HF HFC HN   (pause / hold group)
COL_UNVOICED = 4  # 1 for  P T K HF HFC S SCH F TH
COL_NASAL  = 18   # 1 for  HN M N NG             (duplicated at column 24)


def build_hybrid(die):
    """Silicon where it is decoded, bootstrap where it is not.

    Voicing and the true-silence closures come from the die read.  Formants and
    amplitudes still come from the acoustic table, because the bits carrying
    them have not been identified yet.
    """
    rows = build_bootstrap()
    out = []
    for i, word in enumerate(rows):
        vals = {}
        for fname, msb, lsb in FIELDS:
            vals[fname] = (word >> lsb) & ((1 << (msb - lsb + 1)) - 1)

        unvoiced = die[i][COL_UNVOICED] == "1"
        silent   = die[i][COL_STOP] == "0" and die[i][COL_HOLD] == "0"

        vals["VD"] = 0 if unvoiced else 1
        if unvoiced:
            vals["VA"] = 0                    # noise source only
        elif vals["FA"] == 0:
            vals["FA"] = 0
        if silent:
            vals["CL"] = 1

        w = 0
        for fname, msb, lsb in FIELDS:
            w |= (vals[fname] & ((1 << (msb - lsb + 1)) - 1)) << lsb
        out.append(w)
    return out


def read_bits(path):
    """Read a 64-line x 27-char '0'/'1' matrix. Blank lines and # ignored."""
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.split("#")[0].strip().replace("_", "").replace(" ", "")
            if not line:
                continue
            if len(line) != WIDTH or set(line) - set("01"):
                sys.exit("bad row (need %d bits of 0/1): %r" % (WIDTH, line))
            rows.append(int(line, 2))
    if len(rows) != DEPTH:
        sys.exit("need %d rows, got %d" % (DEPTH, len(rows)))
    return rows


def bitrev(word):
    out = 0
    for i in range(WIDTH):
        if word & (1 << i):
            out |= 1 << (WIDTH - 1 - i)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", help="input 64x27 bit matrix (default: bootstrap)")
    ap.add_argument("--out", default="rom/sc02_phoneme_rom.bin")
    ap.add_argument("--dump-bits", help="also write the matrix back out here")
    ap.add_argument("--row-reverse", action="store_true",
                    help="phoneme 0 is the LAST row of the die read")
    ap.add_argument("--bit-reverse", action="store_true",
                    help="bit 26 is on the right-hand side of the die read")
    ap.add_argument("--rotate180", action="store_true",
                    help="shorthand for --row-reverse --bit-reverse")
    ap.add_argument("--hybrid", metavar="BITS",
                    help="take the decoded flags (voicing, closure) from a die "
                         "read and the acoustics from the bootstrap table")
    ap.add_argument("--report", action="store_true")
    a = ap.parse_args()

    if a.hybrid:
        rows = build_hybrid(read_bits_raw(a.hybrid))
    elif a.bits:
        rows = read_bits(a.bits)
    else:
        rows = build_bootstrap()

    if a.rotate180:
        a.row_reverse = a.bit_reverse = True
    if a.bit_reverse:
        rows = [bitrev(w) for w in rows]
    if a.row_reverse:
        rows = rows[::-1]

    with open(a.out, "w") as fh:
        fh.write("// sc02 phoneme ROM  %dx%d  source=%s row_rev=%d bit_rev=%d\n"
                 % (DEPTH, WIDTH, a.bits or "BOOTSTRAP",
                    a.row_reverse, a.bit_reverse))
        for w in rows:
            fh.write(format(w, "027b") + "\n")

    if a.dump_bits:
        with open(a.dump_bits, "w") as fh:
            for w in rows:
                fh.write(format(w, "027b") + "\n")

    if a.report:
        print("%-4s %-5s %s" % ("hex", "name", " ".join(f[0] for f in FIELDS)))
        for i, w in enumerate(rows):
            parts = []
            for fname, msb, lsb in FIELDS:
                parts.append("%*d" % (len(fname), (w >> lsb) & ((1 << (msb - lsb + 1)) - 1)))
            nm = BOOT[i][0] if not a.bits else ""
            print("%02X   %-5s %s" % (i, nm, " ".join(parts)))

    print("wrote %s (%d x %d)" % (a.out, DEPTH, WIDTH), file=sys.stderr)


if __name__ == "__main__":
    main()
