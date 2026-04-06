# OpenSoC GEMM Systolic Array

## Overview

The GEMM accelerator computes the general matrix multiply:

```
C[M × N] = A[M × K] × B[K × N]
```

where A and B contain INT8 elements and C contains INT32 elements. It implements a weight-stationary 8×8 systolic array: the B matrix is preloaded into the PE registers once via CSRs, then each row of A is streamed through a skew network to produce one row of C.

- **Weight-stationary** — B[k][n] is held in PE[k][n]'s weight register across all M output rows; only A rows need to be re-read per row of C
- **Data skew** — a chain of flip-flop delays ensures that each row of the array sees its correct A element simultaneously at the MAC enable pulse
- **INT8 inputs, INT32 outputs** — each PE accumulates one signed 32-bit partial sum; the result drain sums across all K rows to form C[m][n]
- **Matrix dimensions** — M, K, N configurable from 1 to 8 at runtime; unused PE rows/columns naturally contribute zero
- **DMA master port** — reads A from `SRC_ADDR` (one INT8 per 32-bit word, row-major) and writes C to `DST_ADDR` (INT32, row-major) via the AXI crossbar

Base address: `0x400C0000` (1 kB window). IRQ: `irq_fast_i[9]`.

## Architecture

```
gemm.sv (control registers + DMA FSM)
├── data_skew.sv       — 8-stage explicit flip-flop delay chain
├── systolic_array.sv  — 8×8 generate-based grid of pe_cell instances
├── pe_cell.sv         — INT8 weight register + INT32 accumulator (one MAC)
└── result_drain.sv    — combinational column-sum across all 8 PE rows
```

### SoC Integration

- **Slave port**: crossbar slave index `GemmSlvIdx` (last optional slave), address `0x400C0000`
- **Master port**: crossbar master index `GemmDmaMstIdx` (before PIO DMA), via `axi_from_mem` bridge
- **IRQ**: `irq_fast_i[9]`, level-sensitive (`done & ier`)

## Compute Core

### pe_cell.sv

Each PE holds one INT8 weight register (`w_q`) and one INT32 accumulator (`acc_q`). On a MAC enable pulse (`en_i`), the PE computes `acc_q += a_in_i * w_q`. The weight is loaded independently via `set_w_i` / `w_i`; the accumulator is cleared synchronously via `clr_i`.

```
     set_w_i, w_i
          │
    ┌─────▼─────┐
    │   w_q     │  (INT8 weight register)
    └─────┬─────┘
          │
a_in_i ──►│  MAC (en_i)
          │
    ┌─────▼─────┐
    │   acc_q   │  (INT32 accumulator)
    └─────┬─────┘
          │
       acc_o
```

A pass-through register (`a_out_q`) propagates `a_in_i` eastward to the next PE in the same row, though the current implementation broadcasts each `skew_out[k]` to all N columns in row k rather than using east-flow propagation.

### data_skew.sv

A chain of 7 explicit flip-flop stages introduces a per-row delay: row 0 sees the input directly, row 1 sees it one cycle later, …, row 7 sees it seven cycles later. This ensures that when the MAC enable fires at the end of the 8-cycle SKEW_FEED phase, each row k has the correct A element (`A[m][k]`) at its input.

```
cycle:    0     1     2     3     4     5     6     7 (en)
         ─────────────────────────────────────────────────
row 0    a[7]  a[6]  a[5]  a[4]  a[3]  a[2]  a[1]  a[0] ✓
row 1     0    a[7]  a[6]  a[5]  a[4]  a[3]  a[2]  a[1] ✓
row 2     0     0    a[7]  a[6]  a[5]  a[4]  a[3]  a[2] ✓
  ⋮
row 7     0     0     0     0     0     0     0    a[7] ✓
```

The reversed-order feed (`a[7-k]` at cycle k, where unused indices are zero-extended) is what aligns each row's data with the enable pulse.

### systolic_array.sv

An 8×8 `generate` loop instantiates 64 `pe_cell` modules. For PE[k][n]:

- `set_w_i` fires when `weight_addr_q == (k << 3) | n`
- `a_in_i` comes from `skew_out[k]` (broadcast to all columns in row k)
- `clr_i` and `en_i` are global signals from the FSM

### result_drain.sv

A purely combinational tree of adders. For each output column n:

```
C[m][n] = acc[0][n] + acc[1][n] + ... + acc[7][n]
```

The 8-input sum is implemented as a chain: `s0 = acc[0]+acc[1]`, `s1 = s0+acc[2]`, …, `s6 = s5+acc[7]`. When MAT_K < 8, unused rows have been cleared and contribute zero.

## FSM

The accelerator uses a 7-state FSM. The outer loop iterates over M output rows; for each row it clears the accumulators, reads K elements of A via DMA, runs the 8-cycle skew-feed, then writes N output elements via DMA.

```
              GO
IDLE ─────────────────► COMPUTE_CLR
                              │
                         assert sa_clr
                         reset k, n
                              │
                              ▼
                           RD_REQ ◄────────────────────────┐
                              │                            │
                        assert dma_req                     │
                              │                            │
                            gnt                            │
                              │                            │
                              ▼                            │
                           RD_WAIT                         │
                              │                            │
                           rvalid                          │
                              │                            │
                    store a_row_buf[k]                     │
                              │                            │
                     k == K-1? ─── no: k++ ───────────────┘
                              │ yes: k=0
                              ▼
                          SKEW_FEED ◄──────────────────────┐
                              │                            │
                  feed a_row_buf[7-k] to skew              │
                     advance k                             │
                              │                            │
                     k == 7? ─── no ──────────────────────┘
                     (en fires)
                              │ yes: k=0
                              ▼
                           WR_REQ ◄────────────────────────┐
                              │                            │
                        assert dma_req                     │
                        write drain[n]                     │
                              │                            │
                            gnt                            │
                              │                            │
                              ▼                            │
                           WR_WAIT                         │
                              │                            │
                           rvalid                          │
                              │                            │
                     n == N-1? ─── no: n++ ───────────────┘
                              │ yes: n=0
                              │
                     m == M-1? ─── no: m++, ──► COMPUTE_CLR
                              │ yes
                              ▼
                          IDLE (DONE)
```

**Weight preload:** before asserting GO, software writes each B[k][n] element by setting `WEIGHT_ADDR = (k << 3) | n` then writing `WEIGHT_DATA`. This fires `set_w_i` on the matching PE immediately. Weights persist across GO pulses; only a SOFT_RESET or a new weight write changes them.

**Skew reversed-order feed:** at SKEW_FEED cycle k (k = 0..7), the FSM feeds `a_row_buf[7-k]` if `7-k < MAT_K`, else 0. Row j (with j flip-flop delays) therefore sees `a_row_buf[7-k+j]`; at the en pulse (k=7), row j sees `a_row_buf[j]` = A[m][j]. ✓

**Result drain:** after the 8th skew cycle, `drain_result[n]` = Σ_k acc[k][n] = Σ_k A[m][k] × B[k][n] = C[m][n].

## Register Map

Base address: `0x400C0000`.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x00 | CTRL | W | [0] GO, [1] SOFT_RESET |
| 0x04 | STATUS | R | [0] BUSY, [1] DONE |
| 0x08 | SRC_ADDR | R/W | A matrix base address (word-aligned) |
| 0x0C | DST_ADDR | R/W | C matrix base address (word-aligned) |
| 0x10 | (reserved) | — | — |
| 0x14 | IER | R/W | [0] IRQ enable on completion |
| 0x18 | MAT_M | R/W | Number of A rows / C rows (1–8) |
| 0x1C | MAT_K | R/W | Number of A cols = B rows (1–8) |
| 0x20 | MAT_N | R/W | Number of B cols / C cols (1–8) |
| 0x24 | WEIGHT_ADDR | R/W | PE select: bits [5:3] = row k, bits [2:0] = col n |
| 0x28 | WEIGHT_DATA | R/W | INT8 weight value for PE[k][n]; write triggers load |
| 0x2C | ARRAY_SIZE | R | [15:8] = ARRAY_M (8), [7:0] = ARRAY_N (8) |

### CTRL Register (0x00)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | GO | Start computation. Ignored if BUSY. |
| 1 | SOFT_RESET | Clears BUSY and DONE, returns FSM to IDLE. Does not clear PE weights. |

### STATUS Register (0x04)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | BUSY | Set from GO until the last C element is written. |
| 1 | DONE | Set when computation completes. Cleared by next GO or SOFT_RESET. |

### WEIGHT_ADDR / WEIGHT_DATA (0x24, 0x28)

Write `WEIGHT_ADDR` first to select a PE, then write `WEIGHT_DATA` to load the weight. The PE address encodes the B matrix position: `addr = (k << 3) | n` for B[k][n]. Bits [5:3] select the row (k = 0–7) and bits [2:0] select the column (n = 0–7). The write takes effect immediately; no GO is required.

```c
// Load B[k][n] = value
DEV_WRITE(GEMM_WEIGHT_ADDR, (k << 3) | n);
DEV_WRITE(GEMM_WEIGHT_DATA, (uint32_t)(int32_t)value);
```

### ARRAY_SIZE Register (0x2C)

Read-only. Returns `0x00000808` (ARRAY_M=8 in bits [15:8], ARRAY_N=8 in bits [7:0]). Useful for software to query the physical array dimensions at runtime.

### Element Packing

**A matrix (input):** stored row-major as INT8 values, one per 32-bit word (hardware uses bits [7:0] only). Element A[m][k] is at `SRC_ADDR + (m * MAT_K + k) * 4`.

**C matrix (output):** stored row-major as INT32 words. Element C[m][n] is at `DST_ADDR + (m * MAT_N + n) * 4`.

Source and destination buffers must be word-aligned.

## Interrupt

```
irq_o = done & ier
```

Level-sensitive. DONE persists until the next GO or SOFT_RESET.

## Programming Guide

### 4×4 Matrix Multiply (Polling)

```c
// A (4×4 INT8), one element per word
int32_t a[4*4] = { 1, 2, 3, 4,
                   5, 6, 7, 8,
                   9,10,11,12,
                  13,14,15,16 };
int32_t c[4*4];   // INT32 output

int8_t b[4*4] = { 17,18,19,20,
                  21,22,23,24,
                  25,26,27,28,
                  29,30,31,32 };

// 1. Preload B into PE weight registers
for (int k = 0; k < 4; k++) {
    for (int n = 0; n < 4; n++) {
        DEV_WRITE(GEMM_WEIGHT_ADDR, (k << 3) | n);
        DEV_WRITE(GEMM_WEIGHT_DATA, (uint32_t)(int32_t)b[k * 4 + n]);
    }
}

// 2. Configure matrix dimensions
DEV_WRITE(GEMM_MAT_M, 4);
DEV_WRITE(GEMM_MAT_K, 4);
DEV_WRITE(GEMM_MAT_N, 4);

// 3. Set source and destination addresses
DEV_WRITE(GEMM_SRC_ADDR, (uint32_t)a);
DEV_WRITE(GEMM_DST_ADDR, (uint32_t)c);

// 4. Launch and poll
DEV_WRITE(GEMM_CTRL, GEMM_CTRL_GO);
while (!(DEV_READ(GEMM_STATUS, 0) & GEMM_STATUS_DONE))
    ;
// c[m*4+n] now holds C[m][n]
```

### 8×8 Full-Array Multiply

Use the same pattern with `MAT_M = MAT_K = MAT_N = 8`. No special handling is needed — the full 8×8 PE grid is exercised and all 64 result columns are drained.

### Reusing B Across Multiple A Matrices

Weights persist across GO pulses. If B is fixed (e.g. a neural network weight matrix), load it once and call GO for each new A:

```c
// Load B once
for (int k = 0; k < K; k++)
    for (int n = 0; n < N; n++) {
        DEV_WRITE(GEMM_WEIGHT_ADDR, (k << 3) | n);
        DEV_WRITE(GEMM_WEIGHT_DATA, (uint32_t)(int32_t)b[k*N+n]);
    }

// Run multiple A inputs
for (int batch = 0; batch < NUM_BATCHES; batch++) {
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
    DEV_WRITE(GEMM_SRC_ADDR, (uint32_t)a[batch]);
    DEV_WRITE(GEMM_DST_ADDR, (uint32_t)c[batch]);
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_GO);
    while (!(DEV_READ(GEMM_STATUS, 0) & GEMM_STATUS_DONE))
        ;
}
```

### IRQ-Driven Completion

```c
DEV_WRITE(GEMM_IER,  GEMM_IER_DONE);
DEV_WRITE(GEMM_CTRL, GEMM_CTRL_GO);

// In ISR (irq_fast_i[9]):
void gemm_isr(void) {
    // C is ready — process results
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);  // clear DONE
}
```

## C Header Definitions

From `sw/include/opensoc_regs.h`:

```c
#define GEMM_BASE         0x400C0000UL

#define GEMM_CTRL         (GEMM_BASE + 0x00)
#define GEMM_STATUS       (GEMM_BASE + 0x04)
#define GEMM_SRC_ADDR     (GEMM_BASE + 0x08)
#define GEMM_DST_ADDR     (GEMM_BASE + 0x0C)
#define GEMM_IER          (GEMM_BASE + 0x14)
#define GEMM_MAT_M        (GEMM_BASE + 0x18)
#define GEMM_MAT_K        (GEMM_BASE + 0x1C)
#define GEMM_MAT_N        (GEMM_BASE + 0x20)
#define GEMM_WEIGHT_ADDR  (GEMM_BASE + 0x24)
#define GEMM_WEIGHT_DATA  (GEMM_BASE + 0x28)
#define GEMM_ARRAY_SIZE   (GEMM_BASE + 0x2C)

#define GEMM_CTRL_GO          0x1
#define GEMM_CTRL_SOFT_RESET  0x2

#define GEMM_STATUS_BUSY  0x1
#define GEMM_STATUS_DONE  0x2

#define GEMM_IER_DONE     0x1

#define IRQ_GEMM  9
```

## File Structure

```
hw/ip/gemm/
├── gemm.core              — FuseSoC core (opensoc:ip:gemm)
└── rtl/
    ├── gemm.sv            — Control registers + DMA FSM (top-level)
    ├── data_skew.sv       — 8-stage explicit flip-flop delay chain
    ├── systolic_array.sv  — 8×8 generate-based grid of pe_cell instances
    ├── pe_cell.sv         — INT8 weight register + INT32 accumulator (one MAC)
    └── result_drain.sv    — Combinational column-sum: C[m][n] = Σ_k acc[k][n]
```
