#!/usr/bin/env python3
"""
browse_dlv.py -- .dlv container frame browser / seek-bug forensics tool.

Companion to pack_dlv.py.  Steps through a .dlv frame-by-frame and, for each
frame, shows the metadata the CORE would have used to get there:

  * video frame index    (what dlv_streamer.v calls cur_frame / vid_target)
  * DISC frame           (what the Z80's LD-V1000 SEARCH actually asks for)
  * the 5 BCD digits + the real LD-V1000 opcode bytes DL sends for that frame

WHY: to diagnose "we seek to entirely the wrong frame", find the frame you're
SEEING on hardware, find the frame you SHOULD be seeing, and compare their
digit sequences.  The transformation between the two IS the bug.
Use the [Mark SEEN] / [Mark EXPECTED] buttons, then read the DIFF panel.

Mapping (kept bit-identical to rtl/video/dlv_streamer.v):
    disc_rel   = ld_curr_frame - ld_leader            (clamped at 0)
    vid_target = disc_rel            [1:1, ONE-TO-ONE-FIX-2026-07-16]
The old fps-ratio map below was a FABRICATION and is gone; the inverse used to be a
RANGE of disc frames -- both ends are shown rather than a fake single value.

Opcode table verified against Daphne ldp-in/ldv1000.cpp:181-214 (NOT MAME --
our asset chain is Daphne-derived; see the vault handoff).

Usage:  ./browse_dlv.py [path/to/file.dlv]
Keys:   <- ->  +/-1      Shift+<- ->  +/-10      PgUp/PgDn  +/-100
        Home/End  first/last      Ctrl+<- ->  +/-1000
"""

import io
import os
import struct
import sys
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageTk

DEFAULT_DLV = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "dragonslair", "dlair.dlv")

# Daphne ldv1000.cpp:181-214 -- digit -> command byte the game sends
DIGIT_OP = {0: 0x3F, 1: 0x0F, 2: 0x8F, 3: 0x4F, 4: 0x2F,
            5: 0xAF, 6: 0x6F, 7: 0x1F, 8: 0x9F, 9: 0x5F}
CMD_CLEAR, CMD_SEARCH, CMD_NO_ENTRY = 0xBF, 0xF7, 0xFF


class Dlv:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        # DLV-V2-2026-07-24: read the WHOLE header sector, not the first 96 bytes -- v2 puts
        # samp_per_frame_q16 @96 and max_frame_size @100, which a 96-byte read cannot see.
        # ORIGINAL: h = self.f.read(96) / if len(h) < 96: raise ...
        h = self.f.read(512)
        if len(h) < 96:
            raise ValueError("file too short to hold a .dlv header")
        magic, self.ver, self.w, self.h, self.frame_count = struct.unpack_from("<4sIIII", h, 0)
        if magic != b"DLV1":
            raise ValueError(f"bad magic {magic!r} (expected b'DLV1') -- not a .dlv?")
        # DLV-V2-2026-07-24: @24 (mpeg_fpks) is RESERVED=0 and @28 (ldoff) is SIGNED (TQ = -16).
        self.disc_fpks, self.mpeg_fpks = struct.unpack_from("<II", h, 20)
        (self.ldoff,) = struct.unpack_from("<i", h, 28)
        self.srate, self.chans, self.total_samples = struct.unpack_from("<IIQ", h, 32)
        self.idx_off, self.idx_len = struct.unpack_from("<QQ", h, 48)
        self.vid_off, self.vsize = struct.unpack_from("<QQ", h, 64)
        self.aud_off, self.asize = struct.unpack_from("<QQ", h, 80)

        # v2: samples-per-disc-frame in 16.16, and the largest coded frame.
        self.spf_q16, self.max_frame = (struct.unpack_from("<II", h, 96)
                                        if len(h) >= 104 else (0, 0))
        if self.ver >= 2 and 1 << 20 <= self.spf_q16 < 1 << 27:
            # fps derived from the AUDIO, which is the only self-consistent source; mpeg_fpks was
            # removed in v2 precisely because it assumed audio duration == video duration.
            self.fps = self.srate / (self.spf_q16 / 65536.0)
        elif self.mpeg_fpks:
            self.fps = self.mpeg_fpks / 1000.0          # v1 fallback
        else:
            raise ValueError("no usable frame rate in header (v1 with zero mpeg_fpks?)")

        # index: frame_count * {u32 off_in_video_blob, u32 size}
        self.f.seek(self.idx_off)
        raw = self.f.read(self.frame_count * 8)
        if len(raw) < self.frame_count * 8:
            raise ValueError("index table truncated")
        self.index = [struct.unpack_from("<II", raw, i * 8) for i in range(self.frame_count)]

    # ---- the RTL's forward map, integer-identical to dlv_streamer.v ----
    def disc_rel_to_vid(self, disc_rel):
        # ONE-TO-ONE-FIX-2026-07-16: the disc->video map is 1:1. The fps-ratio map this used to
        # apply was a FABRICATION (Daphne's framefile is a single offset, with no fps scaling
        # anywhere in its model) and was the "seeks to entirely the wrong frame" bug.
        # ORIGINAL: return (disc_rel*self.mpeg_fpks + self.disc_fpks//2) // self.disc_fpks
        return disc_rel

    def vid_to_disc_range(self, vid):
        # ONE-TO-ONE-FIX-2026-07-16: the map is 1:1, so the inverse is exact -- one disc frame per
        # video frame, not a range. The old many-to-one inverse existed only because of the
        # fabricated fps-ratio map. Tuple kept so callers are unchanged.
        return vid + self.ldoff, vid + self.ldoff

    def jpeg(self, vid):
        off, size = self.index[vid]
        self.f.seek(self.vid_off + off)
        return self.f.read(size), off, size

    def duration_s(self):
        return self.total_samples / self.srate if self.srate else 0.0


def digits_of(disc_frame, n=5):
    """Disc frame -> the n decimal digits an LD-V1000 SEARCH would carry.

    DLV-V2-2026-07-24: the disc frame CAN BE NEGATIVE. Thayer's Quest has ldoff = -16, so video
    frames 0..15 sit at disc frames -16..-1 -- i.e. the capture starts BEFORE disc frame 0. There
    is no digit encoding for a negative frame and a real player cannot SEARCH there, so clamp to 0
    (see searchable() -- callers should say so rather than pretend frame 0 was requested).
    Previously str(-16).zfill(5) gave '-0016' and int('-') raised ValueError.
    ORIGINAL: s = str(disc_frame).zfill(n)
    """
    d = 0 if disc_frame < 0 else min(disc_frame, 10 ** n - 1)
    return [int(c) for c in f"{d:0{n}d}"[-n:]]


def searchable(disc_frame):
    """False for frames a real LD-V1000 SEARCH cannot address (before disc frame 0)."""
    return disc_frame >= 0


def opcode_seq(disc_frame, with_acks=False):
    """The real byte stream DL sends to seek to disc_frame."""
    ds = digits_of(disc_frame)
    if not with_acks:
        return [CMD_CLEAR] + [DIGIT_OP[d] for d in ds] + [CMD_SEARCH]
    out = [CMD_CLEAR]
    for d in ds:
        out += [CMD_NO_ENTRY, DIGIT_OP[d]]
    out += [CMD_NO_ENTRY, CMD_SEARCH]
    return out


def hexs(bs):
    return " ".join(f"{b:02X}" for b in bs)


class App:
    def __init__(self, root, dlv):
        self.dlv = dlv
        self.vid = 0
        self.seen = None
        self.expected = None
        root.title(f"browse_dlv -- {os.path.basename(dlv.path)}")

        top = ttk.Frame(root, padding=6)
        top.pack(fill="both", expand=True)

        self.canvas = tk.Label(top, bg="#111")
        self.canvas.grid(row=0, column=0, rowspan=2, padx=(0, 8))

        self.meta = tk.Text(top, width=54, height=17, font=("monospace", 9),
                            bg="#0d0d0d", fg="#d8d8d8", relief="flat")
        self.meta.grid(row=0, column=1, sticky="nsew")

        self.diff = tk.Text(top, width=54, height=11, font=("monospace", 9),
                            bg="#0d0d0d", fg="#9fd6a0", relief="flat")
        self.diff.grid(row=1, column=1, sticky="nsew", pady=(6, 0))

        nav = ttk.Frame(root, padding=(6, 0, 6, 6))
        nav.pack(fill="x")
        for lbl, delta in (("<<<", -1000), ("<<", -100), ("<", -10), ("-1", -1),
                           ("+1", 1), (">", 10), (">>", 100), (">>>", 1000)):
            ttk.Button(nav, text=lbl, width=5,
                       command=lambda d=delta: self.step(d)).pack(side="left", padx=1)

        ttk.Label(nav, text="  video#:").pack(side="left")
        self.e_vid = ttk.Entry(nav, width=9)
        self.e_vid.pack(side="left")
        self.e_vid.bind("<Return>", lambda e: self.goto_vid())

        ttk.Label(nav, text="  disc#:").pack(side="left")
        self.e_disc = ttk.Entry(nav, width=9)
        self.e_disc.pack(side="left")
        self.e_disc.bind("<Return>", lambda e: self.goto_disc())

        ttk.Button(nav, text="Mark SEEN", command=self.mark_seen).pack(side="left", padx=(10, 2))
        ttk.Button(nav, text="Mark EXPECTED", command=self.mark_expected).pack(side="left", padx=2)
        ttk.Button(nav, text="Clear", command=self.mark_clear).pack(side="left", padx=2)

        for k, d in (("<Left>", -1), ("<Right>", 1),
                     ("<Shift-Left>", -10), ("<Shift-Right>", 10),
                     ("<Prior>", -100), ("<Next>", 100),
                     ("<Control-Left>", -1000), ("<Control-Right>", 1000)):
            root.bind(k, lambda e, d=d: self.step(d))
        root.bind("<Home>", lambda e: self.goto(0))
        root.bind("<End>", lambda e: self.goto(self.dlv.frame_count - 1))

        self.render()

    def step(self, d):
        self.goto(self.vid + d)

    def goto(self, v):
        self.vid = max(0, min(self.dlv.frame_count - 1, int(v)))
        self.render()

    def goto_vid(self):
        try:
            self.goto(int(self.e_vid.get().strip()))
        except ValueError:
            pass

    def goto_disc(self):
        try:
            df = int(self.e_disc.get().strip())
        except ValueError:
            return
        rel = max(0, df - self.dlv.ldoff)
        self.goto(self.dlv.disc_rel_to_vid(rel))

    def mark_seen(self):
        self.seen = self.vid
        self.render()

    def mark_expected(self):
        self.expected = self.vid
        self.render()

    def mark_clear(self):
        self.seen = self.expected = None
        self.render()

    def render(self):
        d = self.dlv
        try:
            data, off, size = d.jpeg(self.vid)
            im = Image.open(io.BytesIO(data))
            im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
            self.photo = ImageTk.PhotoImage(im)
            self.canvas.configure(image=self.photo, text="")
            err = None
        except Exception as ex:
            self.canvas.configure(image="", text=f"decode failed:\n{ex}",
                                  fg="#ff6666", width=46, height=22)
            off = size = 0
            err = str(ex)

        lo, hi = d.vid_to_disc_range(self.vid)
        t = self.vid / d.fps
        m = self.meta
        m.delete("1.0", "end")
        m.insert("end", f" file        {os.path.basename(d.path)}\n")
        m.insert("end", f" v{d.ver} {d.w}x{d.h}  frames={d.frame_count}  {d.fps:.3f}fps"
                       f"  ldoff={d.ldoff}" + (f"  maxframe={d.max_frame}" if d.max_frame else "") + "\n")
        m.insert("end", f" ldoff(leader)={d.ldoff}   disc={d.disc_fpks/1000:.2f}fps\n")
        m.insert("end", "-" * 52 + "\n")
        m.insert("end", f" VIDEO frame   {self.vid}\n")
        m.insert("end", f"   blob offset {off}  size {size}\n")
        m.insert("end", f"   timecode    {int(t//60):02d}:{t%60:06.3f}\n")
        if err:
            m.insert("end", f"   !! {err}\n")
        m.insert("end", "-" * 52 + "\n")
        rng = f"{lo}" if lo == hi else f"{lo} .. {hi}"
        m.insert("end", f" DISC frame    {rng}\n")
        m.insert("end", "   (disc->video is 1:1 -- ONE-TO-ONE-FIX-2026-07-16)\n\n")
        for tag, df in (("lo", lo), ("hi", hi)) if lo != hi else (("", lo),):
            ds = digits_of(df)
            m.insert("end", f"   {tag+':' if tag else '':4s}{df:>6d}  digits {' '.join(map(str,ds))}\n")
            if not searchable(df):
                m.insert("end", "        ** NEGATIVE disc frame -- BEFORE disc frame 0, so a real\n"
                                "           LD-V1000 SEARCH cannot reach it. Digits shown clamped to 0. **\n")
            m.insert("end", f"        SEARCH  {hexs(opcode_seq(df))}\n")
        m.insert("end", "\n   (with 0xFF handshake ACKs, as really sent:)\n")
        m.insert("end", f"   {hexs(opcode_seq(lo, with_acks=True))}\n")

        x = self.diff
        x.delete("1.0", "end")
        s, e = self.seen, self.expected
        x.insert("end", f" SEEN     video {s if s is not None else '--'}"
                        f"   {'disc '+str(self.dlv.vid_to_disc_range(s)[0]) if s is not None else ''}\n")
        x.insert("end", f" EXPECTED video {e if e is not None else '--'}"
                        f"   {'disc '+str(self.dlv.vid_to_disc_range(e)[0]) if e is not None else ''}\n")
        x.insert("end", "-" * 52 + "\n")
        if s is None or e is None:
            x.insert("end", " Navigate to the frame you SEE on hardware -> [Mark SEEN]\n"
                            " Navigate to the frame you SHOULD see  -> [Mark EXPECTED]\n"
                            " This panel then diffs their digits.\n")
        else:
            ds = self.dlv.vid_to_disc_range(s)[0]
            de = self.dlv.vid_to_disc_range(e)[0]
            gs, ge = digits_of(ds), digits_of(de)
            x.insert("end", f" seen     disc {ds:05d}  digits {' '.join(map(str,gs))}\n")
            x.insert("end", f" expected disc {de:05d}  digits {' '.join(map(str,ge))}\n\n")
            x.insert("end", f" delta    {ds - de:+d}\n")
            x.insert("end", f" ratio    {ds/de:.6f}\n" if de else " ratio    n/a\n")
            same = "".join("=" if a == b else "^" for a, b in zip(gs, ge))
            x.insert("end", f" digitcmp {' '.join(same)}   (^ = differs)\n\n")
            x.insert("end", f" seen     SEARCH {hexs(opcode_seq(ds))}\n")
            x.insert("end", f" expected SEARCH {hexs(opcode_seq(de))}\n")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DLV
    if not os.path.exists(path):
        sys.exit(f"not found: {path}\nusage: {sys.argv[0]} [file.dlv]")
    try:
        dlv = Dlv(path)
    except Exception as ex:
        sys.exit(f"failed to open {path}: {ex}")
    print(f"[dlv] {path}")
    print(f"      v{dlv.ver} {dlv.w}x{dlv.h} frames={dlv.frame_count} fps={dlv.fps:.4f} "
          f"ldoff={dlv.ldoff} dur={dlv.duration_s():.1f}s")
    root = tk.Tk()
    App(root, dlv)
    root.mainloop()


if __name__ == "__main__":
    main()
