#!/usr/bin/env python3
"""Turn the testbench's PCM dump into a .wav you can actually listen to.

The sample rate is not a free choice: it is the filter clock the design was
running at, Fs = XCK / (2*(256-FF)).  Pass --ff and --xck to match whatever the
testbench wrote into the Filter Frequency register.
"""

import argparse
import struct
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcm", nargs="?", default="build/out.pcm")
    ap.add_argument("-o", "--out", default="build/out.wav")
    ap.add_argument("--xck", type=float, default=3579545.0 / 2)
    ap.add_argument("--ff", type=lambda s: int(s, 0), default=0xD3)
    ap.add_argument("--gain", type=float, default=1.0)
    a = ap.parse_args()

    fs = int(round(a.xck / (2 * (256 - a.ff))))

    samples = []
    with open(a.pcm) as fh:
        for line in fh:
            line = line.split()
            if not line:
                continue
            v = int(float(line[0]) * a.gain)
            samples.append(max(-32768, min(32767, v)))

    data = struct.pack("<%dh" % len(samples), *samples)
    with open(a.out, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt ")
        fh.write(struct.pack("<IHHIIHH", 16, 1, 1, fs, fs * 2, 2, 16))
        fh.write(b"data" + struct.pack("<I", len(data)) + data)

    peak = max(abs(s) for s in samples) if samples else 0
    print("%s  %d samples  %d Hz  peak %d (%.1f%% FS)"
          % (a.out, len(samples), fs, peak, 100.0 * peak / 32768), file=sys.stderr)


if __name__ == "__main__":
    main()
