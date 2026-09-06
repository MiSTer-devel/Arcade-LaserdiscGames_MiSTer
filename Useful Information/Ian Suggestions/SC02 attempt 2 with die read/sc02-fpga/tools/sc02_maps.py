"""
Formant code -> normalised-frequency maps, shared by rom_build.py and
coef_build.py so the ROM packer and the hardware LUTs can never disagree.

A ROM formant field is only 4 or 5 bits, so a flat linear map over 0..Nyquist
wastes almost all of its range (F1 lives in 250..750 Hz, which is two codes out
of sixteen).  Real silicon would use a nonlinear ladder; we do the same with a
small per-field table baked into the RTL.

Unit of the 8-bit output: 256 == Fs/2 == Nyquist, i.e. one LSB is Fs/512.
That is exactly the index cos_lut is built on.
"""

import math

FS_NOM = 20000.0                 # nominal filter clock  (XCK / (2*(256-FF)))
NYQ = FS_NOM / 2.0


def _u8(hz):
    return max(0, min(255, int(round(hz / NYQ * 256.0))))


def _linear(lo, hi, n):
    return [_u8(lo + (hi - lo) * i / (n - 1.0)) for i in range(n)]


def _geometric(lo, hi, n):
    return [_u8(lo * (hi / lo) ** (i / (n - 1.0))) for i in range(n)]


# F1  4 bits, linear 150..1150 Hz   (vowel first formant lives here)
F1_MAP = _linear(150.0, 1150.0, 16)

# F2  5 bits, linear 500..3200 Hz
F2_MAP = _linear(500.0, 3200.0, 32)

# F3  4 bits, geometric 1500..8000 Hz -- has to reach the /s/ and /sh/ region
F3_MAP = _geometric(1500.0, 8000.0, 16)

# Sections 4 and 5 are not individually programmable in this build; they are
# a fixed upper pole and a spectral-tilt low pass.  Codes are 8-bit directly.
F4_FIX = _u8(3600.0)
F5_FIX = _u8(4800.0)
Q4_FIX = 5
Q5_FIX = 6

BW_LO, BW_HI = 60.0, 400.0       # 3-bit bandwidth code range


def nearest(table, hz):
    """Invert a map: pick the code whose frequency is closest to hz."""
    want = _u8(hz)
    best, bi = None, 0
    for i, v in enumerate(table):
        d = abs(v - want)
        if best is None or d < best:
            best, bi = d, i
    return bi


def bw_code(bw_hz):
    t = math.log(max(BW_LO, min(BW_HI, bw_hz)) / BW_LO) / math.log(BW_HI / BW_LO)
    return max(0, min(7, int(round(t * 7))))
