# Brainstorm: Vector MAC Accelerator

**Date:** 2026-03-17
**Status:** Draft

## What We're Building

A parameterizable INT8 vector multiply-accumulate (MAC) accelerator for OpenSoC that computes dot products: `dot(A[N], B[N]) -> INT32`. It will:

- Accept two source vectors (A, B) and a destination address via control registers
- Use a single DMA master port (time-multiplexed reads of A and B) connected to the AXI crossbar via `axi_from_mem`
- Feed data through an **internal AXI-Stream pipeline** into a parallel MAC array with `NUM_LANES` configurable signed INT8 x INT8 multiply-accumulate lanes (default 4)
- Accumulate partial products into a **saturating INT32** accumulator
- Write the scalar result to the destination address on completion
- Fire an interrupt when done
- Expose **external AXI-Stream ports** for future direct streaming from other IP

The compute model starts as a **single dot product** but the register set and FSM will be architected so that matrix-vector multiply is a natural extension later.

DMA starts as **single-beat transfers** (like the ReLU accelerator), with AXI4 burst support planned as a follow-up upgrade.

## Why This Approach

**Approach A (extended single-DMA)** was chosen over dual-DMA masters or CPU-fed AXIS because:

1. **Follows established patterns.** The ReLU accelerator proved the OBI-like → `axi_from_mem` → crossbar path works. Extending that FSM to dual-read is an incremental step, not a rewrite.

2. **Minimal crossbar impact.** A single new master port takes NumMasters from 3→4. `$clog2(4) = 2`, so `AxiIdWidthOut` stays at 3 bits — zero ripple effects on existing modules.

3. **Debuggable.** Time-multiplexing A/B reads through one port means one set of bus signals to trace in waveforms. Dual-DMA doubles the debug surface.

4. **Bandwidth is adequate for learning.** At 32-bit single-beat, feeding 4 INT8 lanes needs 1 bus word per operand per cycle. The time-multiplexed penalty (2 reads per MAC step) is real but acceptable. Burst DMA upgrade later recovers most of this.

5. **External AXIS ports future-proof the design.** The MAC compute block has clean AXIS interfaces internally, so a future DMA-to-AXIS bridge or inter-accelerator streaming can plug in without redesigning the datapath.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Goal | Learning + practical | Architect for growth, start simple |
| AXI-Stream boundary | External AXIS ports exposed | More realistic, enables future streaming |
| MAC lanes | Parameterizable (default 4) | Maximizes reusability across configs |
| DMA strategy | Single-beat first, burst later | Reduce risk — debug MAC datapath first |
| Compute model | Single dot product first | Architect for matrix-vector extension |
| Accumulator | Saturating INT32 | Prevents silent overflow, matches bus width |
| Crossbar integration | Single DMA master, single ctrl slave | Follows ReLU pattern, minimal crossbar changes |
| Approach | A: Extended single-DMA | Pragmatic, debuggable, follows conventions |
| Lane constraint | NUM_LANES <= AXI_DATA_WIDTH/8 for now | Compile-time assert; revisit with burst DMA |
| AXIS direction | Bidirectional | Enables accelerator chaining (MAC -> activation) |
| Accum reset | Clear on GO + auto-clear mode bit | CTRL bit disables auto-clear for multi-kick accumulation |

## Architecture Sketch

```
                     AXI Crossbar
                          |
               +----------+----------+
               |                     |
          axi_from_mem          axi_to_mem
          (DMA master)          (ctrl slave)
               |                     |
               v                     v
     +-------------------+    +-----------+
     |  DMA Read/Write   |    | Control   |
     |  Engine (FSM)     |    | Registers |
     +-------------------+    +-----------+
               |                     |
               |    Main loop (LEN iterations):
               |      RD_A_REQ -> RD_A_WAIT
               |      RD_B_REQ -> RD_B_WAIT -> ACCUMULATE
               |    Then once:
               |      WR_REQ -> WR_WAIT -> IDLE
               v
     +-------------------+
     | stream_fifo (A)   |     ext_axis_a_in ──> (bypass DMA)
     | stream_fifo (B)   |     ext_axis_b_in ──>
     +--------+----------+
              |
              v
     +----------------------------+
     | MAC Array                  |
     | NUM_LANES x (INT8 * INT8)  |
     | signed multiply            |
     | -> saturating INT32 accum  |
     +-------------+--------------+
                   |
                   v
              RESULT reg ──> ext_axis_result_out
```

**Constraints:**
- All INT8 values are **signed** (two's complement). Multiplies are signed x signed.
- Vectors A and B must be the same length (LEN words each).
- Source and destination addresses must be **word-aligned** (4-byte boundary).

## Control Registers (at 0x80000)

| Offset | Name       | Access | Description |
|--------|------------|--------|-------------|
| 0x00   | SRC_A_ADDR | R/W    | Vector A source address |
| 0x04   | SRC_B_ADDR | R/W    | Vector B source address |
| 0x08   | DST_ADDR   | R/W    | Result destination address |
| 0x0C   | LEN        | R/W    | Number of INT8 elements per vector (must be a multiple of NUM_LANES) |
| 0x10   | CTRL       | W      | Bit[0] GO, Bit[1] NO_ACCUM_CLEAR (skip auto-clear on GO) |
| 0x14   | STATUS     | R      | Bit[0] BUSY, Bit[1] DONE |
| 0x18   | IER        | R/W    | Bit[0] Done interrupt enable |
| 0x1C   | RESULT     | R      | Direct read of accumulator value |

## Integration Points

- **Crossbar**: NumMasters 3→4, NumSlaves 7→8, new address rule at 0x80000
- **IRQ**: `irq_fast_i[4]`
- **IP folder**: `hw/ip/vec_mac/` with `vec_mac.core`
- **FuseSoC**: `opensoc:ip:vec_mac`, new `--cores-root=hw/ip/vec_mac`
- **common_cells**: Use `stream_fifo` for internal AXIS FIFOs

## Resolved Questions

1. **NUM_LANES vs bus width mismatch**: Constrain NUM_LANES <= AXI_DATA_WIDTH/8 with a compile-time assert. Default 4 lanes at 32-bit bus is a perfect fit (1 word = 4 INT8). Revisit when burst DMA is added.

2. **External AXIS port direction**: Bidirectional. AXIS slave ports for input (bypass DMA) and AXIS master port for streaming results out. Enables future accelerator chaining (e.g., MAC -> ReLU activation -> next layer).

3. **Accumulator reset between dot products**: Clear on GO by default, with a CTRL[1] `NO_ACCUM_CLEAR` bit to disable auto-clear. This enables multi-kick accumulation for future matrix-vector mode without a register redesign.

## Open Questions

None — all design questions resolved.
