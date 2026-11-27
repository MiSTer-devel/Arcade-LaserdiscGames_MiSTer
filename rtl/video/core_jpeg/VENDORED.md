# core_jpeg (vendored)

Source: https://github.com/ultraembedded/core_jpeg at commit bb03cce ("Add support for dynamic DHT tables"). Licence: Apache 2.0, see LICENSE.

Only `LICENSE`, `README.md` and `src_v/` are kept; the C model and docs are in the upstream repository.

This used to be a git link with no `.gitmodules` entry, so a fresh clone had an empty folder, and the edits the core needs could not be committed with it. The files are now part of this repository.

Changes from bb03cce (each changed file also says so in its header):

- `jpeg_idct_ram_dp.v`, `jpeg_idct_transpose_ram.v`, `jpeg_output_cx_ram.v`, `jpeg_output_y_ram.v`: the port-1 write is removed. Every instance ties `wr1_i` low, and Quartus cannot infer these RAMs with a write on both ports.
- `jpeg_dht.v`: the standard Huffman table lookup inputs are registered, for timing at the 80 MHz core clock.
- `jpeg_output.v`: the YCbCr to RGB conversion is pipelined one stage (16-bit multiplies, registered terms, pixel x/y/valid delayed to match), for timing at 80 MHz.
