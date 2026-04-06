# OpenSoC 2D Convolution Engine

## Overview

The 2D Convolution Engine computes the discrete 2D convolution of an INT8 image with a fixed 3×3 INT8 kernel:

```
output[r][c] = sum_{i=0..2, j=0..2} kernel[i*3+j] * input[r+i][c+j]
```

The accelerator reads the input image from DRAM row by row via a DMA master port, stores the last three rows in a line-buffer, and computes one INT32 output pixel per 3×3 sliding window position. Results are written back to DRAM via the same DMA port.

- **Line-buffer sliding window** — three flip-flop row arrays hold the last K rows; the 3×3 window is formed combinationally
- **Fixed 3×3 kernel** — nine INT8 weights loaded via CSRs before asserting GO; KERNEL_SIZE CSR is readable/writable but the FSM hardcodes K=3
- **Two padding modes** — valid-only (output smaller than input) and zero-pad/same (output same size as input)
- **INT8 inputs, INT32 outputs** — each output pixel is the sum of nine signed 16-bit products; no saturation
- **DMA master port** — reads input pixels and writes output pixels via AXI crossbar
- **Maximum image size** — 64×64 pixels (configurable at synthesis via `MAX_IMG_WIDTH`)

Base address: `0x400B0000` (1 kB window). IRQ: `irq_fast_i[8]`.

## Architecture

```
conv2d.sv (control registers + DMA FSM)
├── line_buffer.sv  — 3×MAX_WIDTH INT8 flip-flop arrays; combinational read output
├── conv2d_pe.sv    — 9 INT8×INT8 multipliers + INT32 accumulator (combinational)
└── addr_gen.sv     — DMA read address: src_addr + (row × width + col) × 4
```

### SoC Integration

- **Slave port**: crossbar slave index `Conv2dSlvIdx` (with all accelerators enabled), address `0x400B0000`
- **Master port**: crossbar master index `Conv2dDmaMstIdx` (before PIO DMA), via `axi_from_mem` bridge
- **IRQ**: `irq_fast_i[8]`, level-sensitive (`done & ier`)

## Compute Core

### line_buffer.sv

Three flip-flop arrays of depth `MAX_WIDTH` (default 64), each holding one row of INT8 pixels. The three rows are indexed modulo 3 — the accelerator rotates which physical slot corresponds to the "oldest", "middle", and "newest" row as it advances through the image. Written one pixel per cycle; read combinationally as a full `[3][MAX_WIDTH]` array. Cleared synchronously on `clr_i` (SOFT_RESET).

```
Row slot 0  [ p[0]  p[1]  p[2]  ...  p[63] ]
Row slot 1  [ p[0]  p[1]  p[2]  ...  p[63] ]   ──► pixels_o [3][64]
Row slot 2  [ p[0]  p[1]  p[2]  ...  p[63] ]
```

The FSM selects which physical slot is oldest/middle/newest via modular arithmetic on `cur_row_q`:

```
oldest_slot = (cur_row_q + 1) % 3
middle_slot = (cur_row_q + 2) % 3
newest_slot =  cur_row_q      % 3
```

### conv2d_pe.sv

Nine parallel signed INT8×INT8 multipliers, producing nine INT16 products. The products are sign-extended to INT32 and summed. The output is purely combinational; `conv2d.sv` registers the result before issuing the DMA write.

```
window[0][0]×w[0] ──┐
window[0][1]×w[1] ──┤
window[0][2]×w[2] ──┤
window[1][0]×w[3] ──┤
window[1][1]×w[4] ──┼──► result_o (INT32)
window[1][2]×w[5] ──┤
window[2][0]×w[6] ──┤
window[2][1]×w[7] ──┤
window[2][2]×w[8] ──┘
```

No overflow is possible: the worst case is `9 × 127 × 127 = 145,161`, which is well within INT32 range.

### addr_gen.sv

Computes the DMA read address for any (row, col) position:

```
rd_addr = src_addr + (cur_row × img_width + cur_col) × 4
```

Used for both the FILL phase (pre-loading rows) and the SLIDE phase (reading one pixel per window position). Combinational; shared between both phases via a row/col mux in `conv2d.sv`.

## FSM

The accelerator uses a 7-state FSM. The image is processed in two phases:

**FILL phase** — reads `lag` complete rows into the line buffer before sliding begins. In valid mode `lag = K−1 = 2`; in same mode `lag = K/2 = 1`.

**SLIDE phase** — reads one pixel per position, computes the PE output when the column window is valid (`cur_col_q ≥ lag`), and writes the result. Virtual pixels (zero-padded borders in same mode) skip the DMA read.

```
                  GO
IDLE ──────────────────► FILL_RD_REQ
                              │
                            gnt
                              │
                              ▼
                         FILL_RD_WAIT ◄─────────────────┐
                              │                          │
                           rvalid                        │ more fill cols/rows
                              │                          │
                     fill complete? ─────────────────────┘
                              │ yes
                              ▼
                         SLIDE_RD_REQ ◄─────────────────────────────────┐
                              │                                          │
                     virtual? │ no: assert dma_req                      │
                              │    wait for gnt                         │
                              ▼                                          │
                         SLIDE_RD_WAIT                                   │
                              │                                          │
                    virtual or rvalid                                    │
                              │                                          │
                   write lb; should_output?                              │
                       ┌─yes──┴──no──┐                                  │
                       ▼             └──── advance col/row ─────────────┘
                  SLIDE_WR_REQ
                       │
                     gnt
                       │
                       ▼
                  SLIDE_WR_WAIT
                       │
                     rvalid
                       │
              last output? ─────────────────── advance col/row ─────────┘
                       │ yes
                       ▼
                      IDLE (DONE)
```

**`should_output`** is asserted when `cur_col_q ≥ lag_q` — meaning the full left side of the 3-column window falls within the image (or virtual zero region).

**Virtual pixels** (same mode only): when `cur_col_q ≥ img_width_q` (right border) or `cur_row_q ≥ img_height_q` (bottom border), `skip_dma_q` is set and the pixel value is treated as zero without issuing a DMA read.

## Padding Modes

| Mode | PADDING_MODE | `lag` | Output size | Description |
|------|-------------|-------|-------------|-------------|
| Valid | 0x0 | 2 | `(H−2) × (W−2)` | No padding. First output at `(row=2, col=2)`. |
| Same | 0x1 | 1 | `H × W` | Zero-pad all borders. FILL pre-loads 1 row; virtual pixels supply zeros at left, right, and bottom edges. |

**Valid-mode example:** 8×8 image, 3×3 kernel → 6×6 output (36 pixels).

**Same-mode example:** 8×8 image, 3×3 kernel → 8×8 output (64 pixels). Identity kernel produces `output[r][c] = input[r][c]` for all pixels.

## Register Map

Base address: `0x400B0000`.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x00 | CTRL | W | [0] GO, [1] SOFT_RESET |
| 0x04 | STATUS | R | [0] BUSY, [1] DONE |
| 0x08 | SRC_ADDR | R/W | Input image base address (word-aligned) |
| 0x0C | DST_ADDR | R/W | Output buffer base address (word-aligned) |
| 0x10 | (reserved) | — | — |
| 0x14 | IER | R/W | [0] IRQ enable on completion |
| 0x18 | IMG_WIDTH | R/W | Image width W in pixels (1–64) |
| 0x1C | IMG_HEIGHT | R/W | Image height H in pixels (1–64) |
| 0x20 | KERNEL_SIZE | R/W | Kernel size (read/write, but only K=3 is implemented) |
| 0x24 | PADDING_MODE | R/W | [0] zero-pad enable (0=valid, 1=same) |
| 0x28 | KERNEL_W[0] | R/W | Top-left weight (INT8, sign-extended to 32 bits) |
| 0x2C | KERNEL_W[1] | R/W | Top-center weight |
| 0x30 | KERNEL_W[2] | R/W | Top-right weight |
| 0x34 | KERNEL_W[3] | R/W | Middle-left weight |
| 0x38 | KERNEL_W[4] | R/W | Center weight |
| 0x3C | KERNEL_W[5] | R/W | Middle-right weight |
| 0x40 | KERNEL_W[6] | R/W | Bottom-left weight |
| 0x44 | KERNEL_W[7] | R/W | Bottom-center weight |
| 0x48 | KERNEL_W[8] | R/W | Bottom-right weight |

**Kernel weight layout** (row-major, top-left to bottom-right):

```
W[0]  W[1]  W[2]
W[3]  W[4]  W[5]
W[6]  W[7]  W[8]
```

### CTRL Register (0x00)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | GO | Start convolution. Sampled combinationally; ignored if BUSY. |
| 1 | SOFT_RESET | Clears BUSY and DONE, clears line buffer, returns FSM to IDLE. |

GO is not self-clearing in hardware — software must not hold it asserted across multiple operations.

### STATUS Register (0x04)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | BUSY | Set when the accelerator is running; cleared on DONE or SOFT_RESET. |
| 1 | DONE | Set when the last output pixel has been written. Cleared by next GO or SOFT_RESET. |

### KERNEL_SIZE Register (0x20)

Readable and writable, but the FSM hardcodes K=3. Writing any value other than 3 has no effect on compute behavior.

### PADDING_MODE Register (0x24)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | ZERO_PAD | 0 = valid-only mode; 1 = same/zero-pad mode |

Use `PADDING_MODE = 0x0` for valid-only or `PADDING_MODE = 0x1` for same-size output.

### KERNEL_W Registers (0x28–0x48)

Each register stores one INT8 kernel weight, sign-extended to 32 bits. Only bits [7:0] are used by hardware; bits [31:8] are ignored on write and read back as the sign extension of bit 7. Weights are in row-major order: `W[i*3+j]` applies to `input[r+i][c+j]`.

### Element Packing

Input pixels are stored one INT8 per 32-bit word (bits [7:0] used; bits [31:8] ignored). Each pixel occupies one full word in memory. Source and destination buffers must be word-aligned.

Output elements are written as INT32 words (one 32-bit write per output pixel).

## Interrupt

```
irq_o = done & ier
```

Level-sensitive. DONE persists until the next GO or SOFT_RESET. Clear DONE implicitly by writing GO for the next operation.

## Programming Guide

### 3×3 Edge Detection on an 8×8 Image (Polling, Valid Mode)

```c
int32_t input[8*8]  = { ... };   // 64 INT8 pixels, one per word
int32_t output[6*6];             // 36 INT32 results (valid mode: (8-2)×(8-2))

int8_t kernel[9] = { -1,-1,-1,
                      -1, 8,-1,
                      -1,-1,-1 };

// Load kernel
for (int i = 0; i < 9; i++)
    DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)kernel[i]);

// Configure
DEV_WRITE(CONV2D_IMG_WIDTH,    8);
DEV_WRITE(CONV2D_IMG_HEIGHT,   8);
DEV_WRITE(CONV2D_KERNEL_SIZE,  3);
DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_VALID);
DEV_WRITE(CONV2D_SRC_ADDR,     (uint32_t)input);
DEV_WRITE(CONV2D_DST_ADDR,     (uint32_t)output);

// Launch and poll
DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO);
while (!(DEV_READ(CONV2D_STATUS, 0) & CONV2D_STATUS_DONE))
    ;
```

### Same-Size Output (Zero-Pad Mode)

```c
int32_t input[8*8];
int32_t output[8*8];   // same size as input

DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_SAME);
DEV_WRITE(CONV2D_IMG_WIDTH,  8);
DEV_WRITE(CONV2D_IMG_HEIGHT, 8);
// ... load kernel, addresses, assert GO as above
```

### IRQ-Driven Completion

```c
// Enable IRQ before asserting GO
DEV_WRITE(CONV2D_IER,  CONV2D_IER_DONE);
DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO);

// In ISR (irq_fast_i[8] / mip.MEIP bit 8):
void conv2d_isr(void) {
    // Output is ready — DONE is set
    DEV_WRITE(CONV2D_CTRL, 0);  // DONE clears on next GO
}
```

### SOFT_RESET Between Runs

Always issue SOFT_RESET before reconfiguring for a new image size or kernel, as it clears the line buffer and resets all working counters:

```c
DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);
```

## C Header Definitions

From `sw/include/opensoc_regs.h`:

```c
#define CONV2D_BASE          0x400B0000UL

#define CONV2D_CTRL          (CONV2D_BASE + 0x00)
#define CONV2D_STATUS        (CONV2D_BASE + 0x04)
#define CONV2D_SRC_ADDR      (CONV2D_BASE + 0x08)
#define CONV2D_DST_ADDR      (CONV2D_BASE + 0x0C)
#define CONV2D_IER           (CONV2D_BASE + 0x14)
#define CONV2D_IMG_WIDTH     (CONV2D_BASE + 0x18)
#define CONV2D_IMG_HEIGHT    (CONV2D_BASE + 0x1C)
#define CONV2D_KERNEL_SIZE   (CONV2D_BASE + 0x20)
#define CONV2D_PADDING_MODE  (CONV2D_BASE + 0x24)
#define CONV2D_KERNEL_W(n)   (CONV2D_BASE + 0x28 + (n) * 4)

#define CONV2D_CTRL_GO          0x1
#define CONV2D_CTRL_SOFT_RESET  0x2

#define CONV2D_STATUS_BUSY      0x1
#define CONV2D_STATUS_DONE      0x2

#define CONV2D_IER_DONE         0x1

#define CONV2D_PAD_VALID        0x0
#define CONV2D_PAD_SAME         0x1

#define IRQ_CONV2D  8
```

## File Structure

```
hw/ip/conv2d/
├── conv2d.core              — FuseSoC core (opensoc:ip:conv2d)
└── rtl/
    ├── conv2d.sv            — Control registers + DMA FSM (top-level)
    ├── conv2d_pe.sv         — 9 INT8×INT8 multipliers + INT32 accumulator (combinational)
    ├── line_buffer.sv       — 3×64 INT8 flip-flop row arrays with synchronous clear
    └── addr_gen.sv          — DMA read address generator: src + (row×W + col)×4
```
