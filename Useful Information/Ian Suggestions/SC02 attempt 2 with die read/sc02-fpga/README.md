# sc02-fpga

An FPGA implementation of the Votrax SC-02 / SSI-263 phoneme speech
synthesiser. Register-level behaviour follows the 1985 Votrax datasheet; the
vocal tract is a digital reimplementation of the chip's five cascaded
switched-capacitor sections.

Verified with Icarus Verilog: `make wav` produces `build/out.wav`, ~0.5 s of
speech built from a "hello world", a vowel sweep and a fricative set, driven
through the A/R handshake exactly as a host CPU would.

---

## Status

| Block | State |
|---|---|
| Host bus, 5 attribute registers, D7 read-back | done, datasheet-exact |
| Mode chart, CTL power-down, PD/RST | done |
| Frame / phoneme timing, A/R handshake | done |
| Target interpolation (formants, amplitude, pitch) | done |
| Glottal + noise excitation, inflection divider | done |
| 5-section resonator cascade, FF-scaled sample rate | done |
| Phoneme parameter ROM | die read wired in; source bits decoded, formant bits not |
| Sections 4 and 5 individually programmable | not yet, fixed poles |

Measured against the bootstrap table, the synthesised vowels land within a few
percent of their intended formants:

```
        target F1/F2/F3      measured
EH      550 1750 2450        556 1731 2282
AE      700 1650 2400        677 1631 2296
AH      730 1200 2450        753 1185 2316
AW      600  950 2500        549  925 2600
ER      490 1350 1690        464 1206 1418
```

So the signal path is right. What is not yet right is *which numbers go in*.

---

## The ROM situation

The chip stores 64 phonemes' worth of vocal-tract parameters in an on-die mask
ROM. The datasheet publishes none of it. `rom/die_read.bits` is the community
read of that ROM, taken from the visual6502 SSI-263P die shot: 64 rows of 27
bits, one row per phoneme.

### Orientation: do NOT rotate it

The read was posted with a note saying it is upside down and should be rotated
180 degrees. **That is wrong for the transcription**, and `make analyse` shows
why. Take the eleven columns that are sparse enough to test, and ask what set
of phonemes each one selects:

```
c0   0 = has a closure phase             B D P T K HVC HFC
c1   0 = pause / hold group              PA HV HVC HF HFC HN
c2   0 = dental-alveolar                 T Z S THV TH
c4   1 = unvoiced (noise source)         P T K HF HFC S SCH F TH
c5   1 = fricative group A               P T HF HFC Z S J
c7   0 = low F3 / r-coloured             U1 ER R R1
c10  1 = obstruent group                 P T K S SCH V F
c15  1 = sibilant group                  P T Z S J SCH THV TH
c18  1 = nasal                           HN M N NG
c21  1 = sibilant burst                  P T S
c24  1 = nasal (duplicate of c18)        HN M N NG
```

Eleven of eleven are an *exact* phonetic class in the as-posted row order.
Rotate 180 and the score is zero of eleven — the same columns then pick out
incoherent sets like {IE, I, A, O} and {AH1, U1, UH}. The odds of eleven exact
class matches arising by chance are nil, so the row order as transcribed is
correct. The poster's "it's upside down" almost certainly refers to the die
photograph he was reading from, not to the text he posted.

Column mirroring is a separate question and these tests cannot settle it:
reversing bit order only relabels columns, it cannot change a per-column set
membership. It matters only for multi-bit fields — and as the poster suspected,
most of these bits look like individual filter enables rather than packed
binary.

### Structure: nine 3-bit groups

27 = 9 x 3, and the sparse flag columns land at 24, 21, 18, 15 — every third
column. Grouping the word into nine 3-bit fields makes more structure fall out:

- group 1 (bits 3-5) is 4 for every vowel and sonorant, 0 for the whole
  0x37-0x3F block (nasals plus the German/French vowels), and takes distinct
  low values across the stops and fricatives. A manner/source class code.
- group 3 (bits 9-11) correlates with vowel F1 at rho = +0.67: low vowels
  (AE, AH, AW, UH2) get 5, mid vowels (EH, OO, UH) get 4, high vowels (E, I,
  U, OU) get 0-1. Its middle bit is the c10 obstruent flag, so the F1 data is
  really c9 and c11.
- group 6 (bits 18-20) and group 8 (bits 24-26) both lead with the nasal flag.

That is where the decode stands. The manner and source bits are settled; the
formant bits are located but not calibrated.

### What the build actually uses

Default is **hybrid**: silicon where it is decoded, bootstrap where it is not.

```sh
make rom                    # hybrid (default)
make rom MODE=bootstrap     # acoustic table only, no die data
make rom MODE=raw           # die read packed with the hypothesised field map
make analyse                # the orientation and column report above
```

Hybrid takes voicing and the true-silence closures straight from the die read —
`VD` from column 4, and `CL` for HVC and HFC from columns 0 and 1 — and keeps
formants and amplitudes from the acoustic table, because the bits carrying
those have not been calibrated yet. So the *source* behaviour of all 64
phonemes is now real chip data; the *filter* behaviour is still placeholder.

`MODE=raw` slices the die read with the packed field map in `rom_build.py` and
will not sound like speech. It is there so that when the formant bits are
calibrated, the switch already exists.

### Continuing the decode

The remaining work is calibrating groups 2 to 8 against real silicon. Record an
SSI-263 stepping through all 64 codes at a fixed pitch, amplitude and filter
frequency, take formant tracks, and fit each 2-bit data field against them. The
flags above give you a free consistency check at every step: if a candidate
field assignment implies a voicing that contradicts column 4, the assignment is
wrong.

---

## Design notes

**Sample rate is the switched-capacitor clock.** The tract sections in the real
part are switched-capacitor, so they are already discrete-time, clocked at
`Fs = XCK / (2*(256-FF))`. The digital biquads run at that same rate, which
makes the mapping structural rather than an approximation of a continuous-time
network. It also means the Filter Frequency register works for free: because
formant frequencies and Fs scale together, the coefficients depend only on the
interpolated formant code, and writing FF moves the sample rate and the whole
spectrum with it — the datasheet's "vocal tract length" / voice-type control,
which does not touch pitch.

**Coefficients are Q21, not Q14.** Each section is
`y = (A*x + B*y1 - C*y2) >> 21` with `B = 2r·cosθ`, `C = r²`, `A = 1 - B + C`.
A is a difference of two nearly equal numbers — about 4e-4 for a narrow formant
— so in Q14 it rounds to the integer 7 and the voiced path quantises itself
into silence. This design hit that exact bug during bring-up. If you retune
bandwidths, keep an eye on it.

**Excitation is an impulse train plus a DC blocker,** not a doublet. A doublet
avoids the DC offset without extra logic, but its spectrum nulls at 0 Hz and
rolls off towards the formants, which starves F1. The impulse is spectrally
flat; a first-order high pass at the output removes the offset.

**One multiplier, time-shared.** Five sections × 7 states = 35 clocks per audio
sample. At 20 kHz on a 50 MHz fabric there are ~2500 available, so the whole
tract is a single 24×24 signed multiply and a small coefficient RAM.

### Known deviations from the real part

- Sections 4 and 5 are fixed poles (a ~3.6 kHz upper formant and a ~4.8 kHz
  spectral tilt) rather than individually programmable. The datasheet says all
  five are programmable; the field map above has no bits left for them, which
  is itself a hint the real field map differs. The visible symptom is that /s/
  and /sh/ lose their top end — measured F3 for S comes out at 3.5 kHz where
  the target is 6.5 kHz.
- Amplitude slews at the articulation tick. The datasheet says amplitude
  transitions at a rate dependent on the *duration* setting.
- Transitioned inflection is interpreted as: I10:I6 is the pitch target, I5:I3
  the rate of change, I11 and I2:I0 always immediate. The datasheet is terse
  and this is the reading that makes its two sentences consistent, but it
  quantises the pitch target to 32 steps. Worth checking against silicon.
- Write timing is edge-detected in the FPGA clock domain rather than modelled
  as the datasheet's Ts/Th/Tws analogue timings. Fine for any real host.

---

## Layout

```
rtl/sc02_top.v       pin wrapper: tri-state D7, open-collector A/R
rtl/sc02_core.v      clock enables, integration, DC blocker, sigma-delta
rtl/sc02_regs.v      host bus + the five attribute registers
rtl/sc02_seq.v       frame/phoneme timing, A/R, target interpolators
rtl/sc02_rom.v       64 x 27 phoneme ROM, runtime row_flip
rtl/sc02_excite.v    glottal pulse + LFSR noise
rtl/sc02_filter.v    5-section cascade on a shared multiplier
tools/sc02_maps.py   formant code -> frequency ladders (shared by both tools)
tools/coef_build.py  cos/radius/formant-map LUTs
tools/rom_build.py   bootstrap table + ROM packer, hybrid mode, orientation flags
tools/rom_analyse.py orientation verdict and column-to-phonetic-class decode
rom/die_read.bits    the community 64 x 27 read, as posted (do not rotate)
tools/pcm_to_wav.py  sim output -> listenable wav
tb/tb_sc02.v         host-side driver, full phrase
tb/tb_probe.v        single-vowel internal state trace
```

## Build

```sh
make wav       # luts + rom + compile + simulate + build/out.wav
make probe     # trace pitch, amplitudes, formants through one vowel
make sim       # simulate only
```

Retuning the voice does not need RTL changes: edit `theta()` or the bandwidth
range in `tools/coef_build.py`, or the ladders in `tools/sc02_maps.py`, and
rebuild.
