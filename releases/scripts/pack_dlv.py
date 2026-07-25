#!/usr/bin/env python3
"""
pack_dlv.py  --  build a single mountable .dlv image for the in-fabric DL/SA/TQ video path.

Layout (all sections start on a 512-byte sector boundary so the MiSTer sd_lba block
streamer can seek to sector granularity):

  [Header      1 sector = 512 B]
  [Frame index frame_count * 8 B]   {u32 offset_in_video_blob, u32 size}
  [Video blob  jpegtran'd baseline JPEGs] concatenated, standard 1-table-per-DHT layout
  [Audio blob  s16le 44100 stereo PCM decoded from the *.ogg]

Frame offsets are the PREFIX SUM of the per-frame JPEG sizes taken from the .idx
(column 1). The ffprobe 'pos' column (column 2) is quantised to 4096-byte AVIO
blocks and is NOT used.

disc_fpks is fixed 29970 (NTSC). mpeg_fpks is derived from frame_count and the true
audio duration (both span the full show), so no fps guessing.

Usage:
  python3 pack_dlv.py dragonslair/lair          -> writes dragonslair/lair.dlv
  python3 pack_dlv.py spaceace/ace
  python3 pack_dlv.py thayersquest/tq

The <stem> is the path minus extension; the script expects, next to it:
  <stem>_320x240_q3.mjpeg   (video)      <stem>.idx   (size,pos csv)
  <stem>.ogg                (audio in)   <stem>.txt   (Daphne framefile -> ldframe_offset)
It will run ffmpeg to make <stem>.pcm if that file is missing.
"""
import os, sys, struct, subprocess, shutil

SECTOR   = 512
DISC_FPKS = 29970          # NTSC, fixed for all these games
SRATE    = 44100
CHANS    = 2
MAGIC    = b"DLV1"
VER      = 1
W, H     = 320, 240

def align(f):
    pad = (-f.tell()) % SECTOR
    if pad: f.write(b"\x00" * pad)

def read_sizes(idx_path):
    sizes = []
    with open(idx_path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                sizes.append(int(line.split(",")[0]))   # col1 = size; col2 (pos) ignored
    return sizes

def read_ldframe_offset(txt_path):
    # Daphne framefile: a leading '.' line then '<offset>\t<file>.m2v'.
    # single-file games only (DL2 multi-file is deferred). Grab the first int.
    with open(txt_path) as fh:
        for line in fh:
            tok = line.strip().split()
            if tok and tok[0].lstrip("-").isdigit():
                return int(tok[0])
    raise SystemExit(f"no frame offset found in {txt_path}")

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    stem = sys.argv[1]
    mjpeg = f"{stem}_320x240_q3.mjpeg"
    idx   = f"{stem}.idx"
    ogg   = f"{stem}.ogg"
    txt   = f"{stem}.txt"
    pcm   = f"{stem}.pcm"
    out   = f"{stem}.dlv"

    for p in (mjpeg, idx, ogg, txt):
        if not os.path.exists(p):
            sys.exit(f"missing input: {p}")

    # 1) decode audio to raw PCM if not already done
    if not os.path.exists(pcm):
        print(f"[pcm] ffmpeg {ogg} -> {pcm}")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-i", ogg, "-vn", "-ar", str(SRATE), "-ac", str(CHANS),
                        "-f", "s16le", pcm], check=True)

    # 2) split the mjpeg into frames (via the .idx sizes), transcode EACH through jpegtran to a
    #    baseline JPEG with the standard 1-table-per-DHT layout core_jpeg (SUPPORT_WRITABLE_DHT=0)
    #    requires — see FPGAmp scripts/convert.py. jpegtran changes the byte length, so the index
    #    is rebuilt from the *transcoded* sizes.  (2026-07-04: this step was missing → decoder hung.)
    orig_sizes = read_sizes(idx)
    with open(mjpeg, "rb") as v:
        vdata = v.read()
    if sum(orig_sizes) != len(vdata):
        sys.exit(f"idx size sum {sum(orig_sizes)} != mjpeg size {len(vdata)} (bad idx)")
    frame_count = len(orig_sizes)

    print(f"[jpegtran] transcoding {frame_count} frames to baseline standard-DHT layout ...")
    frames, pos = [], 0
    for i, osz in enumerate(orig_sizes):
        fr = vdata[pos:pos+osz]; pos += osz
        p = subprocess.run(["jpegtran"], input=fr, stdout=subprocess.PIPE, check=True)
        frames.append(p.stdout)
        if (i+1) % 2000 == 0:
            print(f"\r  {i+1}/{frame_count}", end="", flush=True)
    print(f"\r  {frame_count}/{frame_count} done")
    del vdata

    sizes = [len(f) for f in frames]
    vsize = sum(sizes)
    offsets, acc = [], 0
    for s in sizes:
        offsets.append(acc); acc += s
    index_blob = b"".join(struct.pack("<II", o, s) for o, s in zip(offsets, sizes))

    # 3) derived params
    ldoff = read_ldframe_offset(txt)
    asize = os.path.getsize(pcm)
    total_samples = asize // (CHANS * 2)
    dur = total_samples / SRATE
    mpeg_fpks = round(frame_count * 1000.0 / dur)   # video coded rate x1000

    # 4) section geometry (each section sector-aligned)
    hdr_len   = SECTOR
    idx_off   = hdr_len
    idx_len   = len(index_blob)
    vid_off   = idx_off + ((idx_len + SECTOR - 1) // SECTOR) * SECTOR
    aud_off   = vid_off + ((vsize   + SECTOR - 1) // SECTOR) * SECTOR

    hdr = bytearray(SECTOR)
    struct.pack_into("<4sIIII", hdr, 0, MAGIC, VER, W, H, frame_count)
    struct.pack_into("<III",   hdr, 20, DISC_FPKS, mpeg_fpks, ldoff)
    struct.pack_into("<IIQ",   hdr, 32, SRATE, CHANS, total_samples)
    struct.pack_into("<QQ",    hdr, 48, idx_off, idx_len)
    struct.pack_into("<QQ",    hdr, 64, vid_off, vsize)
    struct.pack_into("<QQ",    hdr, 80, aud_off, asize)

    # 5) write
    print(f"[dlv] {out}: frames={frame_count} ldoff={ldoff} "
          f"mpeg_fpks={mpeg_fpks} disc_fpks={DISC_FPKS} "
          f"video={vsize} audio={asize} ({dur:.1f}s)")
    with open(out, "wb") as f:
        f.write(hdr)
        f.write(index_blob); align(f)
        for fr in frames: f.write(fr)          # transcoded baseline JPEGs (jpegtran'd above)
        align(f)
        with open(pcm,   "rb") as a: shutil.copyfileobj(a, f, 1 << 20)
    print(f"[done] {out} = {os.path.getsize(out)} bytes")

if __name__ == "__main__":
    main()
