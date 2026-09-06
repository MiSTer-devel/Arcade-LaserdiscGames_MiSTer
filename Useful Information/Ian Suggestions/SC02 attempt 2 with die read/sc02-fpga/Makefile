IVERILOG ?= iverilog
VVP      ?= vvp
PY       ?= python3

RTL := rtl/sc02_top.v rtl/sc02_core.v rtl/sc02_regs.v rtl/sc02_rom.v \
       rtl/sc02_seq.v rtl/sc02_excite.v rtl/sc02_filter.v

GEN := rtl/cos_lut.bin rtl/b2r_lut.bin rtl/rsq_lut.bin \
       rtl/f1_map.bin rtl/f2_map.bin rtl/f3_map.bin

ROM := rom/sc02_phoneme_rom.bin
BITS   ?= rom/die_read.bits   # the community 64 x 27 read
MODE   ?= hybrid              # hybrid | bootstrap | raw
ORIENT ?=                     # e.g. ORIENT="--rotate180" (do not: see README)

ifeq ($(MODE),hybrid)
ROMARGS := --hybrid $(BITS)
else ifeq ($(MODE),raw)
ROMARGS := --bits $(BITS)
else
ROMARGS :=
endif

.PHONY: all sim wav probe flip clean rom luts

all: wav

luts: $(GEN)
$(GEN): tools/coef_build.py tools/sc02_maps.py
	$(PY) tools/coef_build.py

rom: $(ROM)
$(ROM): tools/rom_build.py tools/sc02_maps.py $(BITS)
	$(PY) tools/rom_build.py $(ROMARGS) $(ORIENT) --out $@

.PHONY: analyse
analyse:
	$(PY) tools/rom_analyse.py $(BITS)

build/tb.vvp: $(RTL) tb/tb_sc02.v $(GEN) $(ROM)
	@mkdir -p build
	$(IVERILOG) -g2005 -o $@ tb/tb_sc02.v $(RTL)

sim: build/tb.vvp
	$(VVP) $<

wav: sim
	$(PY) tools/pcm_to_wav.py build/out.pcm -o build/out.wav

probe: $(RTL) tb/tb_probe.v $(GEN) $(ROM)
	@mkdir -p build
	$(IVERILOG) -g2005 -o build/probe.vvp tb/tb_probe.v $(RTL)
	$(VVP) build/probe.vvp

# Render the same phrase both ways round so you can A/B the die-read
# orientation by ear.  See README "Which way up is the ROM?".
flip:
	$(PY) tools/rom_build.py --bits $(BITS) --out $(ROM)
	$(MAKE) sim && $(PY) tools/pcm_to_wav.py build/out.pcm -o build/as_read.wav
	$(PY) tools/rom_build.py --bits $(BITS) --rotate180 --out $(ROM)
	$(MAKE) sim && $(PY) tools/pcm_to_wav.py build/out.pcm -o build/rotated.wav
	@echo "compare build/as_read.wav and build/rotated.wav"

clean:
	rm -rf build
