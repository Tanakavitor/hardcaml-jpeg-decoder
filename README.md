# Hardcaml JPEG decoder for the DE10-Standard (Cyclone V 5CSXFC6D6F31C6)

A baseline JPEG decoder written in [Hardcaml](https://github.com/janestreet/hardcaml)
(OCaml), with a ready-to-compile Quartus project for the **Terasic DE10-Standard** board
(Cyclone V SX `5CSXFC6D6F31C6`). The FPGA decodes a JPEG stored in on-chip ROM, shows it on a
VGA monitor, and checks itself with a checksum shown on the LEDs and 7-segment displays.

You don't need OCaml to run it: the generated Verilog is already in `quartus/`.

```mermaid
flowchart LR
    JPG["🖼️ JPEG file<br/><sub>baseline, ≤ 128 KiB</sub>"]:::sw
    ROM["💾 On-chip ROM<br/><sub>jpeg_rom.hex</sub>"]:::mem
    DEC["⚙️ Hardcaml JPEG decoder<br/><sub>parse · Huffman · IDCT · colour</sub>"]:::core
    FB["🧱 Frame buffer<br/><sub>320×240×24 in M10K</sub>"]:::mem
    VGA["🖥️ VGA monitor<br/><sub>640×480 @ 60 Hz</sub>"]:::out
    CHK["✅ Checksum<br/><sub>LEDs + 7-segment</sub>"]:::out

    JPG -- "tools/make_rom.py" --> ROM
    ROM -- "bytes" --> DEC
    DEC -- "RGB pixels" --> FB
    FB -- "2× scaled" --> VGA
    DEC -- "RGB pixels" --> CHK

    classDef sw fill:#fde68a,stroke:#b45309,color:#1f2937
    classDef mem fill:#bfdbfe,stroke:#1d4ed8,color:#1f2937
    classDef core fill:#c4b5fd,stroke:#6d28d9,color:#1f2937,stroke-width:2px
    classDef out fill:#bbf7d0,stroke:#15803d,color:#1f2937
```

---

## 1. Run it on the board (no OCaml needed)

**You need:** Quartus Prime **Lite** 18.1 or newer with *Cyclone V* device support, a
DE10-Standard, its USB-Blaster II cable (the mini-USB "BLASTER" port), and a VGA monitor.

1. Open `quartus/jpeg_de10.qpf` in Quartus and run **Processing → Start Compilation**.
   From a terminal, the same step is:
   ```
   cd quartus
   quartus_sh --flow compile jpeg_de10
   ```
2. Plug the VGA monitor into the board's VGA port and power the board on. Leave the MSEL
   switches (SW10) at their factory setting.
3. Open **Tools → Programmer** and click **Auto Detect**. If Quartus asks which device
   variant to use, pick **5CSXFC6D6**. The JTAG chain contains **two** devices, the ARM HPS
   and the FPGA. Attach `output_files/jpeg_de10.sof` to the **FPGA** (usually the second
   device), tick *Program/Configure*, then click **Start**. From a terminal (run
   `jtagconfig` first to check the device order):
   ```
   quartus_pgm -m jtag -o "p;output_files/jpeg_de10.sof@2"
   ```

### What you should see

* The monitor shows a Mandelbrot picture (the built-in demo JPEG, 320×240, shown 2× at 640×480).
* **LEDR0** (decode finished) and **LEDR1** (checksum matches) are on. **LEDR9** blinks.
* HEX5…HEX0 show **`B93D92`**: the low 24 bits of the checksum of the decoded pixels.
  Push **SW0** up to see the top byte, **`0C`**.
* Press **KEY0** to reset and decode again. The decode takes about 5 ms.

### LEDs, switches, buttons

| Control | Meaning |
|---|---|
| KEY0 | reset and decode again |
| LEDR0 | decode finished |
| LEDR1 | checksum **matches** the expected value (the image is bit-exact) |
| LEDR2 | checksum **mismatch** |
| LEDR3 | decoder error (code on LEDR7..4, see below) |
| LEDR8 | decoder busy |
| LEDR9 | heartbeat (the bitstream is running) |
| all SW down | 7-seg shows checksum bits [23:0] |
| SW0 up | checksum bits [31:24] |
| SW1 up | show the **expected** checksum instead of the computed one |
| SW2 up | image width (HEX5-3) and height (HEX2-0), in hex |
| SW3 up | decode time in microseconds, in hex |

Error codes on LEDR7..4: 1 progressive/arithmetic/lossless JPEG, 2 not 8-bit,
3 not 1 or 3 components, 4 unsupported subsampling, 5 multi-scan file, 6 invalid Huffman
code (corrupt data), 8 bad DHT, 9 bad DQT, 10 bad segment length, 11 height 0 (DNL),
12 not a JPEG (does not start with FF D8).

## 2. Show your own picture

```
python3 tools/make_rom.py my_picture.jpg     # Python 3 only, no extra packages
```

This rewrites `quartus/jpeg_rom.hex` (the ROM contents) and `quartus/jpeg_expected.vh`
(the checksum the hardware must reproduce, computed by a bit-exact Python model). Recompile
in Quartus and program the board again. The script refuses files the hardware can't decode.

The picture must be:
* a **baseline** JPEG (not progressive), 8-bit, colour or greyscale;
* at most **128 KiB**;
* chroma subsampling 4:2:0, 4:2:2, 4:4:0 or 4:4:4 (what normal cameras and editors produce).

Any size up to 65535×65535 decodes, but only the top-left **320×240** pixels fit in the
frame buffer and are displayed. To make a fitting file with ImageMagick:
```
magick photo.jpg -resize 320x240 -interlace none -sampling-factor 4:2:0 -quality 90 small.jpg
```

## 3. What the decoder supports

* SOF0 (baseline) and SOF1 (extended sequential, 8-bit, Huffman), with 8- or 16-bit
  quantisation tables and up to 4 DC + 4 AC Huffman tables.
* Grayscale, or YCbCr with luma sampling 1×1, 2×1, 1×2 or 2×2 (chroma 1×1).
* Restart markers (DRI / RSTn), APPn/COM segments (skipped), EXIF thumbnails, fill bytes.
* Output is **bit-exact with libjpeg-turbo** run as `djpeg -dct int -nosmooth`. That means
  libjpeg's accurate integer IDCT (`jidctint.c`), its YCbCr→RGB tables, and
  replicated ("box") chroma upsampling. Ordinary image viewers smooth the chroma instead,
  so 4:2:0 pictures can differ from them by a few levels on colour edges.

Not supported: progressive JPEG, arithmetic coding, 12-bit, lossless, CMYK/Adobe RGB, and
files that put each component in its own scan.

## 4. How it works

### Data path

Everything runs on the single 50 MHz clock. Bytes flow left to right; the colour stage emits
about one pixel per cycle.

```mermaid
flowchart TB
    subgraph IN["① Input · src/system.ml"]
        direction LR
        ROM[("JPEG ROM<br/>128 KiB · M10K")]:::mem --> STR["ROM streamer<br/><sub>ready/valid byte stream</sub>"]:::io
    end

    subgraph ENT["② Entropy decoding · src/decoder.ml"]
        direction LR
        BB["32-bit bit buffer<br/><sub>unstuffs FF 00, stops at markers</sub>"]:::core
        MP["Marker parser<br/><sub>SOI · SOF · DHT · DQT · DRI · SOS · RSTn · EOI</sub>"]:::core
        HUF["Huffman decoder<br/><sub>16 code lengths compared in parallel</sub>"]:::core
        DQ["Dequantise + de-zigzag<br/><sub>64-register block</sub>"]:::core
        BB --> MP -- "tables" --> HUF
        BB -- "bits" --> HUF --> DQ
    end

    subgraph REC["③ Reconstruction · src/idct.ml + src/decoder.ml"]
        direction LR
        IDCT["8×8 IDCT<br/><sub>2 passes · 6-stage · 39-bit<br/>bit-exact jidctint.c</sub>"]:::dsp
        MCU[("MCU buffer<br/><sub>16×16 Y · 8×8 Cb · 8×8 Cr</sub>")]:::mem
        CC["Upsample + YCbCr → RGB<br/><sub>libjpeg tables · ~1 px/cycle</sub>"]:::dsp
        IDCT --> MCU --> CC
    end

    subgraph OUT["④ Output · src/system.ml"]
        direction LR
        FB[("Frame buffer<br/>320×240×24")]:::mem --> VGAT["VGA timing<br/><sub>640×480 @ 60 Hz, 2× scale</sub>"]:::io --> MON["🖥️ VGA monitor"]:::out
        SUM["Checksum + status"]:::io --> LED["💡 LEDR · HEX5..0"]:::out
    end

    IN == "bytes" ==> ENT
    ENT == "8×8 coefficient blocks" ==> REC
    REC == "(x, y, R, G, B) pixels" ==> OUT

    classDef mem fill:#bfdbfe,stroke:#1d4ed8,color:#1f2937
    classDef core fill:#ddd6fe,stroke:#6d28d9,color:#1f2937
    classDef dsp fill:#fbcfe8,stroke:#be185d,color:#1f2937
    classDef io fill:#fef3c7,stroke:#b45309,color:#1f2937
    classDef out fill:#bbf7d0,stroke:#15803d,color:#1f2937
    style IN fill:#fffbeb,stroke:#b45309
    style ENT fill:#f5f3ff,stroke:#6d28d9
    style REC fill:#fdf2f8,stroke:#be185d
    style OUT fill:#f0fdf4,stroke:#15803d
```

### Control: the decoder state machine

A single state machine in `src/decoder.ml` walks the file's segments, then loops over MCUs
and 8×8 blocks until the scan ends.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> SOI: reset
    SOI --> FindMarker: FF D8
    SOI --> Error: not a JPEG

    state "Header segments" as Headers {
        FindMarker --> Dispatch: FF xx
        Dispatch --> SOF: C0 / C1
        Dispatch --> DHT: C4
        Dispatch --> DQT: DB
        Dispatch --> DRI: DD
        Dispatch --> Skip: APPn / COM
        SOF --> FindMarker
        DHT --> FindMarker
        DQT --> FindMarker
        DRI --> FindMarker
        Skip --> FindMarker
    }

    Dispatch --> SOS: DA
    SOS --> Scan

    state "Entropy-coded scan" as Scan {
        [*] --> Block
        Block --> Huffman: next coefficient
        Huffman --> Block: write coef
        Block --> IDCT: 64 coefs / EOB
        IDCT --> Block: more blocks in MCU
        IDCT --> Colour: MCU complete
        Colour --> [*]
    }

    Scan --> Scan: next MCU / RSTn
    Scan --> Finished: last MCU
    Dispatch --> Finished: EOI (D9)
    Finished --> [*]
    Dispatch --> Error: unsupported
```

### From OCaml to pixels

```mermaid
flowchart LR
    ML["📝 Hardcaml sources<br/><sub>src/*.ml</sub>"]:::sw
    GEN["dune exec<br/>bin/gen_verilog.exe"]:::tool
    V["Verilog<br/><sub>quartus/jpeg_system.v<br/>rtl/jpeg_decoder.v</sub>"]:::art
    PIC["🖼️ your_picture.jpg"]:::sw
    MK["tools/make_rom.py<br/><sub>+ bit-exact Python model</sub>"]:::tool
    HEX["jpeg_rom.hex<br/>jpeg_expected.vh"]:::art
    Q["Quartus compile"]:::tool
    SOF["jpeg_de10.sof"]:::art
    B["🔌 DE10-Standard"]:::out

    ML --> GEN --> V --> Q
    PIC --> MK --> HEX --> Q
    Q --> SOF -- "USB-Blaster II" --> B

    classDef sw fill:#fde68a,stroke:#b45309,color:#1f2937
    classDef tool fill:#e2e8f0,stroke:#475569,color:#1f2937
    classDef art fill:#bfdbfe,stroke:#1d4ed8,color:#1f2937
    classDef out fill:#bbf7d0,stroke:#15803d,color:#1f2937
```

### The pieces

* `src/decoder.ml`: the decoder core. A single state machine parses the markers and drives
  the entropy decoder. The 32-bit bit buffer refills in the background, removes stuffed
  bytes and stops at markers. The Huffman decoder compares all 16 code lengths in parallel.
  Coefficients are dequantised as they are written into a 64-register block.
* `src/idct.ml`: the 8×8 IDCT, one 8-point 39-bit datapath used for both passes. It is
  exactly libjpeg's `jidctint.c`: pass 2 only needs its sum modulo 2^28, so pass 1 only
  needs modulo 2^39, and the result is still bit-exact.
* `src/system.ml`: the board system: ROM streamer, 320×240×24 frame buffer,
  640×480@60 VGA timing (25 MHz clock enable), checksum, LEDs and 7-segment displays.
  Everything runs on the single 50 MHz clock.
* `quartus/de10_standard_top.v`: maps the generated `jpeg_system` to the board pins and
  adds the power-on/KEY0 reset. `quartus/jpeg_rom.v` holds the JPEG (`$readmemh`).

Checksum: sum over all pixels of `(2·(y·W + x) + 1) · (R | G<<8 | B<<16)` mod 2^32
(`tools/jpeg_ref.py` computes the same value).

Size (Yosys `synth_intel_alm -family cyclonev` estimate for the decoder core alone):
about 8.4K LUTs (roughly 5K of the chip's ~42K ALMs), 10K flip-flops and 29 DSP
multipliers. The board system adds a 1.8 Mbit frame buffer and a 1 Mbit ROM in M10K block
RAM, roughly 350 of the chip's 514 M10K blocks. Quartus's own numbers will differ somewhat.

Speed: about 1 pixel/cycle in the colour stage, and roughly 4–8 cycles per non-zero
coefficient. A 320×240 4:2:0 image takes about 5 ms; a 1680×954 photo takes about 100 ms
(at 50 MHz).

## 5. How it was verified

* **Hardcaml cycle simulation of the core against libjpeg-turbo** (`djpeg -dct int -nosmooth`).
  44 generated test JPEGs covering 4:4:4, 4:2:2, 4:4:0, 4:2:0, greyscale, restart intervals,
  optimised Huffman tables, 16-bit quant tables (SOF1), and odd sizes (17×9, 77×53).
  Each one was run twice, with and without random gaps in the input stream: **88/88
  bit-exact**. Baseline JPEGs from other encoders (500×500 with DRI, 1680×954, 256×256,
  340×200 4:2:0) were also **bit-exact**. Progressive files are rejected with error 1.
* **Python model** `tools/jpeg_ref.py` gives identical output to djpeg on all of them.
* **Whole-system simulation** (`test/sim_system.ml`): ROM → decoder → frame buffer → VGA pins.
  It checks the LEDs, the 800-clock line and 525-line frame timing, and compares all
  307,200 pixels of a captured VGA frame with the reference.
* **The exact Quartus sources** (`de10_standard_top.v` + `jpeg_rom.v` + generated
  `jpeg_system.v` + `jpeg_rom.hex`) were simulated with Icarus Verilog.
* Pin assignments come from the Terasic DE10-Standard user manual, cross-checked against
  Terasic golden-top `.qsf` files.

**Not verified:** this was **not compiled with Quartus** (it was built on a Mac, where
Quartus doesn't run), so the Quartus fit and timing report are untested. The design targets
50 MHz with registered pipeline stages. Check *Timing Analyzer → Slow 1100mV 85C Model →
Fmax* after compiling.

## 6. Rebuilding from the Hardcaml sources (optional)

```
opam install hardcaml ppx_hardcaml ppx_jane      # tested with v0.17
dune build
dune exec bin/gen_verilog.exe -- .               # writes quartus/jpeg_system.v and rtl/jpeg_decoder.v

# core simulation against djpeg (libjpeg-turbo), e.g.
python3 tools/make_test_images.py testdata
djpeg -dct int -nosmooth -pnm -outfile ref.pnm testdata/t_77x53_420.jpg
./_build/default/test/sim_decoder.exe testdata/t_77x53_420.jpg -ref ref.pnm -stall

# whole board: ROM -> decoder -> VGA pins
python3 tools/jpeg_ref.py images/demo_320x240.jpg -o ref.ppm    # prints the checksum
./_build/default/test/sim_system.exe images/demo_320x240.jpg ref.ppm 0CB93D92
```

`rtl/jpeg_decoder.v` is the core on its own, with a ready/valid byte input and an
`(x, y, r, g, b)` pixel output stream, for use in other designs.

### Using a different board

Only `quartus/de10_standard_top.v` and the pin section of `quartus/jpeg_de10.qsf` are
board-specific. The Intel Cyclone V SX SoC Development Kit uses the same chip with a
different pinout. The DE1-SoC and SoCKit use other chips.
