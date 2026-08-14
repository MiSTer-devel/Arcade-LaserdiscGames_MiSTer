#!/usr/bin/env python3
"""
pack_dlv.py -- one-shot .dlv builder for the in-fabric DL/SA/TQ video path.

Full chain, from Daphne source material to a mountable image. EVERYTHING is read from
--src and the image is written to --dest; nothing is looked up relative to the output.

    --src/<name>.txt   (Daphne framefile) -> leader offset(s) + m2v filename(s)
    --src/<m2v>                           -> ffmpeg  -> scaled 4:2:0 baseline MJPEG
                                          -> jpegtran-> standard 1-table-per-DHT layout
                                          -> split   -> per-frame index
    --src/<audio>                         -> ffmpeg  -> s16le 44100 stereo PCM
                                          -> pack    -> --dest/<name>.dlv

Image layout (every section starts on a 512-byte sector so the MiSTer sd_lba block
streamer can seek at sector granularity):

  [Header      1 sector = 512 B]
  [Frame index frame_count * 8 B]   {u32 offset_in_video_blob, u32 size}
  [Video blob  jpegtran'd baseline JPEGs, concatenated]
  [Audio blob  s16le 44100 stereo PCM]

Usage:
  pack_dlv.py dlair --src ~/daphne/dl  --dest ~/dlv
  pack_dlv.py ace   --src ~/daphne/sa  --dest ~/dlv
  pack_dlv.py tq    --src ~/daphne/tq  --dest ~/dlv  -q 2
  pack_dlv.py       --src ~/daphne/dl  --dest ~/dlv     # <name> auto-discovered

  <name>         game base name (matches <name>.txt in --src). Optional when --src
                 holds exactly one .txt.
  --src DIR      directory holding ALL source files: the .txt framefile, every .m2v
                 it names, and the audio. Nothing is read from anywhere else.
  --dest DIR     where <name>.dlv (and its companion <name>.idx) is written.
  --work DIR     scratch for the big .mjpeg/.pcm intermediates (default: --dest).
                 Worth pointing at a scratch disk: the MJPEG alone is ~700 MB.
  Audio is matched per segment as <m2v-stem>.{ogg,wav,flac,m4a,mp3} first (Daphne's
  own convention, lair.m2v -> lair.ogg), falling back to <name>.<ext>.
  --size WxH     output geometry (default 512x480 -- the NATIVE Daphne m2v size, so no
                 resampling happens at all. Must match FB_COLS_HW/FB_ROWS_HW in
                 Arcade-DragonsLair.sv. 512 is fb_raster_reader's hard width ceiling.
  -q Q           ffmpeg mjpeg quality, 2..31, LOWER IS BETTER (default 3)
  --fbuf-aw N    dlv_streamer.v FBUF_AW; the pack FAILS if any frame does not fit
                 (default 17 = 128 KB, matching the RTL)
  --deint        deinterlace (yadif) -- only if the m2v is interlaced
  --reuse        reuse an existing intermediate .mjpeg instead of re-running ffmpeg
  --jobs N       parallel jpegtran workers (default: cpu_count)

=============================== HEADER v2 =====================================
off  type  field                notes
  0  4s    MAGIC "DLV1"
  4  u32   VER = 2              v1 files remain readable; see samp_per_frame_q16
  8  u32   width
 12  u32   height
 16  u32   frame_count          <- read by dlv_streamer
 20  u32   disc_fpks = 29970    NTSC, fixed
 24  u32   RESERVED = 0         *** was mpeg_fpks -- REMOVED, see below ***
 28  s32   ldframe_offset       <- read by dlv_streamer.  SIGNED (TQ = -16)
 32  u32   srate = 44100
 36  u32   chans = 2
 40  u64   total_samples
 48  u64   index_off            <- read by dlv_streamer
 56  u64   index_len
 64  u64   video_off            <- read by dlv_streamer
 72  u64   video_size
 80  u64   audio_off            <- read by dlv_streamer
 88  u64   audio_size           <- read by dlv_streamer
 96  u32   samp_per_frame_q16   *** NEW *** 16.16 fixed point, see below
100  u32   max_frame_size       *** NEW *** largest single JPEG, for FBUF sizing
104..511   reserved, zero

*** WHY mpeg_fpks IS GONE (offset 24, now RESERVED=0) ***
It was derived by ASSUMING audio duration == video duration, which gives Space Ace
an impossible 41.218 fps.  Nothing has read it since ONE-TO-ONE-FIX-2026-07-16
established that disc->video is 1:1 (Daphne's framefile is a single offset, there is
no fps scaling anywhere in Daphne's model).  Writing 0 makes that explicit so it can
never be resurrected as a video scaler.

*** WHY samp_per_frame_q16 EXISTS (offset 96) ***
The RTL used to compute samples-per-frame as an INTEGER divide:
    (audio_size >> 2) / frame_count  ->  1842  for Dragon's Lair
but the true value is 81343495/44154 = 1842.26786.  That 0.26786 error is then
MULTIPLIED BY THE FRAME NUMBER at every seek re-point:
    aud_target_lba = aud_lba_start + (disc_rel * samp_per_frame) >> 7
so a seek to disc frame 35000 landed the audio 9375 samples = 213 ms off, and the
error grew linearly with disc position -- early scenes near-perfect, late scenes
(rapids, whirlpools) audibly wrong the instant they land, attract (which loops back
to a low frame) fine.  Exactly the reported symptom.

Q16 fixed point fixes it exactly, and costs the FPGA nothing -- it REPLACES a runtime
32-bit divider with a header field, and the multiply fits one Cyclone V DSP:
    aud_target_lba = aud_lba_start + ((disc_rel * samp_per_frame_q16) >> 23)
Residual error: 267 ms -> 0.015 ms.

*** HOW samp_per_frame_q16 IS DERIVED -- FILM-RATE-SPF-2026-07-24, READ THIS ***
    samp_per_frame_q16 = round(SRATE * fps_den / fps_num * 65536)     <- FILM RATE
    (24000/1001 -> 1839.3375 samp/frame -> 120,542,822.  Same for DL, SA and TQ.)
It is NOT round(total_samples * 65536 / frame_count).  That earlier formula assumed the
audio track spans the whole video; it does for DL and TQ, but Space Ace's ace.ogg
(1422.7 s) covers only 34,107 of ace.m2v's 58,643 frames, so SA got 1069.91 samp/frame
= an impossible 41.218 fps, which starved the RTL's frame-lock audio credit to 58% (a
23.9 Hz stutter + 0.42 s of lag per second) and stretched the audio<->video map 1.72x.
Daphne paces the ogg in real time against the m2v's own fps and never uses a
frames<->samples ratio, so a container Daphne plays perfectly broke only in OUR packer.
total_samples / asize still describe how much audio EXISTS; this field is the RATE.

BACKWARD COMPATIBILITY: v1 files have zero at offset 96.  The RTL treats an
out-of-range value as "absent" and falls back to the old computed divide, so an
un-repacked .dlv keeps working exactly as it does today.  No flag day.
===============================================================================
"""
import os, re, sys, mmap, struct, shutil, argparse, subprocess, tempfile
from multiprocessing import Pool, cpu_count

SECTOR    = 512
DISC_FPKS = 29970          # NTSC, fixed for all these games
SRATE     = 44100
CHANS     = 2
MAGIC     = b"DLV1"
VER       = 2


# ----------------------------------------------------------------------------
# FILM-RATE-SPF-2026-07-24
# ----------------------------------------------------------------------------
def probe_fps(m2v_path):
    """-> (num, den) frame rate from the m2v's own MPEG-2 sequence header.

    This is the FILM rate and the ONLY trustworthy source for samples-per-frame.
    DL / Space Ace / Thayer's Quest all report exactly 24000/1001 (23.976 fps).
    See FILM-RATE-SPF-2026-07-24 in main() for why the old audio-length-derived
    value was wrong.
    """
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0",
                          m2v_path],
                         stdout=subprocess.PIPE, check=True).stdout.decode()
    # PARSE-FIX-2026-07-24: `-of csv=p=0` emits a TRAILING COMMA ("24000/1001,"), so a bare
    # split("/") hands int() the string "1001," and dies. Take the first CSV field, and accept a
    # bare integer rate as well as num/den.
    tok = out.strip().split(",")[0].strip()
    try:
        num, den = ((int(x) for x in tok.split("/")) if "/" in tok else (int(tok), 1))
    except ValueError:
        raise SystemExit(f"{m2v_path}: could not parse frame rate {out.strip()!r}")
    if den == 0 or not (10.0 <= num / den <= 60.0):
        raise SystemExit(f"{m2v_path}: implausible frame rate {out}")
    return num, den


# ----------------------------------------------------------------------------
# Daphne framefile
# ----------------------------------------------------------------------------
def read_framefile(txt_path):
    """-> [(disc_frame_offset, m2v_filename), ...] in file order.

    Daphne framefile:
        <base directory>              '.' for DL/SA, '..\\games\\ThayersQuest' for TQ
        <offset>  <file1.m2v>         offset = the DISC FRAME the file's frame 0 shows
        <offset>  <file2.m2v>         ... multi-file games have several of these
    Skip any line whose first token is not an integer, which drops the directory line.
    Offsets may be NEGATIVE (Thayer's Quest is -16): the capture begins BEFORE disc
    frame 0.  DL and Space Ace are single-file; several other Daphne titles are not,
    so every line is kept.
    """
    segs = []
    with open(txt_path) as fh:
        for line in fh:
            tok = line.split()
            if len(tok) >= 2 and re.fullmatch(r"[+-]?\d+", tok[0]):
                segs.append((int(tok[0]), os.path.basename(tok[1].replace("\\", "/"))))
    if not segs:
        raise SystemExit(f"{txt_path}: no '<offset> <file>.m2v' line found")
    segs.sort(key=lambda s: s[0])
    return segs


# ----------------------------------------------------------------------------
# JPEG stream splitting + validation
#
# An MJPEG stream is just concatenated JPEGs.  We walk the marker segments by their
# declared length (so a stray D9 byte inside an APPn/COM payload cannot split a frame
# early), and once we reach SOS we jump straight to the terminating FFD9 with a
# C-speed bytes.find(): inside entropy-coded data a literal FF is always byte-stuffed
# as FF00 and restart markers are FFD0-FFD7, so the first FFD9 after SOS is always the
# real EOI.  Byte-at-a-time scanning would take minutes on a 700 MB stream.
# ----------------------------------------------------------------------------
STANDALONE = {0x01} | set(range(0xD0, 0xD8))     # TEM, RST0-7: no length field


def scan_jpeg(buf, start):
    """Parse one JPEG beginning at `start`. -> (end_offset_exclusive, info)."""
    if buf[start:start + 2] != b"\xff\xd8":
        raise ValueError(f"expected SOI at byte {start}, got {buf[start:start+2].hex()}")
    i = start + 2
    info = {"w": None, "h": None, "sampling": None, "dri": 0, "dht_tables": []}

    while True:
        if buf[i] != 0xFF:
            raise ValueError(f"lost marker sync at byte {i}")
        while buf[i] == 0xFF:                     # skip fill bytes
            i += 1
        marker = buf[i]
        i += 1

        if marker == 0xD9:                        # EOI
            return i, info
        if marker in STANDALONE:
            continue

        seglen = (buf[i] << 8) | buf[i + 1]
        body   = buf[i + 2 : i + seglen]

        if marker in (0xC0, 0xC1):                # SOF0/SOF1 baseline
            info["h"] = (body[1] << 8) | body[2]
            info["w"] = (body[3] << 8) | body[4]
            ncomp = body[5]
            info["sampling"] = [(body[6 + c * 3 + 1] >> 4, body[6 + c * 3 + 1] & 0xF)
                                for c in range(ncomp)]
        elif marker in (0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            raise ValueError(f"non-baseline SOF marker FF{marker:02X} -- core_jpeg is "
                             f"baseline-only (need a plain -f mjpeg encode)")
        elif marker == 0xDD:                      # DRI
            info["dri"] = (body[0] << 8) | body[1]
        elif marker == 0xC4:                      # DHT -- count tables in this segment
            p = 0
            n = 0
            while p < len(body):
                nsym = sum(body[p + 1 : p + 17])
                p += 17 + nsym
                n += 1
            info["dht_tables"].append(n)

        i += seglen

        if marker == 0xDA:                        # SOS -> entropy data -> EOI
            end = buf.find(b"\xff\xd9", i)
            if end < 0:
                raise ValueError(f"no EOI after SOS at byte {i}")
            i = end                               # loop around; next marker IS the EOI


def split_jpegs(buf):
    frames, i, n = [], 0, len(buf)
    while i < n:
        end, _ = scan_jpeg(buf, i)
        frames.append(bytes(buf[i:end]))
        i = end
        while i < n and buf[i] == 0x00:           # tolerate trailing pad
            i += 1
    return frames


def split_bounds(buf, n):
    """Frame (start, end) OFFSETS only -- MEMORY-STREAM-2026-07-24.

    Same walk as split_jpegs, but it never materialises a single frame.  Space Ace is
    58,643 frames / 1.27 GB at 512x480: split_jpegs turned that into 58,643 separate bytes
    objects (a second full copy plus ~2 MB of per-object overhead) on top of the whole file
    already being read into the heap, and Pool.map then pickled EVERY task up-front for a
    third copy -- MemoryError while merely sending work.  Offsets are ~1 MB of ints instead,
    and main() slices frames out of an mmap in bounded batches.
    """
    bounds, i = [], 0
    while i < n:
        end, _ = scan_jpeg(buf, i)
        bounds.append((i, end))
        i = end
        while i < n and buf[i] == 0x00:           # tolerate trailing pad
            i += 1
    return bounds


def check_frame_compat(jpg, want_w, want_h, where, strict_dht=True):
    """Assert one frame is something core_jpeg can actually decode.

    strict_dht=False for the PRE-jpegtran check: ffmpeg legitimately writes a single
    DHT segment carrying all 4 tables, and splitting that into one-table-per-DHT is
    exactly the job jpegtran does below.  Enforcing it before jpegtran would reject
    every valid source.  (Verified 2026-07-24 against the real DL mjpeg: pre = [4],
    post = [1,1,1,1].)
    """
    _, info = scan_jpeg(jpg, 0)
    errs = []
    if (info["w"], info["h"]) != (want_w, want_h):
        errs.append(f"dimensions {info['w']}x{info['h']} != requested {want_w}x{want_h}")
    if info["dri"]:
        errs.append(f"restart interval {info['dri']} -- core_jpeg does NOT support "
                    f"restart markers (re-encode with -threads 1)")
    if info["sampling"] != [(2, 2), (1, 1), (1, 1)]:
        errs.append(f"chroma sampling {info['sampling']} != 4:2:0 [(2,2),(1,1),(1,1)] "
                    f"(need -pix_fmt yuvj420p)")
    if strict_dht and any(n != 1 for n in info["dht_tables"]):
        errs.append(f"DHT segments carry {info['dht_tables']} tables; core_jpeg is built "
                    f"with SUPPORT_WRITABLE_DHT=0 and needs exactly 1 table per DHT "
                    f"(this is what jpegtran normalises -- is jpegtran on PATH?)")
    if errs:
        raise SystemExit(f"[fatal] {where}:\n  - " + "\n  - ".join(errs))
    return info


# ----------------------------------------------------------------------------
def _jpegtran(arg):
    """(idx, frame) -> (idx, bytes, status, err).  status: ok | unusable.

    jpegtran normalises the DHT layout to 1-table-per-DHT, which core_jpeg REQUIRES
    (SUPPORT_WRITABLE_DHT=0).  It is also the FIRST stage that actually entropy-decodes a
    frame, so a frame ffmpeg wrote badly surfaces here and nowhere earlier: split_jpegs /
    scan_jpeg validate MARKER structure only, never Huffman data.

    JPEGTRAN-REPAIR-2026-07-24 -- why this is no longer a bare `check=True`:
    one bad frame out of 58,643 (Space Ace frame 22044) aborted the entire multi-hour run with
    a multiprocessing traceback that named NO frame index and DISCARDED jpegtran's stderr, so
    there was nothing to act on and the whole encode had to be redone to learn anything. Now
    the frame is reported by INDEX with the real stderr, and main() conceals it by HOLD-LAST.

    HOLD-LAST-NOT-REENCODE-2026-07-24: the first attempt at this re-encoded the bad frame via
    ffmpeg. **That produced garbage and was reverted after LOOKING at the result** -- SA frame
    22044 came out 90% flat GREEN (only the top ~12% decoded, 10,001 B vs ~52 KB/~42 KB for its
    neighbours), i.e. a one-frame green flash on screen. Obvious in hindsight: if jpegtran
    cannot entropy-decode the frame, neither can ffmpeg, so a re-encode can only preserve the
    corruption. Holding the previous good frame for one extra 1/24 s is genuinely invisible --
    and 22043/22045 are different scenes, so this frame sits on a hard cut where an extra
    duplicated frame is completely unremarkable.
    ORIGINAL:
        def _jpegtran(fr):
            return subprocess.run(["jpegtran"], input=fr, stdout=subprocess.PIPE,
                                  check=True).stdout

    WINDOWS-TEMPFILE-2026-07-26 -- why this uses NAMED FILES and not a stdin->stdout pipe:
    Windows libjpeg builds are compiled with TWO_FILE_COMMANDLINE, where jpegtran REQUIRES
    an input and an output file. Invoked bare it prints "must name one input and one output
    file" and exits 1, so on Windows EVERY frame came back unusable (reported 2026-07-26
    against the pre-JPEGTRAN-REPAIR packer, which surfaced it as an opaque pool traceback).
    Text-mode stdio on the pipe corrupts entropy data the same way. `jpegtran -outfile OUT IN`
    is accepted by BOTH command-line styles, so this is the portable form, not a Windows
    special case -- output bytes are identical to the piped version on Linux.
    ORIGINAL (piped, Linux-only):
        idx, fr = arg
        try:
            return (idx, subprocess.run(["jpegtran"], input=fr, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, check=True).stdout, "ok", "")
        except subprocess.CalledProcessError as e:
            err = (e.stderr or b"").decode(errors="replace").strip().replace("\n", " ")
            return (idx, b"", "unusable", err or f"jpegtran exit {e.returncode}")
    """
    idx, fr = arg
    fd_i, pi = tempfile.mkstemp(suffix=".jpg")
    fd_o, po = tempfile.mkstemp(suffix=".jpg")
    try:
        os.close(fd_o)                      # jpegtran writes it; mkstemp only reserved the name
        with os.fdopen(fd_i, "wb") as f:
            f.write(fr)
        subprocess.run(["jpegtran", "-outfile", po, pi],
                       stderr=subprocess.PIPE, check=True)
        with open(po, "rb") as f:
            return (idx, f.read(), "ok", "")
    except subprocess.CalledProcessError as e:
        err = (e.stderr or b"").decode(errors="replace").strip().replace("\n", " ")
        return (idx, b"", "unusable", err or f"jpegtran exit {e.returncode}")
    finally:
        for p in (pi, po):
            try:
                os.remove(p)
            except OSError:
                pass


def run(cmd, what):
    print(f"[{what}] {' '.join(str(c) for c in cmd[:6])} ...")
    subprocess.run(cmd, check=True)


def align(f):
    pad = (-f.tell()) % SECTOR
    if pad:
        f.write(b"\x00" * pad)


# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("name", nargs="?", default=None,
                    help="game base name, e.g. dlair. Omit if --src holds exactly one .txt")
    ap.add_argument("--src",  required=True, help="directory holding ALL source files "
                                                 "(.txt framefile, .m2v, audio)")
    ap.add_argument("--dest", default=".",   help="directory to write <name>.dlv into")
    ap.add_argument("--work", default=None,  help="scratch dir for the big .mjpeg/.pcm "
                                                 "intermediates (default: --dest)")
    ap.add_argument("--size", default="512x480",
                    help="output geometry. DEFAULT IS NOW 512x480 = the native Daphne\n                          m2v size, i.e. NO resampling at all. 512 is also exactly\n                          fb_raster_reader's line-buffer ceiling.")
    ap.add_argument("-q", "--quality", type=int, default=3, help="2..31, lower=better")
    ap.add_argument("--fbuf-aw", type=int, default=17, help="dlv_streamer.v FBUF_AW")
    ap.add_argument("--deint", action="store_true")
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--jobs", type=int, default=cpu_count())
    ap.add_argument("--keep", action="store_true",
                    help="keep the .mjpeg/.pcm/.idx intermediates instead of deleting them")
    a = ap.parse_args()

    W, H = (int(v) for v in a.size.lower().split("x"))
    fbuf_bytes = 1 << a.fbuf_aw
    src  = a.src
    dest = a.dest
    work = a.work or dest
    if not os.path.isdir(src):
        sys.exit(f"--src is not a directory: {src}")
    os.makedirs(dest, exist_ok=True)
    os.makedirs(work, exist_ok=True)

    # Framefile: named explicitly, or auto-discovered when --src holds exactly one.
    if a.name:
        name = a.name
        txt  = os.path.join(src, f"{name}.txt")
        if not os.path.exists(txt):
            sys.exit(f"missing framefile: {txt}")
    else:
        found = sorted(f for f in os.listdir(src) if f.lower().endswith(".txt"))
        if len(found) != 1:
            sys.exit(f"--src holds {len(found)} .txt files {found}; name the game explicitly, "
                     f"e.g.  pack_dlv.py dlair --src {src} --dest {dest}")
        name = found[0][:-4]
        txt  = os.path.join(src, found[0])
        print(f"[auto] framefile {found[0]} -> game '{name}'")

    out   = os.path.join(dest, f"{name}.dlv")
    idxo  = os.path.join(work, f"{name}.idx")   # companion index is an INTERMEDIATE
    wtag  = os.path.join(work, f"{name}_{W}x{H}_q{a.quality}")   # intermediate .mjpeg prefix

    # Everything the framefile names is resolved inside --src. Audio is matched to each segment's
    # m2v first (Daphne's own convention, lair.m2v -> lair.ogg) and falls back to the game name,
    # since our tree ships dlair.ogg alongside lair.m2v.
    AUD_EXT = (".ogg", ".wav", ".flac", ".m4a", ".mp3")

    def find_src(fname):
        p = os.path.join(src, fname)
        if not os.path.exists(p):
            sys.exit(f"missing source file: {p}  (named by {txt})")
        return p

    def find_audio(m2v_name):
        bases = [os.path.splitext(m2v_name)[0], name]
        for b in bases:
            for e in AUD_EXT:
                p = os.path.join(src, b + e)
                if os.path.exists(p):
                    return p
        sys.exit(f"no audio for {m2v_name} in {src}; tried " +
                 ", ".join(f"{b}{{{','.join(AUD_EXT)}}}" for b in bases))

    segs = read_framefile(txt)
    base = segs[0][0]                            # disc frame of index entry 0
    multi = len(segs) > 1
    print(f"[framefile] {len(segs)} segment(s), base disc frame {base}: " +
          ", ".join(f"{o}->{n}" for o, n in segs))

    # =========================================================================
    # Pass 1: per segment -- encode, split, normalise, append to the video blob.
    #
    # Frames are streamed straight into a temp blob so we never hold a 700 MB MJPEG
    # AND its transcoded copy in RAM at once; only (offset,size) per frame is kept.
    # =========================================================================
    intermediates = []
    tmp_vid = f"{out}.vid.tmp"
    seg_info = []                                # [(disc_off, [(blob_off,size), ...])]
    sizes_all = []
    vsize = 0
    with open(tmp_vid, "wb") as vb:
        for si, (off, m2v_name) in enumerate(segs):
            seg_mjpeg = wtag + (f".{si}" if multi else "") + ".mjpeg"

            # -- m2v -> scaled 4:2:0 baseline MJPEG ---------------------------
            # -vsync 0 is LOAD-BEARING: a single dup/drop shifts every index entry and
            # breaks the disc->video map.  -threads 1 stops ffmpeg slice-threading,
            # which emits restart markers core_jpeg cannot decode.  -huffman default
            # + jpegtran give the 1-table-per-DHT layout SUPPORT_WRITABLE_DHT=0 needs.
            if a.reuse and os.path.exists(seg_mjpeg):
                print(f"[mjpeg] reusing {seg_mjpeg}")
            else:
                vf = ("yadif," if a.deint else "") + f"scale={W}:{H}:flags=lanczos"
                run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                     "-i", find_src(m2v_name), "-an", "-threads", "1", "-vsync", "0",
                     "-vf", vf, "-pix_fmt", "yuvj420p", "-q:v", str(a.quality),
                     "-huffman", "default", "-f", "mjpeg", seg_mjpeg], f"mjpeg {m2v_name}")

            intermediates.append(seg_mjpeg)
            print(f"[split] scanning {seg_mjpeg} ...")

            # ---- MEMORY-STREAM-2026-07-24 ------------------------------------------------
            # The mjpeg stays in an mmap (never on the heap), we keep only frame OFFSETS, and
            # transcode in bounded BATCHES, writing each frame to tmp_vid as it comes back.
            # Peak RSS is now ~BATCH*2 frames (~25 MB) instead of 3 full copies of the stream.
            # Pool.imap is NOT used: its task feeder races ahead of the workers with an
            # unbounded queue, which is the same MemoryError by another route. Explicit
            # batches give real backpressure. Batches are sequential and Pool.map preserves
            # order within a batch, so global frame order -- which IS the index -- is exact.
            BATCH = 512
            ent, rep = [], []
            # `rep` = frames concealed by hold-last (HOLD-LAST-NOT-REENCODE-2026-07-24)
            first_out = None
            with open(seg_mjpeg, "rb") as v:
                mm = mmap.mmap(v.fileno(), 0, access=mmap.ACCESS_READ)
                try:
                    bounds = split_bounds(mm, mm.size())
                    nfr = len(bounds)
                    check_frame_compat(bytes(mm[bounds[0][0]:bounds[0][1]]), W, H,
                                       f"{seg_mjpeg} frame 0 (pre-jpegtran)", strict_dht=False)
                    print(f"[jpegtran] {nfr} frames on {a.jobs} workers, "
                          f"batches of {BATCH} ...")
                    # JPEGTRAN-REPAIR-2026-07-24: index every frame so a failure can NAME it,
                    # and aggregate in the parent so one bad frame cannot kill the run.
                    with Pool(a.jobs) as pool:
                        for b0 in range(0, nfr, BATCH):
                            batch = [(k, bytes(mm[s:e])) for k, (s, e) in
                                     enumerate(bounds[b0:b0 + BATCH], start=b0)]
                            for i, d, st, err in pool.map(_jpegtran, batch, chunksize=8):
                                if st == "unusable":
                                    # HOLD-LAST-NOT-REENCODE-2026-07-24: conceal by repeating
                                    # the previous good frame -- write NO new bytes, just point
                                    # this index entry at the previous frame's blob extent. The
                                    # .dlv index already has these semantics (pack's hold-last
                                    # across uncaptured disc frames), and the RTL just decodes
                                    # the same JPEG twice. Invisible for one 1/24 s frame.
                                    if not ent:
                                        vb.close()
                                        os.remove(tmp_vid)
                                        sys.exit(
                                            f"[fatal] frame 0 of {seg_mjpeg} is unusable and "
                                            f"there is no previous frame to hold: {err}\n"
                                            f"        Aborted WITHOUT writing {out}.")
                                    rep.append((i, err))
                                    ent.append(ent[-1])          # duplicate = hold-last
                                    sizes_all.append(ent[-1][1])
                                    continue
                                if i == 0:
                                    first_out = d
                                ent.append((vsize, len(d)))
                                sizes_all.append(len(d))
                                vb.write(d)
                                vsize += len(d)
                            del batch
                            if b0 % (BATCH * 20) == 0 and b0:
                                print(f"\r  {b0}/{nfr}", end="", flush=True)
                    print(f"\r  {nfr}/{nfr} done")
                finally:
                    mm.close()

            if rep:
                print(f"[hold-last] {len(rep)} frame(s) had entropy data jpegtran cannot "
                      f"transcode and were CONCEALED by repeating the previous frame: "
                      f"{[i for i, _ in rep][:20]}{' ...' if len(rep) > 20 else ''}")
                print(f"[hold-last]   first: {rep[0][1]}")
                print(f"[hold-last]   disc->video is 1:1, so frame N here = disc frame N+{off}")
                if len(rep) * 200 > nfr:                # >0.5% is not "a bad frame"
                    vb.close()
                    os.remove(tmp_vid)
                    sys.exit(f"[fatal] {len(rep)} of {nfr} frames were unusable "
                             f"({100.0*len(rep)/nfr:.2f}%). That is a systematic encode "
                             f"or split problem, not isolated bad frames, and concealing that "
                             f"many would visibly stutter -- refusing to write a file this "
                             f"rough. Aborted WITHOUT writing {out}.")
            check_frame_compat(first_out, W, H, f"{seg_mjpeg} frame 0 (post-jpegtran)")
            seg_info.append((off, ent))
            # MEMORY-STREAM-2026-07-24: no `del frames` -- there is no whole-segment frame
            # list any more; each frame is written to tmp_vid as it leaves the pool.
            del bounds, first_out

    # -- size guard -----------------------------------------------------------
    # Without this an oversized frame is SILENTLY corrupted on hardware: dlv_streamer
    # does fbuf[bytes_got[FBUF_AW-1:0]] (wraps) and frm_size[FBUF_AW-1:0]-1 (truncates).
    max_sz = max(sizes_all)
    big    = sum(1 for s in sizes_all if s >= fbuf_bytes)
    need   = max(15, (max_sz - 1).bit_length())
    print(f"[frames] {len(sizes_all)} coded  max {max_sz} B  "
          f"mean {sum(sizes_all)//len(sizes_all)} B  "
          f"fbuf {fbuf_bytes} B ({max_sz*100//fbuf_bytes}% full)")
    if big:
        os.remove(tmp_vid)
        sys.exit(f"[fatal] {big} frame(s) >= FBUF ({fbuf_bytes} B); largest {max_sz} B.\n"
                 f"        Set FBUF_AW = {need} in rtl/video/dlv_streamer.v and rebuild,\n"
                 f"        or re-encode with a higher -q (lower quality).")
    if max_sz > fbuf_bytes * 3 // 4:
        print(f"[warn] frames use >75% of FBUF -- little headroom for a quality bump")

    # =========================================================================
    # DENSE, DISC-FRAME-INDEXED TABLE.  Entry i describes DISC frame base+i, so the
    # RTL keeps doing `index_off + (ld_curr_frame - ldoff)*8` with no change at all.
    # A single-file game is the degenerate case and produces a byte-identical table
    # to the old video-frame-indexed one.  Multi-file games have GAPS between
    # segments (disc frames nobody captured); those entries repeat the previous real
    # frame, so the streamer always has a valid JPEG to fetch and the picture simply
    # holds across the gap instead of being fed a zero-length frame.
    # =========================================================================
    span_end    = max(off + len(ent) for off, ent in seg_info)
    frame_count = span_end - base
    covered     = [None] * frame_count
    for off, ent in seg_info:
        for k, e in enumerate(ent):
            covered[off - base + k] = e
    gaps = sum(1 for c in covered if c is None)
    last = next(c for c in covered if c is not None)
    for i in range(frame_count):                 # hold-last across gaps
        if covered[i] is None:
            covered[i] = last
        else:
            last = covered[i]
    if gaps:
        print(f"[index] {frame_count} disc frames, {gaps} uncaptured -> hold-last")

    index_blob = b"".join(struct.pack("<II", o, s) for o, s in covered)

    # =========================================================================
    # AUDIO, laid out over the SAME disc-frame span as the index.  That invariant is
    # what makes one uniform samp_per_frame correct: the RTL's seek re-point is
    #     aud_target = aud_start + disc_rel * samp_per_frame
    # which is only true if the audio blob is dense over [base, span_end).
    # =========================================================================
    seg_pcm = []
    for si, (off, m2v_name) in enumerate(segs):
        src_ogg = find_audio(m2v_name)
        dst_pcm = os.path.join(work, f"{name}.{si}.pcm" if multi else f"{name}.pcm")
        if not os.path.exists(dst_pcm):
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src_ogg,
                 "-vn", "-ar", str(SRATE), "-ac", str(CHANS), "-f", "s16le", dst_pcm],
                f"pcm {os.path.basename(src_ogg)}")
        seg_pcm.append(dst_pcm)
        intermediates.append(dst_pcm)

    # samples per DISC frame: exact for a single segment; from segment 0 otherwise.
    n0  = len(seg_info[0][1])
    spf = (os.path.getsize(seg_pcm[0]) // (CHANS * 2)) / n0
    asize = round(frame_count * spf) * CHANS * 2
    total_samples = asize // (CHANS * 2)
    # ---- FILM-RATE-SPF-2026-07-24 ----------------------------------------------------------
    # samples-per-disc-frame MUST come from the FILM RATE, never from total_samples/frame_count.
    # That ratio silently assumes "the audio track spans the whole video" -- true for Dragon's
    # Lair and Thayer's Quest, FALSE for Space Ace, whose ace.ogg (1422.7 s) covers only 34,107
    # of ace.m2v's 58,643 frames. It therefore wrote spf = 1069.91, an "impossible" 41.218 fps.
    # In the RTL that value IS the frame-lock credit rate (dlv_streamer.v FRAME-LOCK-2026-07-20):
    # audio supply = film_fps * spf must equal 44100, so SA ran at 58.1% of drain -- ~1070 samples
    # drain, then the drain gates off and pcm holds the last sample for ~17.5 ms of every 41.774 ms
    # frame = a 23.9 Hz stutter plus 0.42 s of lag per second played -- AND a 1.72x stretched
    # audio<->video map (aud_target_lba error 17.4 ms per disc frame, linear, re-applied at every
    # SEARCH). Daphne never derives a rate this way: it paces the ogg in real time against the
    # m2v's own fps, which is why a container Daphne plays perfectly was unpackable by this script.
    # The blob geometry (asize / total_samples) is deliberately UNCHANGED -- those describe how much
    # audio exists; spf_q16 describes the RATE. They are independent fields.
    # ORIGINAL: spf_q16 = round(total_samples * 65536 / frame_count)
    fps_num, fps_den = probe_fps(find_src(segs[0][1]))
    spf_film  = SRATE * fps_den / fps_num              # 1839.3375 @ 24000/1001
    spf_q16   = round(spf_film * 65536)                # 120542822 for all three games
    spf_ratio = total_samples / frame_count            # the OLD value -- now only a sanity check
    print(f"[fps] {segs[0][1]}: {fps_num}/{fps_den} = {fps_num/fps_den:.5f} fps "
          f"-> samp/frame {spf_film:.4f}")
    if abs(spf_ratio - spf_film) / spf_film > 0.01:
        print(f"[warn] AUDIO DOES NOT SPAN THE VIDEO: ratio-derived samp/frame {spf_ratio:.3f} vs "
              f"film-rate {spf_film:.3f} ({100.0*spf_ratio/spf_film:.1f}%).\n"
              f"       Using the FILM RATE (correct). The audio covers about "
              f"{total_samples/spf_film:.0f} of {frame_count} disc frames; past that the RTL wraps "
              f"aud_lba back to the blob start (dlv_streamer.v:751), so late scenes would replay "
              f"early-show audio. Harmless if the game never seeks that far.")
    if not (1 << 20) <= spf_q16 < (1 << 27):
        os.remove(tmp_vid)
        sys.exit(f"[fatal] samp_per_frame_q16 = {spf_q16} outside the range the RTL "
                 f"accepts (2^20..2^27); frame rate {fps_num}/{fps_den} looks wrong.")

    idx_off = SECTOR
    idx_len = len(index_blob)
    vid_off = idx_off + ((idx_len + SECTOR - 1) // SECTOR) * SECTOR
    aud_off = vid_off + ((vsize   + SECTOR - 1) // SECTOR) * SECTOR

    hdr = bytearray(SECTOR)
    struct.pack_into("<4sIIII", hdr,  0, MAGIC, VER, W, H, frame_count)
    struct.pack_into("<II",     hdr, 20, DISC_FPKS, 0)      # 24 = RESERVED (was mpeg_fpks)
    struct.pack_into("<i",      hdr, 28, base)              # SIGNED -- TQ is -16
    struct.pack_into("<IIQ",    hdr, 32, SRATE, CHANS, total_samples)
    struct.pack_into("<QQ",     hdr, 48, idx_off, idx_len)
    struct.pack_into("<QQ",     hdr, 64, vid_off, vsize)
    struct.pack_into("<QQ",     hdr, 80, aud_off, asize)
    struct.pack_into("<II",     hdr, 96, spf_q16, max_sz)   # NEW in v2

    print(f"[dlv] {out}: v{VER} {W}x{H} q{a.quality} discframes={frame_count} "
          f"ldoff={base}\n      samp/frame={spf_q16/65536:.5f} (q16={spf_q16})  "
          f"video={vsize} audio={asize} ({total_samples/SRATE:.1f}s)")

    with open(out, "wb") as f:
        f.write(hdr)
        f.write(index_blob); align(f)
        with open(tmp_vid, "rb") as vin:
            shutil.copyfileobj(vin, f, 1 << 20)
        align(f)
        abase = f.tell()
        for (off, ent), p in zip(seg_info, seg_pcm):        # place each at its frame
            want = abase + round((off - base) * spf) * CHANS * 2
            if f.tell() < want:
                f.write(b"\x00" * (want - f.tell()))        # silence across the gap
            with open(p, "rb") as ain:
                shutil.copyfileobj(ain, f, 1 << 20)
        if f.tell() < abase + asize:
            f.write(b"\x00" * (abase + asize - f.tell()))
    os.remove(tmp_vid)

    with open(idxo, "w") as fh:         # companion index (informational; browse_dlv.py reads
        for o, s in covered:            # the index out of the .dlv itself, not from here)
            fh.write(f"{s},{o}\n")

    print(f"[done] {out} = {os.path.getsize(out)} bytes")

    # Clean the intermediates only AFTER the image is fully written -- and only files this run
    # actually produced. Never the whole --work directory: it defaults to --dest, so an rmtree
    # there would delete the .dlv we just made.
    if not a.keep:
        freed = 0
        for p in intermediates + [idxo]:
            if os.path.exists(p) and os.path.abspath(p) != os.path.abspath(out):
                freed += os.path.getsize(p)
                os.remove(p)
        print(f"[clean] removed {len(intermediates)+1} intermediate(s), freed {freed/1e9:.2f} GB "
              f"(--keep to retain)")


if __name__ == "__main__":
    main()
