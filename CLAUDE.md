# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenSoC is a RISC-V SoC built on the lowRISC **Ibex** CPU core. The top-level module (`opensoc_top`) uses an AXI4 crossbar (`axi_xbar` from PULP) to connect the Ibex CPU (instruction fetch + data port) to 1 MB SRAM, a simulation control module, and a timer.

## Build Commands

All builds use **FuseSoC** and must run under WSL/Linux (not native Windows).

**Always invoke make via WSL from the Windows shell:**

```bash
wsl bash -lc "cd /mnt/c/GitHub/opensoc && make lint"
wsl bash -lc "cd /mnt/c/GitHub/opensoc && make run-hello"
```

The login shell (`-lc`) is required so that PATH includes FuseSoC, Verilator, and the RISC-V toolchain.

```bash
# Verilator lint (the primary build target today)
make lint

# Equivalent manual command
fusesoc --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
  --cores-root=hw/ip/common_cells --cores-root=hw/ip/pulp_axi \
  run --target=lint opensoc:soc:opensoc_top
```

After cloning, initialize submodules: `git submodule update --init --recursive`

## Architecture

```
opensoc_top (hw/rtl/opensoc_top.sv)
├── ibex_top_tracing       — Ibex RISC-V core with trace output
├── axi_from_mem ×7        — OBI-to-AXI bridges (instr + data + ReLU/VMAC/SG DMA/Softmax/PIO DMA)
├── axi_xbar               — AXI4 crossbar (7 masters × 10 slaves)
├── axi_to_mem ×10         — AXI-to-memory bridges (RAM, SimCtrl, Timer, UART, PIO, I2C, ReLU, VMAC, SG DMA, Softmax)
├── ram_1p                 — 1 MB single-port SRAM
├── simulator_ctrl         — ASCII output and simulation halt (0x20000)
├── timer                  — Timer with interrupt (0x30000)
├── uart                   — UART TX/RX with 8-deep FIFOs (0x40000)
├── pio                    — Programmable I/O: 4 state machines, 32-instr shared memory, GPIO compat (0x50000)
├── i2c_controller         — I2C master controller (0x60000)
├── relu_accel             — ReLU accelerator with DMA (0x70000)
├── vec_mac                — INT8 vector MAC accelerator with DMA (0x80000)
├── sg_dma                 — Scatter-gather DMA engine (0x90000)
└── softmax                — Softmax pipeline with DMA (0xA0000)
```

Memory map: RAM at 0x100000 (1 MB), SimCtrl at 0x20000, Timer at 0x30000, UART at 0x40000, PIO at 0x50000, I2C at 0x60000, ReLU at 0x70000, VMAC at 0x80000, SG DMA at 0x90000, Softmax at 0xA0000. Boot address is 0x100000+0x80.

## Repository Structure

- `hw/rtl/` — OpenSoC RTL (top-level, UART, I2C, dual-UART wrapper, I2C loopback wrapper)
- `hw/opensoc_top.core` — FuseSoC core file defining dependencies and build targets
- `hw/lint/` — Verilator waiver files
- `hw/ip/ibex/` — Ibex submodule (CPU core + shared sim RTL like bus, ram, timer)
- `hw/ip/pulp_axi/` — PULP AXI submodule (crossbar, bridges)
- `hw/ip/common_cells/` — PULP common_cells submodule (required by pulp_axi)
- `hw/ip/pulp_obi/` — PULP OBI submodule (for future use)
- `hw/ip/pio/` — Programmable I/O block (4 SMs, GPIO compat, DMA)
- `hw/ip/relu_accel/` — ReLU accelerator IP
- `hw/ip/vec_mac/` — Vector MAC accelerator IP
- `hw/ip/sg_dma/` — Scatter-gather DMA engine IP
- `hw/ip/softmax/` — Softmax pipeline IP
- `dv/` — Design verification (Verilator testbench)
- `sw/lib/` — Pico SDK-compatible PIO library (header-only)
  - `hardware/pio.h` — Main API (PIO type, SM config, FIFO, program loading)
  - `hardware/pio_instructions.h` — Instruction encoders + `enum pio_src_dest`
  - `hardware/structs/pio.h` — `pio_hw_t` / `pio_sm_hw_t` register struct definitions
  - `hardware_pio_compat.h` — OpenSoC-specific glue (`hw_set_bits`, `clock_get_hz`, GPIO stubs)
  - `pio_programs/i2c.pio.h` — PIO I2C TX program (pioasm-format header with init/write helpers)
- `sw/tests/` — Test software (uart, i2c, pio, pio_sdk, pio_i2c, i2c_loopback, relu, vmac, sg_dma, softmax)

## FuseSoC Core Dependencies

The core `opensoc:soc:opensoc_top` depends on:
- `lowrisc:ibex:ibex_top_tracing` — Ibex CPU with tracing
- `lowrisc:ibex:sim_shared` — Shared simulation RTL (bus, ram_1p, ram_2p, simulator_ctrl, timer)
- `pulp-platform.org::axi` — AXI4 crossbar and protocol bridges
- `opensoc:ip:pio` — Programmable I/O block
- `opensoc:ip:relu_accel` — ReLU accelerator
- `opensoc:ip:vec_mac` — Vector MAC accelerator
- `opensoc:ip:sg_dma` — Scatter-gather DMA engine
- `opensoc:ip:softmax` — Softmax pipeline

Nine `--cores-root` paths are needed: repo root, `hw/ip/ibex`, `hw/ip/ibex/vendor/lowrisc_ip`, `hw/ip/common_cells`, `hw/ip/pulp_axi`, `hw/ip/pio`, `hw/ip/relu_accel`, `hw/ip/vec_mac`, `hw/ip/sg_dma`, `hw/ip/softmax`.

## Key Ibex Parameters

Configurable via FuseSoC `vlogdefine` (command-line `+define+`): RV32M, RV32B, RV32ZC, RegFile. Other parameters (SecureIbex, PMPEnable, ICache, etc.) are set as module-level parameters in `opensoc_top.sv` and use their defaults during lint.

## AXI Configuration

- AXI data width: 32 bits, address width: 32 bits
- Slave-port ID width: 1 bit (from `axi_from_mem`)
- Master-port ID width: 4 bits (xbar prepends $clog2(7) = 3 bits)
- User width: 1 bit
- 7 masters (instr, data, ReLU DMA, VMAC DMA, SG DMA, Softmax DMA, PIO DMA)
- 10 slaves (RAM, SimCtrl, Timer, UART, PIO, I2C, ReLU, VMAC, SG DMA, Softmax)
- `MaxRequests = 2` on all bridges; `MaxMstTrans = 4`, `MaxSlvTrans = 4` on xbar
- ATOPs disabled; NO_LATENCY mode (no pipeline stages)
