---
title: "feat: Add INT8 Vector MAC Accelerator with DMA"
type: feat
status: completed
date: 2026-03-17
origin: docs/brainstorms/2026-03-17-vector-mac-accelerator-brainstorm.md
---

# feat: Add INT8 Vector MAC Accelerator with DMA

## Overview

Add a parameterizable INT8 vector multiply-accumulate (MAC) accelerator to OpenSoC that computes dot products: `dot(A[N], B[N]) -> saturating INT32`. Uses the same DMA integration pattern as the ReLU accelerator (single OBI-like master port through `axi_from_mem` into the AXI crossbar), with an extended dual-read FSM to fetch two input vectors.

This is Week 3-4 of the Phase 1 learning arc, building on the AXI plumbing learned from the ReLU accelerator (see brainstorm: `docs/brainstorms/2026-03-17-vector-mac-accelerator-brainstorm.md`).

## Problem Statement / Motivation

The ReLU accelerator demonstrated infrastructure plumbing (AXI buses, DMA, interrupts) but has trivial compute (one combinational line). The Vector MAC introduces real compute: a parallel pipelined INT8 MAC array that produces a measurable throughput number. It is also the fundamental building block for neural network inference (each dense layer neuron = one dot product).

## Proposed Solution

A new IP block at `hw/ip/vec_mac/` following the ReLU accelerator's established patterns:

- **Control slave port** (via `axi_to_mem`): 8 registers for configuration, control, status, and result
- **DMA master port** (via `axi_from_mem`): time-multiplexed reads of vector A and B, single write of scalar result
- **MAC compute array**: `NUM_LANES` (default 4) parallel signed INT8 x INT8 multipliers feeding a saturating INT32 accumulator
- **Interrupt** on `irq_fast_i[4]` when done

## Technical Approach

### Architecture

```
                     AXI Crossbar (4 masters x 8 slaves)
                          |
               +----------+----------+
               |                     |
          axi_from_mem          axi_to_mem
          (DMA master)          (ctrl slave)
          xbar_slv[3]          mem_*[7]
               |                     |
               v                     v
     +-------------------+    +-----------+
     | vec_mac            |    | Control   |
     | DMA FSM + regs     |    | Registers |
     +-------------------+    +-----------+
               |                     |
          a_data_q / b_data_q   config, status,
               |                result readback
               v
     +----------------------------+
     | vec_mac_core               |
     | NUM_LANES x signed INT8*INT8|
     | -> partial sum -> sat INT32 |
     +----------------------------+
              |
              v
         RESULT register
```

DMA read data is latched directly into registers (`a_data_q` on RD_A_WAIT, `b_data_q` on RD_B_WAIT) and fed to the MAC core — no FIFOs needed for single-beat DMA. When burst DMA is added later, `stream_fifo` from common_cells can be inserted between the DMA engine and MAC core.

**Module hierarchy:**

| Module | File | Purpose |
|--------|------|---------|
| `vec_mac` | `rtl/vec_mac.sv` | Top wrapper: control regs + DMA engine + MAC core |
| `vec_mac_core` | `rtl/vec_mac_core.sv` | Pure compute: NUM_LANES multipliers + saturating accumulator |

The design intentionally uses **two files** (not three) to keep it simple. The DMA FSM and control registers live together in `vec_mac.sv` since the FSM is tightly coupled to register state (unlike the ReLU's reusable `dma_accel_core`, which was designed for 1:1 read-write patterns that don't apply here).

### Data Format

- **INT8 packing** (little-endian, matching RISC-V): `word[7:0]` = lane 0, `word[15:8]` = lane 1, `word[23:16]` = lane 2, `word[31:24]` = lane 3
- **Signed range**: each INT8 in [-128, +127]
- **Product range** per lane: [-128 * 127, -128 * -128] = [-16256, +16384] (fits INT16, max 32767)
- **Partial sum** of NUM_LANES=4 products per step: max +/-65024 (fits INT17)
- **Accumulator**: 33-bit internal (sign + 32 data bits), saturated to [INT32_MIN, INT32_MAX] after each step
- **LEN register**: counts INT8 elements. Hardware computes `num_words = LEN >> $clog2(NUM_LANES)`. LEN must be a multiple of NUM_LANES; low bits are masked off (truncated to nearest lower multiple)

### Control Registers (at 0x80000, 1 kB window)

| Offset | Name       | Access | Reset | Description |
|--------|------------|--------|-------|-------------|
| 0x00   | SRC_A_ADDR | R/W    | 0     | Vector A source address (word-aligned) |
| 0x04   | SRC_B_ADDR | R/W    | 0     | Vector B source address (word-aligned) |
| 0x08   | DST_ADDR   | R/W    | 0     | Result destination address (word-aligned) |
| 0x0C   | LEN        | R/W    | 0     | Number of INT8 elements per vector (multiple of NUM_LANES) |
| 0x10   | CTRL       | W      | —     | Bit[0] GO, Bit[1] NO_ACCUM_CLEAR. Sampled on GO only (transient) |
| 0x14   | STATUS     | R      | 0x00  | Bit[0] BUSY, Bit[1] DONE |
| 0x18   | IER        | R/W    | 0     | Bit[0] Done interrupt enable |
| 0x1C   | RESULT     | R      | 0     | Accumulator value (live during operation, final when DONE) |

### Hardware Invariants

These match the ReLU accelerator's established behavior (see brainstorm):

- **GO while BUSY**: silently ignored (`go = ctrl_req_i & ctrl_we_i & ... & ~busy_q`)
- **Config register latching**: SRC_A_ADDR, SRC_B_ADDR, DST_ADDR, LEN are latched into working registers (`cur_src_a_q`, `cur_src_b_q`, `cur_dst_q`, `remaining_q`) on GO. Writes during BUSY prepare the next operation
- **DONE clearing**: DONE is cleared when the next GO fires
- **Bus errors**: `dma_err_i` is ignored (same as ReLU — no error reporting)
- **LEN=0**: With NO_ACCUM_CLEAR=0, clears accumulator to 0 and sets DONE immediately. With NO_ACCUM_CLEAR=1, sets DONE immediately (accumulator unchanged)
- **NO_ACCUM_CLEAR**: transient, sampled only when GO is written. Not readable. CTRL reads return 0
- **RESULT while BUSY**: returns the live (intermediate) accumulator value. Unstable during operation but useful for debug
- **Interrupt**: `irq_o = done_q & ier_done_q` (level-sensitive). ISR pattern: clear IER -> read RESULT -> process -> re-enable IER when ready

### DMA FSM

```
IDLE ──(GO && LEN>0)──> RD_A_REQ
                         │
                    (dma_gnt_i)
                         │
                         v
                    RD_A_WAIT
                         │
                    (dma_rvalid_i) ── latch A word into fifo_a
                         │
                         v
                    RD_B_REQ
                         │
                    (dma_gnt_i)
                         │
                         v
                    RD_B_WAIT
                         │
                    (dma_rvalid_i) ── latch B word, trigger MAC, accumulate
                         │
                    remaining_q - 1
                         │
              ┌──────────┴──────────┐
              │                     │
         (remaining > 0)      (remaining == 0)
              │                     │
              v                     v
         RD_A_REQ              WR_REQ
                                    │
                               (dma_gnt_i)
                                    │
                                    v
                               WR_WAIT
                                    │
                               (dma_rvalid_i)
                                    │
                                    v
                                  IDLE (busy=0, done=1)
```

**7 states**: IDLE, RD_A_REQ, RD_A_WAIT, RD_B_REQ, RD_B_WAIT, WR_REQ, WR_WAIT

Each iteration reads one word of A (4 INT8 values), one word of B (4 INT8 values), computes 4 parallel multiplies, sums the products, and adds to the accumulator with saturation. After LEN/NUM_LANES iterations, writes the 32-bit result to DST_ADDR.

### MAC Compute (vec_mac_core)

```systemverilog
// vec_mac_core.sv — pure combinational + accumulator
module vec_mac_core #(
  parameter int unsigned NUM_LANES = 4
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        clear_i,      // clear accumulator
  input  logic        valid_i,      // new A/B data valid
  input  logic [31:0] a_data_i,     // packed INT8 x NUM_LANES
  input  logic [31:0] b_data_i,     // packed INT8 x NUM_LANES
  output logic [31:0] result_o,     // saturated INT32 accumulator
);
```

**Internal logic:**
1. Unpack: `a[i] = signed'(a_data_i[8*i +: 8])` for each lane
2. Multiply: `prod[i] = a[i] * b[i]` (signed 8x8 -> 16-bit result)
3. Sum partial products: `partial_sum = prod[0] + prod[1] + ... + prod[NUM_LANES-1]` (17-bit for 4 lanes)
4. Accumulate with saturation: `accum_next = sat32(accum_q + partial_sum)` using 33-bit intermediate
5. Saturation: if `accum_next > INT32_MAX`, clamp to `INT32_MAX`. If `accum_next < INT32_MIN`, clamp to `INT32_MIN`

### Compile-Time Assertions

```systemverilog
initial begin
  assert (NUM_LANES <= AxiDataWidth / 8)
    else $fatal("NUM_LANES (%0d) exceeds bus width capacity (%0d)", NUM_LANES, AxiDataWidth / 8);
  assert (NUM_LANES > 0 && (NUM_LANES & (NUM_LANES - 1)) == 0)
    else $fatal("NUM_LANES must be a power of 2");
end
```

### Implementation Phases

#### Phase 1: MAC Compute Core (`vec_mac_core.sv`)

**Files:** `hw/ip/vec_mac/rtl/vec_mac_core.sv`

- [x] Create `vec_mac_core` module with parameterized NUM_LANES
- [x] Implement INT8 unpacking (little-endian lane assignment)
- [x] Implement NUM_LANES signed 8x8 multipliers
- [x] Implement partial product summation tree
- [x] Implement 33-bit accumulator with saturation to INT32
- [x] Implement `clear_i` to reset accumulator
- [x] Wire `result_o` from saturated 32-bit output
- [x] Add compile-time assertions for NUM_LANES constraints

**Success criteria:** Module compiles cleanly with Verilator lint. Saturation logic correct for edge cases.

#### Phase 2: DMA Engine + Control Registers (`vec_mac.sv`)

**Files:** `hw/ip/vec_mac/rtl/vec_mac.sv`

- [x] Create `vec_mac` top-level module with ctrl/dma/irq port groups (matching ReLU pattern: `hw/ip/relu_accel/rtl/relu_accel.sv:15-41`)
- [x] Implement 8 control registers (SRC_A_ADDR through RESULT) with read/write paths
- [x] Implement register latching on GO (copy to working registers)
- [x] Implement GO logic: `go = ctrl_req_i & ctrl_we_i & (addr == REG_CTRL) & wdata[0] & ~busy_q`
- [x] Implement 7-state DMA FSM (IDLE through WR_WAIT)
- [x] Implement LEN -> num_words conversion: `remaining = len_q >> $clog2(NUM_LANES)`
- [x] Implement address increment: `cur_src_a += 4`, `cur_src_b += 4` per iteration
- [x] Instantiate `vec_mac_core`, wire A/B data from DMA reads, connect accumulator
- [x] Implement NO_ACCUM_CLEAR logic (sample CTRL[1] on GO, conditionally clear)
- [x] Implement LEN=0 edge case (immediate DONE)
- [x] Wire `irq_o = done_q & ier_done_q`
- [x] Latch DMA read data into `a_data_q` (on RD_A_WAIT + rvalid) and `b_data_q` (on RD_B_WAIT + rvalid), wire directly to `vec_mac_core`

**Success criteria:** Module compiles cleanly with Verilator lint.

#### Phase 3: FuseSoC Integration

**Files to create:**
- [x] `hw/ip/vec_mac/vec_mac.core` — FuseSoC core file (follow `hw/ip/relu_accel/relu_accel.core` format)
  - Name: `opensoc:ip:vec_mac`
  - Fileset: `rtl/vec_mac_core.sv`, `rtl/vec_mac.sv` (dependency order)

**Files to modify:**
- [x] `hw/opensoc_top.core` — add `"opensoc:ip:vec_mac"` to `depend:` list (after `relu_accel`, line 13 area)

**Success criteria:** `fusesoc core-info opensoc:soc:opensoc_top` resolves the new dependency.

#### Phase 4: Top-Level Integration (`opensoc_top.sv`)

**File:** `hw/rtl/opensoc_top.sv`

All changes follow the exact ReLU integration pattern (see research: lines 97-101, 130-133, 151-159, 407-442, 513-519, 652-675, 315):

- [x] Add `logic vmac_irq;` signal declaration (after `relu_irq`, ~line 101)
- [x] Bump crossbar constants: `NumMasters = 4`, `NumSlaves = 8`, `NumRules = 8` (~lines 130-132)
  - Note: `$clog2(4) = 2` so `AxiIdWidthOut` stays at 3 — no ripple effects
- [x] Add address map entry: `'{ idx: 32'd7, start_addr: 32'h0008_0000, end_addr: 32'h0008_0400 }` (~line 159)
- [x] Declare DMA intermediate signals: `vmac_dma_req`, `vmac_dma_addr`, etc. (after ReLU DMA signals, ~line 415)
- [x] Instantiate `axi_from_mem` for MAC DMA, connecting to `xbar_slv_req[3]` / `xbar_slv_resp[3]` (after ReLU bridge, ~line 442)
- [x] Add `assign mem_gnt[7] = mem_req[7];` (after line 519)
- [x] Instantiate `vec_mac` using `mem_*[7]` for ctrl, `vmac_dma_*` for DMA (~after line 675)
- [x] Update IRQ concatenation: `{10'b0, vmac_irq, relu_irq, i2c_irq, gpio_irq, uart_irq}` (~line 315)

**Success criteria:** `make lint` passes.

#### Phase 5: Lint Waivers + Build System

**Files to modify:**
- [x] `hw/lint/verilator_waiver.vlt` — add UNUSEDSIGNAL waivers for `vec_mac.sv` and `vec_mac_core.sv`
- [x] `Makefile` — add `--cores-root=hw/ip/vec_mac` to `CORES_ROOT` (~line 8)
- [x] `Makefile` — add `sw-vmac` and `run-vmac` targets (follow ReLU pattern, ~lines 107-117)

**Success criteria:** `make lint` passes cleanly.

#### Phase 6: Test Software

**Files to create:**
- [x] `sw/tests/vmac_test/Makefile` — 3-line Makefile (follow `sw/tests/relu_test/Makefile`)
- [x] `sw/tests/vmac_test/vmac_test.c` — test program

**Test cases** (following `sw/tests/relu_test/relu_test.c` patterns):

| # | Test | Input | Expected |
|---|------|-------|----------|
| 1 | Basic correctness | A=[1,2,3,4], B=[5,6,7,8] | 1*5+2*6+3*7+4*8 = 70 |
| 2 | Negative values | A=[-1,-2,3,4], B=[5,6,-7,8] | -5-12-21+32 = -6 |
| 3 | Zero vector | A=[0,0,0,0], B=[1,2,3,4] | 0 |
| 4 | Self dot product | src_a == src_b, A=[1,2,3,4] | 1+4+9+16 = 30 |
| 5 | Longer vector (32 elems) | Known pattern | Precomputed expected |
| 6 | Positive saturation | A=B=[127,...] x many | Clamp to INT32_MAX |
| 7 | Negative saturation | A=[127,...], B=[-128,...] x many | Clamp to INT32_MIN |
| 8 | LEN=0 | Any addresses | DONE=1, RESULT=0 |
| 9 | Multi-kick (NO_ACCUM_CLEAR) | Two segments | Sum of both dot products |
| 10 | Register readback | Write/read all R/W regs | Values match |
| 11 | DMA write-back | Check DST_ADDR in memory | Matches RESULT |
| 12 | Throughput measurement | Long vector | Report cycles/element |

**Test software API:**
```c
#define VMAC_BASE       0x80000
#define VMAC_SRC_A_ADDR (VMAC_BASE + 0x00)
#define VMAC_SRC_B_ADDR (VMAC_BASE + 0x04)
#define VMAC_DST_ADDR   (VMAC_BASE + 0x08)
#define VMAC_LEN        (VMAC_BASE + 0x0C)
#define VMAC_CTRL       (VMAC_BASE + 0x10)
#define VMAC_STATUS     (VMAC_BASE + 0x14)
#define VMAC_IER        (VMAC_BASE + 0x18)
#define VMAC_RESULT     (VMAC_BASE + 0x1C)

#define VMAC_CTRL_GO             0x1
#define VMAC_CTRL_NO_ACCUM_CLEAR 0x2
#define VMAC_STATUS_BUSY         0x1
#define VMAC_STATUS_DONE         0x2
```

**Expected result calculation:** use `int64_t` accumulator in C, clamp to `[INT32_MIN, INT32_MAX]` to match hardware saturation.

**Success criteria:** `make run-vmac` passes all tests, reports throughput in cycles/element.

## Alternative Approaches Considered

(See brainstorm: `docs/brainstorms/2026-03-17-vector-mac-accelerator-brainstorm.md`)

| Approach | Why Rejected |
|----------|-------------|
| **B: Dual DMA masters** | NumMasters 3→5, doubles debug surface, overkill for learning |
| **C: CPU-fed AXI-Stream** | CPU bottleneck, requires separate DMA-to-AXIS bridge |
| **Hybrid A+C** | More modules than needed for initial implementation |

## System-Wide Impact

- **Crossbar**: NumMasters 3→4, NumSlaves 7→8, NumRules 7→8. AxiIdWidthOut unchanged (stays 3). Connectivity `'1` (all-to-all) unchanged
- **IRQ**: One new fast interrupt line (`irq_fast_i[4]`). No impact on existing IRQ assignments
- **Memory map**: New 1 kB region at 0x80000. No overlap with existing peripherals
- **Build**: One new `--cores-root`, one new FuseSoC dependency. No changes to existing IP
- **Simulation**: New `sw-vmac` / `run-vmac` targets. Existing targets unchanged

## Acceptance Criteria

### Functional Requirements

- [ ] `make lint` passes with vec_mac integrated
- [ ] Dot product of known INT8 vectors produces correct INT32 result
- [ ] Saturating accumulator clamps to INT32_MIN / INT32_MAX correctly
- [ ] NO_ACCUM_CLEAR preserves accumulator across consecutive GO operations
- [ ] LEN=0 produces immediate DONE with accumulator cleared (or preserved with NO_ACCUM_CLEAR)
- [ ] DMA writes scalar result to DST_ADDR on completion
- [ ] IRQ fires when done and IER is enabled
- [ ] NUM_LANES parameter works (at least default value of 4)
- [ ] Self-dot-product (src_a == src_b) works correctly

### Non-Functional Requirements

- [ ] Throughput reported in cycles/element by test software
- [ ] No new Verilator lint warnings (beyond waived UNUSEDSIGNAL)

### Quality Gates

- [ ] All 12 test cases pass in `make run-vmac`
- [ ] Register readback test confirms R/W register correctness

## Dependencies & Prerequisites

- **Existing infrastructure** (all in place): AXI crossbar, `axi_from_mem`/`axi_to_mem` bridges, ibex simple_system test framework
- **No new submodules or external IP required**
- **Prerequisite knowledge**: ReLU accelerator integration (completed in weeks 1-2)

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Signed multiply correctness | Medium | High | Explicit test cases for negative values, boundary values (-128 * -128, -128 * 127) |
| Saturation logic off-by-one | Medium | High | Use 33-bit internal accumulator; test both positive and negative saturation |
| DMA FSM complexity (7 states vs ReLU's 5) | Low | Medium | Follow ReLU FSM structure closely; dual-read is a straightforward extension |
| Verilator signed width warnings | Low | Low | common_cells stream_fifo deferred; direct register wiring avoids extra module integration |
| Verilator lint issues with signed arithmetic | Medium | Low | May need `/* verilator lint_off WIDTHTRUNC */` pragmas around saturation logic |

## Future Considerations

These are explicitly deferred (YAGNI) but the architecture accommodates them:

1. **External AXI-Stream ports** — add bidirectional AXIS ports when a concrete consumer/producer exists (see brainstorm resolved question 2)
2. **AXI4 burst DMA + stream_fifo** — add `stream_fifo` between DMA and MAC when burst reads produce multiple words in flight; FSM structure supports this upgrade without changing MAC core
3. **Matrix-vector multiply** — register set has DST_ADDR for output vector; FSM can loop over M dot products with auto-incrementing DST_ADDR
4. **Wider NUM_LANES** — parameterized, constrained to bus width for now; burst DMA enables wider configurations

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-17-vector-mac-accelerator-brainstorm.md](docs/brainstorms/2026-03-17-vector-mac-accelerator-brainstorm.md) — Key decisions carried forward: Approach A (single DMA), parameterizable NUM_LANES (default 4), saturating INT32 accumulator, LEN counts INT8 elements, bidirectional AXIS deferred to stubs

### Internal References

- ReLU accelerator (template): `hw/ip/relu_accel/rtl/relu_accel.sv`, `hw/ip/relu_accel/rtl/dma_accel_core.sv`
- Top-level integration pattern: `hw/rtl/opensoc_top.sv:407-675` (ReLU DMA + ctrl wiring)
- FuseSoC core template: `hw/ip/relu_accel/relu_accel.core`
- Test software template: `sw/tests/relu_test/relu_test.c`
- Lint waiver pattern: `hw/lint/verilator_waiver.vlt:40-41`
