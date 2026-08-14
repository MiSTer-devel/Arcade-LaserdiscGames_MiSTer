#!/usr/bin/env python3
"""
browse_m2v.py -- DAPHNE-SIDE frame browser.  Twin of browse_dlv.py.

Same window, same keys, same disc<->video mapping panel.  The ONLY differences are
the decoder and the source file: this one reads the raw .m2v Daphne ships and
numbers its frames the way VLDP does, so you can put the two browsers side by side,
type the same frame number into both, and SEE whether they show the same picture.

WHY THIS EXISTS
---------------
Our .dlv was built by transcoding the .m2v to MJPEG (pack_dlv.py).  Frame N in the
.dlv is "the Nth picture ffmpeg emitted".  Frame N in Daphne is "the Nth picture in
DISPLAY ORDER as libmpeg2 enumerates the stream" (vldp/vldp_internal.c:93,
g_frame_position[], built by vldp/mpegscan.c).  Nothing has ever checked that those
two enumerations agree -- it was only ever checked arithmetically, never visually.
If the transcode inserted or dropped pictures anywhere (pulldown, field/frame
handling, anything we deliberately simplified away), then every segment after that
point is shifted, and segment boundaries land a few frames early or late.

MEASURED 2026-08-13 -- WHY THE ORDER TOGGLE EXISTS
--------------------------------------------------
Scanning lair.m2v and diffing against Daphne's own lair.dat:

    counts            scan 44154 == dat 44154 == .dlv frame_count 44154
    CODED order       44154 entries, 0 mismatches vs lair.dat  -> IDENTICAL
    coded vs display  delta -1: 28847   0: 763   +1: 241   +2: 14303

So the two enumerations agree on the TOTAL and disagree almost everywhere else:
only 763 of 44154 frames (1.7%) are the same picture under both.  A count check
cannot see this -- it is a permutation, not a length error.  That is exactly why
the arithmetic check passed while the pictures were never compared.

Which order is "right" is NOT settled by this measurement.  Real hardware reads the
frame number out of each field's VBI, where no coded/display distinction exists, so
our display order may well be the faithful one and Daphne's the artifact.  But the
leader offset (151 for lair) was calibrated in Daphne's world.  Flip the toggle and
LOOK -- that is what this tool is for.

⚠️ DELIBERATELY NOT USING ffmpeg's OUTPUT NUMBERING.
ffmpeg is what produced the .dlv.  If this tool also indexed by "the Nth frame
ffmpeg emitted" it would agree with the .dlv perfectly while both were wrong.  So
the picture enumeration here comes from OUR OWN start-code scan of the bitstream
(the same job mpegscan.c does), and ffmpeg is used only as a pixel decoder for a
short slice.  `-fps_mode passthrough` keeps it from duplicating frames for pulldown.

HOW A FRAME IS FETCHED  (mirrors idle_handler_search(), vldp_internal.c:851-1026)
---------------------------------------------------------------------------------
  * scan the whole file once for start codes -> every picture's byte offset,
    coding type (I/P/B) and temporal_reference
  * display index = gop_base + temporal_reference  (MPEG-2 reorder rule)
  * to show frame N: slice the bitstream from the GOP BEFORE N's GOP through the
    GOP after it, prepend the sequence header, decode that slice, take frame N.
    Starting one GOP early is Daphne's own conservatism -- see the
    `(skipped_I < 2) && (s_frames_to_skip < 3)` rule at vldp_internal.c:980, which
    exists because decoding too close to an I-frame gives a corrupt picture.

Usage:  ./browse_m2v.py path/to/lair.m2v [--leader N]
        --leader N   the disc frame the m2v's frame 0 shows, i.e. the number in
                     Daphne's framefile (<name>.txt).  Equivalent to ldoff in the
                     .dlv header.  Auto-read from a sibling <name>.txt if present.

Keys:   <- ->  +/-1      Shift+<- ->  +/-10      PgUp/PgDn  +/-100
        Home/End  first/last      Ctrl+<- ->  +/-1000
"""

import io
import mmap
import os
import re
import subprocess
import sys
import tkinter as tk
from tkinter import ttk

from PIL import Image, ImageTk

# Shared with the .dlv side so both browsers report identical digits/opcodes.
from browse_dlv import digits_of, searchable, opcode_seq, hexs

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PIC_TYPE = {1: "I", 2: "P", 3: "B", 4: "D"}
DLV_W, DLV_H = 512, 480     # what pack_dlv.py writes; see the resize note in render()


class M2v:
    """Raw MPEG-2 elementary stream, indexed the way VLDP indexes it."""

    def __init__(self, path, leader=None):
        self.path = path
        self.f = open(path, "rb")
        self.mm = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.leader = leader if leader is not None else self._read_framefile()
        self._scan()
        self.w, self.h, self.fps = self._probe_geometry()
        self._cache_gop = None      # (first_gop_idx, [PIL.Image, ...], base_display)

    # ---- Daphne framefile: "<offset>  <file.m2v>" (pack_dlv.py:153 reads the same) ----
    def _read_framefile(self):
        d = os.path.dirname(os.path.abspath(self.path))
        base = os.path.basename(self.path)
        for txt in sorted(x for x in os.listdir(d) if x.lower().endswith(".txt")):
            try:
                with open(os.path.join(d, txt), "r", errors="replace") as fh:
                    for line in fh:
                        m = re.match(r"\s*(-?\d+)\s+(\S+\.m2v)\s*$", line, re.I)
                        if m and os.path.basename(m.group(2)).lower() == base.lower():
                            print(f"[framefile] {txt}: leader {m.group(1)} for {base}")
                            return int(m.group(1))
            except OSError:
                pass
        print("[framefile] none found next to the m2v -- leader 0 "
              "(pass --leader N to match the .dlv's ldoff)")
        return 0

    # ---- the mpegscan.c job: enumerate pictures from start codes ----
    def _scan(self):
        mm = self.mm
        self.seq_off = None         # first sequence header -- the decode prefix
        self.prefix_end = None
        pics = []                   # coded order: (offset, coding_type, temporal_ref, gop_idx)
        self.gops = []              # coded order: byte offset of each GOP header
        gop_idx = -1
        pos = 0
        while True:
            i = mm.find(b"\x00\x00\x01", pos)
            if i < 0 or i + 6 > len(mm):
                break
            code = mm[i + 3]
            pos = i + 3
            if code == 0xB3:                       # sequence_header
                if self.seq_off is None:
                    self.seq_off = i
            elif code == 0xB8:                     # group_of_pictures_header
                if self.prefix_end is None:
                    self.prefix_end = i
                gop_idx += 1
                self.gops.append(i)
            elif code == 0x00:                     # picture_header
                if self.prefix_end is None:
                    self.prefix_end = i
                if gop_idx < 0:                    # stream with no GOP headers at all
                    gop_idx = 0
                    self.gops.append(i)
                b0, b1 = mm[i + 4], mm[i + 5]
                tr = (b0 << 2) | (b1 >> 6)         # temporal_reference, 10 bits
                ct = (b1 >> 3) & 0x07              # picture_coding_type, 3 bits
                pics.append((i, ct, tr, gop_idx))

        if not pics:
            raise ValueError("no picture start codes found -- is this a raw .m2v "
                             "elementary stream?")
        if self.seq_off is None:
            raise ValueError("no sequence header found -- cannot build a decode prefix")

        # ---- coded order -> display order.  display = gop_base + temporal_reference ----
        self.by_display = {}
        self.gop_base = {}
        self.gop_itr = {}       # temporal_reference of each GOP's I-frame -- see _decode_window
        base = 0
        cur_gop = pics[0][3]
        max_tr = -1
        for off, ct, tr, g in pics:
            if g != cur_gop:
                base += max_tr + 1
                cur_gop, max_tr = g, -1
            self.gop_base.setdefault(g, base)
            if ct == 1:
                self.gop_itr.setdefault(g, tr)
            self.by_display[base + tr] = (off, ct, tr, g)
            max_tr = max(max_tr, tr)
        self.frame_count = base + max_tr + 1
        self.coded = pics       # CODED (bitstream) order -- what Daphne's .dat is indexed by
        self.gop_first_coded = {}
        for c, (off, ct, tr, g) in enumerate(pics):
            self.gop_first_coded.setdefault(g, c)

        missing = [n for n in range(self.frame_count) if n not in self.by_display]
        self.gaps = missing
        self.i_frames = sum(1 for v in self.by_display.values() if v[1] == 1)

    def _probe_geometry(self):
        """Dimensions + coded frame rate straight from the sequence header."""
        mm, i = self.mm, self.seq_off
        b = mm[i + 4:i + 12]
        w = (b[0] << 4) | (b[1] >> 4)
        h = ((b[1] & 0x0F) << 8) | b[2]
        code = b[3] & 0x0F
        table = {1: 24000 / 1001, 2: 24.0, 3: 25.0, 4: 30000 / 1001,
                 5: 30.0, 6: 50.0, 7: 60000 / 1001, 8: 60.0}
        return w, h, table.get(code, 0.0)

    # ---- the two rival enumerations -------------------------------------------------
    # CODED  : Daphne's.  mpegscan.c:239-270 writes one .dat entry per picture in the
    #          order it meets them in the bitstream, and never reads temporal_reference.
    #          g_frame_position[N] is therefore the Nth CODED picture, and that is what
    #          idle_handler_search() indexes when the game asks for a frame.
    # DISPLAY: ours.  ffmpeg emits frames in display order, so .dlv frame N is the Nth
    #          DISPLAYED picture.
    # Same total either way (a permutation), differing by up to 2 slots inside each GOP
    # and coinciding at GOP boundaries -- invisible to any count check.
    def to_display(self, n, order):
        if order == "display":
            return n
        off, ct, tr, g = self.coded[n]
        return self.gop_base[g] + tr

    def from_display(self, disp):
        """display index -> coded index (linear scan of the GOP; GOPs are ~16 frames)."""
        ent = self.by_display.get(disp)
        if ent is None:
            return None
        off = ent[0]
        g = ent[3]
        lo = max(0, self.gop_first_coded.get(g, 0))
        for c in range(lo, min(len(self.coded), lo + 256)):
            if self.coded[c][0] == off:
                return c
        return None

    def gop_of(self, disp):
        """Which GOP holds this display index."""
        g = self.by_display.get(disp)
        if g is not None:
            return g[3]
        # frame missing from the map -- fall back to the nearest GOP at or below it
        best = 0
        for gi, b in sorted(self.gop_base.items()):
            if b <= disp:
                best = gi
        return best

    # ---- decode a window of GOPs, mirroring idle_handler_search()'s back-up rule ----
    def _decode_window(self, gop):
        first = max(0, gop - 1)                       # start one GOP early, like Daphne
        last = min(len(self.gops) - 1, gop + 1)
        start = self.gops[first]
        end = (self.gops[last + 1] if last + 1 < len(self.gops) else len(self.mm))
        prefix = bytes(self.mm[self.seq_off:self.prefix_end or self.seq_off])
        payload = prefix + bytes(self.mm[start:end])

        for rate_flag in (["-fps_mode", "passthrough"], ["-vsync", "0"]):
            cmd = (["ffmpeg", "-hide_banner", "-loglevel", "error",
                    "-f", "mpegvideo", "-i", "pipe:0"] + rate_flag +
                   ["-f", "image2pipe", "-vcodec", "png", "pipe:1"])
            try:
                p = subprocess.run(cmd, input=payload, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
            except FileNotFoundError:
                raise RuntimeError("ffmpeg not found on PATH")
            if p.returncode == 0 and p.stdout:
                break
        else:
            raise RuntimeError((p.stderr or b"").decode(errors="replace").strip()
                               or "ffmpeg produced no output")

        parts = p.stdout.split(PNG_SIG)
        imgs = [Image.open(io.BytesIO(PNG_SIG + q)) for q in parts[1:]]
        for im in imgs:
            im.load()
        return first, imgs

    def frame(self, disp):
        """-> (PIL.Image, info dict).

        The index into the decoded window is DERIVED, not guessed.  A slice that
        begins at GOP g contains B-frames whose display position precedes that
        GOP's I-frame; they reference the previous GOP's anchor, which is not in
        the slice, so the decoder discards exactly `gop_itr[g]` of them.  That
        count comes straight from the temporal_reference of the GOP's I-frame.

        The derivation is then CHECKED against the picture count the decoder
        actually returned.  A mismatch is reported, never absorbed -- this tool
        exists to detect ±1-2 frame errors, so a tool that silently nudges its own
        index by ±1-2 would be worthless.
        """
        gop = self.gop_of(disp)
        if self._cache_gop is None or not (self._cache_gop[0] <= gop <= self._cache_gop[3]):
            first, imgs = self._decode_window(gop)
            last = min(len(self.gops) - 1, gop + 1)
            self._cache_gop = (first, imgs, self.gop_base.get(first, 0), last)
        first, imgs, base, last = self._cache_gop

        span_end = self.gop_base.get(last + 1, self.frame_count)
        dropped = self.gop_itr.get(first, 0)        # leading B-frames the slice cannot decode
        predicted = (span_end - base) - dropped
        anomaly = len(imgs) - predicted             # must be 0

        k = disp - base - dropped
        if not (0 <= k < len(imgs)):
            raise IndexError(f"frame {disp} -> slot {k} of {len(imgs)} decoded "
                             f"(window GOPs {first}..{last}, base {base}, "
                             f"dropped {dropped})")
        off, ct, tr, g = self.by_display.get(disp, (0, 0, 0, gop))
        return imgs[k], {"offset": off, "type": PIC_TYPE.get(ct, "?"), "tr": tr,
                         "gop": g, "slot": k, "decoded": len(imgs),
                         "dropped": dropped, "anomaly": anomaly}

    def vid_to_disc(self, vid):
        return vid + self.leader

    def duration_s(self):
        return self.frame_count / self.fps if self.fps else 0.0


class App:
    def __init__(self, root, m2v):
        self.m2v = m2v
        self.vid = 0
        self.seen = None
        self.expected = None
        root.title(f"browse_m2v [DAPHNE] -- {os.path.basename(m2v.path)}")

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

        # Default CODED: that is the order Daphne's own index uses, so it is what the
        # game actually gets when it SEARCHes. Flip to DISPLAY to see our .dlv's order.
        self.order = tk.StringVar(value="coded")
        ttk.Radiobutton(nav, text="CODED (Daphne)", value="coded", variable=self.order,
                        command=self.render).pack(side="left", padx=(10, 0))
        ttk.Radiobutton(nav, text="DISPLAY (.dlv)", value="display", variable=self.order,
                        command=self.render).pack(side="left")

        ttk.Button(nav, text="Mark SEEN", command=self.mark_seen).pack(side="left", padx=(10, 2))
        ttk.Button(nav, text="Mark EXPECTED", command=self.mark_expected).pack(side="left", padx=2)
        ttk.Button(nav, text="Clear", command=self.mark_clear).pack(side="left", padx=2)

        for k, d in (("<Left>", -1), ("<Right>", 1),
                     ("<Shift-Left>", -10), ("<Shift-Right>", 10),
                     ("<Prior>", -100), ("<Next>", 100),
                     ("<Control-Left>", -1000), ("<Control-Right>", 1000)):
            root.bind(k, lambda e, d=d: self.step(d))
        root.bind("<Home>", lambda e: self.goto(0))
        root.bind("<End>", lambda e: self.goto(self.m2v.frame_count - 1))

        self.render()

    def step(self, d):
        self.goto(self.vid + d)

    def goto(self, v):
        self.vid = max(0, min(self.m2v.frame_count - 1, int(v)))
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
        self.goto(max(0, df - self.m2v.leader))

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
        v = self.m2v
        info, err = {}, None
        order = self.order.get()
        disp_idx = v.to_display(self.vid, order)
        try:
            im, info = v.frame(disp_idx)
            # The m2v is 640x480; the .dlv is 512x480 (pack_dlv.py squeezes it, despite its
            # header comment claiming 512x480 is native and "no resampling happens at all").
            # Present at the .dlv's geometry so the two windows are the same size and the
            # pictures can actually be compared by eye, which is the point of this tool.
            im = im.resize((DLV_W * 2, DLV_H * 2), Image.NEAREST)
            self.photo = ImageTk.PhotoImage(im)
            self.canvas.configure(image=self.photo, text="")
        except Exception as ex:
            self.canvas.configure(image="", text=f"decode failed:\n{ex}",
                                  fg="#ff6666", width=46, height=22)
            err = str(ex)

        disc = v.vid_to_disc(self.vid)
        t = self.vid / v.fps if v.fps else 0.0
        m = self.meta
        m.delete("1.0", "end")
        m.insert("end", f" file        {os.path.basename(v.path)}   [DAPHNE / m2v]\n")
        m.insert("end", f" {v.w}x{v.h}  pictures={v.frame_count}  {v.fps:.3f}fps"
                        f"  I-frames={v.i_frames}\n")
        m.insert("end", f" leader={v.leader}   GOPs={len(v.gops)}\n")
        m.insert("end", "-" * 52 + "\n")
        m.insert("end", f" VIDEO frame   {self.vid}   [{order.upper()} order]\n")
        # The whole point: same number, two enumerations, and the gap between them.
        if order == "coded":
            m.insert("end", f"   coded  #{self.vid}  ==  display #{disp_idx}"
                            f"   delta {disp_idx - self.vid:+d}\n")
            m.insert("end", "   -> our .dlv frame " + f"{self.vid}"
                            f" is display #{self.vid}, i.e. a\n"
                            f"      DIFFERENT picture whenever that delta is nonzero.\n"
                     if disp_idx != self.vid else
                     "   -> matches our .dlv at this index.\n")
        else:
            c = v.from_display(self.vid)
            m.insert("end", f"   display #{self.vid}  ==  coded #{c}"
                            f"   delta {(c - self.vid) if c is not None else 0:+d}\n"
                     if c is not None else "   coded index not resolved\n")
        if info:
            m.insert("end", f"   picture     {info['type']}-frame   tr={info['tr']}"
                            f"  gop={info['gop']}\n")
            m.insert("end", f"   byte offset {info['offset']}  (0x{info['offset']:X})\n")
            if info["type"] != "I":
                m.insert("end", "   ** not an I-frame: a real LD-V1000 SEARCH lands on\n"
                                "      the previous I-frame and decodes forward. **\n")
            if info["anomaly"]:
                m.insert("end", f"   ** ANOMALY {info['anomaly']:+d}: decoder returned "
                                f"{info['decoded']} pictures,\n"
                                f"      the scan predicted "
                                f"{info['decoded'] - info['anomaly']}. THIS FRAME MAY BE\n"
                                f"      MISALIGNED -- do not trust it as evidence. **\n")
        m.insert("end", f"   timecode    {int(t//60):02d}:{t%60:06.3f}\n")
        if err:
            m.insert("end", f"   !! {err}\n")
        if v.gaps:
            m.insert("end", f"   !! {len(v.gaps)} display slots have no picture "
                            f"(first: {v.gaps[0]})\n")
        m.insert("end", "-" * 52 + "\n")
        m.insert("end", f" DISC frame    {disc}\n")
        m.insert("end", "   (video + leader, same 1:1 map as the .dlv side)\n\n")
        ds = digits_of(disc)
        m.insert("end", f"   {disc:>6d}  digits {' '.join(map(str, ds))}\n")
        if not searchable(disc):
            m.insert("end", "        ** NEGATIVE disc frame -- before disc frame 0, so a\n"
                            "           real LD-V1000 SEARCH cannot reach it. **\n")
        m.insert("end", f"        SEARCH  {hexs(opcode_seq(disc))}\n")
        m.insert("end", "\n   (with 0xFF handshake ACKs, as really sent:)\n")
        m.insert("end", f"   {hexs(opcode_seq(disc, with_acks=True))}\n")

        x = self.diff
        x.delete("1.0", "end")
        s, e = self.seen, self.expected
        x.insert("end", f" SEEN     video {s if s is not None else '--'}"
                        f"   {'disc ' + str(v.vid_to_disc(s)) if s is not None else ''}\n")
        x.insert("end", f" EXPECTED video {e if e is not None else '--'}"
                        f"   {'disc ' + str(v.vid_to_disc(e)) if e is not None else ''}\n")
        x.insert("end", "-" * 52 + "\n")
        if s is None or e is None:
            x.insert("end", " Put this window next to browse_dlv.py, type the SAME\n"
                            " frame number into both, and compare the pictures.\n\n"
                            " If they drift apart at some frame, mark the .dlv frame\n"
                            " that MATCHES this one -> the delta is the packing error.\n")
        else:
            dsc, dec = v.vid_to_disc(s), v.vid_to_disc(e)
            gs, ge = digits_of(dsc), digits_of(dec)
            x.insert("end", f" seen     disc {dsc:05d}  digits {' '.join(map(str, gs))}\n")
            x.insert("end", f" expected disc {dec:05d}  digits {' '.join(map(str, ge))}\n\n")
            x.insert("end", f" delta    {dsc - dec:+d}\n")
            x.insert("end", f" ratio    {dsc / dec:.6f}\n" if dec else " ratio    n/a\n")
            same = "".join("=" if a == b else "^" for a, b in zip(gs, ge))
            x.insert("end", f" digitcmp {' '.join(same)}   (^ = differs)\n\n")
            x.insert("end", f" seen     SEARCH {hexs(opcode_seq(dsc))}\n")
            x.insert("end", f" expected SEARCH {hexs(opcode_seq(dec))}\n")


def main():
    args = [a for a in sys.argv[1:]]
    leader = None
    if "--leader" in args:
        i = args.index("--leader")
        try:
            leader = int(args[i + 1])
        except (IndexError, ValueError):
            sys.exit("--leader needs an integer")
        del args[i:i + 2]
    if not args:
        sys.exit(f"usage: {sys.argv[0]} path/to/file.m2v [--leader N]")
    path = args[0]
    if not os.path.exists(path):
        sys.exit(f"not found: {path}")

    try:
        v = M2v(path, leader)
    except Exception as ex:
        sys.exit(f"failed to open {path}: {ex}")

    print(f"[m2v] {path}")
    print(f"      {v.w}x{v.h} pictures={v.frame_count} fps={v.fps:.4f} "
          f"I-frames={v.i_frames} GOPs={len(v.gops)} leader={v.leader} "
          f"dur={v.duration_s():.1f}s")
    print(f"      >>> compare 'pictures' against the .dlv header's frame_count <<<")
    if v.gaps:
        print(f"      WARNING: {len(v.gaps)} display slots have no picture; "
              f"first at {v.gaps[0]}")
    root = tk.Tk()
    App(root, v)
    root.mainloop()


if __name__ == "__main__":
    main()
