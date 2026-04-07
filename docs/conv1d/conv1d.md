# OpenSoC 1D Convolution Engine

## Overview

The 1D Convolution Engine computes the discrete convolution of an INT8 input signal with a runtime-configurable kernel of up to 16 INT8 weights:

```
y[n] = sum(x[n+k] * w[k]) for k = 0..KERNEL_SIZE-1
```

The accelerator reads the input signal from DRAM via a DMA master port, passes each sample through a shift register, computes the inner product against kernel weights loaded via control registers, and writes the output elements back to DRAM.

- **Sliding-window compute** — shift register holds the current window; one output element per DMA read after the initial fill
- **Runtime kernel configuration** — up to 16 INT8 weights written via CSRs before asserting GO
- **Two padding modes** — valid-only (output shorter than input) and zero-pad/same (output same length as input)
- **INT8 inputs, INT32 outputs** — each output element is the sum of up to 16 signed 16-bit products
- **DMA master port** — reads input samples and writes output elements via AXI crossbar
- **AXI-Stream output port** — in stream mode, results are forwarded directly to a downstream accelerator without a DRAM round-trip

Base address: `0x40090000` (1 kB window). IRQ: `irq_fast_i[7]`.

## Architecture

```
conv1d.sv (control registers + DMA FSM)
├── shift_reg.sv    — Parameterized shift register (DEPTH=KERNEL_SIZE)
└── conv1d_pe.sv    — KERNEL_SIZE parallel INT8×INT8 multipliers + INT32 accumulator
```

### SoC Integration

- **Slave port**: crossbar slave index 10 (with all Phase 1/2 accels enabled), address `0x40090000`
- **Master port**: crossbar master index 6 (before PIO DMA), via `axi_from_mem` bridge
- **IRQ**: `irq_fast_i[7]`, level-sensitive (`done & ier`)

## Compute Core

### shift_reg.sv

A parameterized shift register with `DEPTH = KERNEL_SIZE` and `WIDTH = 8` (INT8). One new sample is loaded per cycle when the DMA returns valid data. The register presents all `DEPTH` entries simultaneously to the PE.

```
Input sample (INT8)
       │
       ▼
  ┌────────┐  ┌────────┐  ┌────────┐       ┌────────┐
  │ reg[0] │→ │ reg[1] │→ │ reg[2] │→ ... →│reg[N-1]│
  └────────┘  └────────┘  └────────┘       └────────┘
       │            │           │                │
    w[0]         w[1]        w[2]            w[N-1]   (kernel weights)
       │            │           │                │
       └────────────┴───────────┴────────────────┘
                              │
                         conv1d_pe
```

### conv1d_pe.sv

`KERNEL_SIZE` parallel signed multipliers, each computing `reg[k] * w[k]` (INT8 × INT8 → INT16). The products are summed into a single INT32 accumulator. One valid output is produced per cycle when `valid_i` is asserted (i.e., after the shift register has been filled for the first time and on every subsequent shift).

```
reg[0]×w[0] ──┐
reg[1]×w[1] ──┤
reg[2]×w[2] ──┼──► partial_sum (INT32) ──► result_o (INT32)
    ⋮         │
reg[N-1]×w[N-1]┘
```

No saturation is applied at the PE level — INT8×INT8 products fit in INT16, and the sum of 16 such products fits within INT32 range.

## FSM

```
              GO
IDLE ─────────────────► RD_REQ
                           │
                         gnt
                           │
                           ▼
                        RD_WAIT ◄──────────────────────────┐
                           │                               │
                         rvalid                            │
                           │                               │
                    shift sample in                        │
                    compute PE output                      │
                           │                               │
                   kernel full?                            │
                    ┌──yes─┴──no──┐                        │
                    ▼             ▼                        │
                 WR_REQ        RD_REQ ─► (next sample) ───┘
                    │
                  gnt
                    │
                    ▼
                 WR_WAIT
                    │
                  rvalid
                    │
          samples remaining?
              ┌──yes──┴──no──┐
              ▼              ▼
           RD_REQ           IDLE (DONE)
```

**Stream mode** (`CTRL[2]=1`): the `WR_REQ`/`WR_WAIT` states are bypassed. After each PE result is captured the FSM enters `STREAM_OUT`, drives the AXI-Stream output, and waits for `m_axis_tready` before advancing to the next read or returning to IDLE.

```
              GO (stream mode)
IDLE ──────────────────► RD_REQ
                            │
                          gnt
                            ▼
                         RD_WAIT
                            │ rvalid + kernel full
                            ▼
                        STREAM_OUT  ◄── holds until m_axis_tready
                            │
                  last element?
                    ┌──yes──┴──no──┐
                    ▼              ▼
                   IDLE          RD_REQ
```

**Causal zero-pad mode (same):** before the first real read, `KERNEL_SIZE-1` virtual-zero samples are pre-counted in the fill counter, so the first output is produced immediately after the first real read. The pre-fill does not generate DMA reads. The output formula is:

```
out[n] = x[n]*w[0] + x[n-1]*w[1] + ... + x[n-K+1]*w[K-1]
```

with `x[negative] = 0`. Note: `w[0]` is applied to the newest (most-recently-read) sample, which is the standard cross-correlation convention.

**Valid-only mode:** the first output element is produced only after `KERNEL_SIZE` real input samples have been loaded. Output length is `LENGTH - KERNEL_SIZE + 1`.

## Register Map

Base address: `0x40090000`.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x00 | CTRL | W | [0] GO, [1] SOFT_RESET |
| 0x04 | STATUS | R | [0] BUSY, [1] DONE |
| 0x08 | SRC_ADDR | R/W | Input signal base address (word-aligned) |
| 0x0C | DST_ADDR | R/W | Output buffer base address (word-aligned) |
| 0x10 | LENGTH | R/W | Number of INT8 input samples |
| 0x14 | IER | R/W | [0] IRQ enable on completion |
| 0x18 | KERNEL_SIZE | R/W | Convolution kernel length (1–16) |
| 0x1C | PADDING_MODE | R/W | [0] zero-pad enable, [1] same vs valid |
| 0x20 | KERNEL_W[0] | R/W | Kernel weight 0 (INT8, sign-extended to 32 bits) |
| 0x24 | KERNEL_W[1] | R/W | Kernel weight 1 |
| 0x28 | KERNEL_W[2] | R/W | Kernel weight 2 |
| 0x2C | KERNEL_W[3] | R/W | Kernel weight 3 |
| 0x30 | KERNEL_W[4] | R/W | Kernel weight 4 |
| 0x34 | KERNEL_W[5] | R/W | Kernel weight 5 |
| 0x38 | KERNEL_W[6] | R/W | Kernel weight 6 |
| 0x3C | KERNEL_W[7] | R/W | Kernel weight 7 |
| 0x40 | KERNEL_W[8] | R/W | Kernel weight 8 |
| 0x44 | KERNEL_W[9] | R/W | Kernel weight 9 |
| 0x48 | KERNEL_W[10] | R/W | Kernel weight 10 |
| 0x4C | KERNEL_W[11] | R/W | Kernel weight 11 |
| 0x50 | KERNEL_W[12] | R/W | Kernel weight 12 |
| 0x54 | KERNEL_W[13] | R/W | Kernel weight 13 |
| 0x58 | KERNEL_W[14] | R/W | Kernel weight 14 |
| 0x5C | KERNEL_W[15] | R/W | Kernel weight 15 |

### CTRL Register (0x00)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | GO | Start convolution. Sampled on the rising edge; ignored if BUSY. |
| 1 | SOFT_RESET | Clears BUSY and DONE, resets shift register and FSM to IDLE. |
| 2 | STREAM_MODE | When set, results are emitted via AXI-Stream output instead of being written back to DRAM. DST_ADDR is unused. |

GO is not self-clearing in hardware — software must not hold it asserted across multiple operations.

### STATUS Register (0x04)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | BUSY | Set when the accelerator is running; cleared on DONE or SOFT_RESET. |
| 1 | DONE | Set when the last output element has been written. Cleared by next GO or SOFT_RESET. |

### KERNEL_SIZE Register (0x18)

Number of kernel weights to use (1–16). Weights beyond KERNEL_SIZE are ignored. Writing 0 or a value greater than 16 is undefined behavior.

### PADDING_MODE Register (0x1C)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | ZERO_PAD | If set, zero-pad the input signal at the boundaries. |
| 1 | SAME | If set (and ZERO_PAD=1), output length equals input length (same-length mode). If clear (and ZERO_PAD=1), same zero-padding but output length still follows valid-only formula — this combination is reserved; do not use. |

In practice, use `PADDING_MODE = 0x00` for valid-only or `PADDING_MODE = 0x03` for same/zero-pad.

### KERNEL_W Registers (0x20–0x5C)

Each register stores one INT8 kernel weight, sign-extended to 32 bits. Only bits [7:0] are used by hardware; bits [31:8] are ignored on write and read back as zero. Weight 0 is applied to the oldest sample in the shift register (standard convolution convention).

### Element Packing

Input samples are stored in memory as packed bytes. The DMA reads full 32-bit words; the accelerator uses only byte [7:0] of each word as one INT8 sample. Source and destination buffers must be word-aligned, and each INT8 element occupies one full word in memory (one sample per DMA transaction).

Output elements are written as INT32 words (one 32-bit write per output sample).

## Padding Modes

| Mode | PADDING_MODE | Output length | Description |
|------|-------------|--------------|-------------|
| Valid-only | 0x00 | `LENGTH - KERNEL_SIZE + 1` | No padding. First output after `KERNEL_SIZE` reads. |
| Causal same | 0x03 | `LENGTH` | Pre-counts `KERNEL_SIZE-1` virtual-zero samples; first output after the first real read. |

**Valid-only example:** 16-element input, 3-tap kernel → 14 output elements.

**Same example:** 8-element input, 3-tap kernel → 8 output elements. out[0] = x[0]·w[0], out[1] = x[1]·w[0] + x[0]·w[1], etc.

## Interrupt

```
irq_o = done & ier
```

Level-sensitive. DONE persists until the next GO or SOFT_RESET. Clear DONE implicitly by writing GO for the next operation.

## Stream Mode

Conv1D can forward its results directly to a downstream accelerator over a hardwired AXI-Stream connection, eliminating the DRAM write/read round-trip between stages.

### AXI-Stream Output Port

| Signal | Direction | Description |
|--------|-----------|-------------|
| `m_axis_tvalid_o` | Output | High when a result beat is available (FSM in `STREAM_OUT`). |
| `m_axis_tready_i` | Input | Asserted by the downstream consumer to accept the beat. |
| `m_axis_tdata_o` | Output | INT32 convolution result (same value that would be written to DRAM in DMA mode). |
| `m_axis_tlast_o` | Output | High on the last beat of the sequence. |

### Wiring in `opensoc_top.sv`

The `conv1d_to_relu_*` signals connect Conv1D's stream output to ReLU's stream input (Config 1 pipeline):

```systemverilog
// Config 1: Conv1D → ReLU
conv1d_to_relu_tvalid  ←  u_conv1d.m_axis_tvalid_o
conv1d_to_relu_tready  →  u_conv1d.m_axis_tready_i
conv1d_to_relu_tdata   ←  u_conv1d.m_axis_tdata_o
conv1d_to_relu_tlast   ←  u_conv1d.m_axis_tlast_o
```

### Software Sequence (Config 1: Conv1D → ReLU)

```c
// 1. Configure Conv1D in stream mode
for (int i = 0; i < ksize; i++)
    DEV_WRITE(CONV1D_KERNEL_W(i), weights[i]);
DEV_WRITE(CONV1D_KERNEL_SIZE,  ksize);
DEV_WRITE(CONV1D_PADDING_MODE, CONV1D_PAD_VALID);
DEV_WRITE(CONV1D_SRC_ADDR,     (uint32_t)input);
DEV_WRITE(CONV1D_LENGTH,       in_len);
// DST_ADDR unused in stream mode

// 2. Configure ReLU in stream mode
DEV_WRITE(RELU_DST_ADDR, (uint32_t)output);
DEV_WRITE(RELU_LEN,      out_len);   // LENGTH - KERNEL_SIZE + 1

// 3. GO: ReLU first (waits for stream), then Conv1D
DEV_WRITE(RELU_CTRL,   RELU_CTRL_GO | RELU_CTRL_STREAM_MODE);
DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_GO | CONV1D_CTRL_STREAM_MODE);

// 4. Poll ReLU DONE
while (!(DEV_READ(RELU_STATUS, 0) & RELU_STATUS_DONE))
    ;
```

ReLU must receive GO before Conv1D starts producing beats, so that its `STREAM_IN` state is ready to accept the first valid beat without stalling.

## Programming Guide

### Basic 3-Tap FIR Filter (Polling)

```c
int8_t  signal[16] = { ... };       // input: 16 INT8 samples
int32_t output[14];                 // output: 14 INT32 results (valid-only, 3-tap)

int8_t kernel[3] = { 1, 2, 1 };    // 3-tap averaging filter (unnormalized)

// Load kernel weights
DEV_WRITE(CONV1D_KERNEL_W(0), (uint32_t)(int32_t)kernel[0]);
DEV_WRITE(CONV1D_KERNEL_W(1), (uint32_t)(int32_t)kernel[1]);
DEV_WRITE(CONV1D_KERNEL_W(2), (uint32_t)(int32_t)kernel[2]);

// Configure
DEV_WRITE(CONV1D_KERNEL_SIZE, 3);
DEV_WRITE(CONV1D_PADDING_MODE, 0x00);   // valid-only
DEV_WRITE(CONV1D_SRC_ADDR,  (uint32_t)signal);
DEV_WRITE(CONV1D_DST_ADDR,  (uint32_t)output);
DEV_WRITE(CONV1D_LENGTH,    16);

// Launch and wait
DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_GO);
while (!(DEV_READ(CONV1D_STATUS, 0) & CONV1D_STATUS_DONE))
    ;
```

### IRQ-Driven Completion

```c
// Enable IRQ before asserting GO
DEV_WRITE(CONV1D_IER, CONV1D_IER_DONE);
DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_GO);

// In ISR (irq_fast_i[7] / mip.MEIP bit 7):
void conv1d_isr(void) {
    // Read output here — DONE is set
    DEV_WRITE(CONV1D_CTRL, 0);  // clear GO if held; DONE clears on next GO
}
```

### Same-Length Output (Zero-Pad Mode)

```c
int8_t  signal[16];
int32_t output[16];     // same length as input

DEV_WRITE(CONV1D_PADDING_MODE, 0x03);   // ZERO_PAD | SAME
DEV_WRITE(CONV1D_LENGTH, 16);
// ... load kernel, addresses, assert GO as above
```

## C Header Definitions

From `sw/include/opensoc_regs.h`:

```c
#define CONV1D_BASE          0x40090000

#define CONV1D_CTRL          (CONV1D_BASE + 0x00)
#define CONV1D_STATUS        (CONV1D_BASE + 0x04)
#define CONV1D_SRC_ADDR      (CONV1D_BASE + 0x08)
#define CONV1D_DST_ADDR      (CONV1D_BASE + 0x0C)
#define CONV1D_LENGTH        (CONV1D_BASE + 0x10)
#define CONV1D_IER           (CONV1D_BASE + 0x14)
#define CONV1D_KERNEL_SIZE   (CONV1D_BASE + 0x18)
#define CONV1D_PADDING_MODE  (CONV1D_BASE + 0x1C)
#define CONV1D_KERNEL_W(n)   (CONV1D_BASE + 0x20 + (n) * 4)

#define CONV1D_CTRL_GO           0x1
#define CONV1D_CTRL_SOFT_RESET   0x2
#define CONV1D_CTRL_STREAM_MODE  0x4

#define CONV1D_STATUS_BUSY       0x1
#define CONV1D_STATUS_DONE       0x2

#define CONV1D_IER_DONE          0x1

#define CONV1D_PAD_VALID         0x0
#define CONV1D_PAD_SAME          0x3

#define IRQ_CONV1D  7
```

## File Structure

```
hw/ip/conv1d/
├── conv1d.core              — FuseSoC core (opensoc:ip:conv1d)
└── rtl/
    ├── conv1d.sv            — Control registers + DMA FSM (top-level)
    ├── conv1d_pe.sv         — KERNEL_SIZE parallel INT8×INT8 multipliers + INT32 accumulator
    └── shift_reg.sv         — Parameterized shift register (DEPTH=KERNEL_SIZE, WIDTH=8)
```
