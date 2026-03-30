# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenSoC is a RISC-V SoC built on the lowRISC **Ibex** CPU core. The top-level module (`opensoc_top`) uses an AXI4 crossbar (`axi_xbar` from PULP) to connect the Ibex CPU (instruction fetch + data port) to 1 MB SRAM, a simulation control module, and a timer.

## Build Commands

All builds use **FuseSoC** and must run under WSL/Linux (not native Windows).

**The user works directly inside a WSL/Ubuntu terminal.** Run all commands directly (e.g. `make lint`) — do NOT wrap with `wsl bash -lc`. The shell already has PATH set up for FuseSoC, Verilator, the RISC-V toolchain, Vivado, etc.

```bash
make lint
make run-hello
```

```bash
# Verilator lint (the primary build target today)
make lint

# Equivalent manual command
fusesoc --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
  --cores-root=hw/ip/common_cells --cores-root=hw/ip/pulp_axi \
  run --target=lint opensoc:soc:opensoc_top
```

After cloning, initialize submodules: `git submodule update --init --recursive`

### Synthesis

```bash
make synth                    # default: FPGA synthesis for Arty A7-100T (Vivado)
make synth FLOW=fpga-arty     # FPGA: Vivado / Arty A7-100T XC7A100T (all accels)
make synth FLOW=fpga-basys3   # FPGA: Vivado / Basys 3 XC7A35T (no accels)
make synth FLOW=yosys         # ASIC: sv2v + Yosys generic gates
make synth FLOW=ol2           # ASIC: OpenLane 2 / Sky130 synthesis + STA
make synth-setup              # FuseSoC setup for Basys 3 (collect sources)
make synth-setup-arty         # FuseSoC setup for Arty A7-100T (collect sources)
```

Each flow calls its own FuseSoC setup target internally; `hw/synth/sources.f` is the shared file list used by the non-Vivado flows.

**FPGA-arty flow** (`FLOW=fpga-arty`, default): Targets Arty A7-100T (XC7A100T). Vivado must be on PATH. Add to `~/.bashrc`: `source /opt/Xilinx/2025.2/Vivado/settings64.sh`. Uses in-process commands (`synth_design`, `opt_design`, `place_design`, `route_design`, `write_bitstream`) — NOT `launch_runs`/`wait_on_run` which hang in batch mode. Sets `FPGA_XILINX=1` (no `FPGA_BASYS3`); derived config selects unified config (512 KB RAM, all 4 accelerators, `CUT_ALL_PORTS`). Reports written to `build/vivado/`.

**FPGA-basys3 flow** (`FLOW=fpga-basys3`): Targets Basys 3 (XC7A35T). Sets `FPGA_XILINX=1 FPGA_BASYS3=1`; derived config selects small FPGA config (64 KB RAM, no accelerators). Reports written to `build/vivado/`.

**OpenLane 2 flow** (`FLOW=ol2`): Runs sv2v → Yosys (Sky130 mapped) → OpenROAD STA. Prerequisites: `sv2v`, Nix with flakes enabled (`experimental-features = nix-command flakes` in `/etc/nix/nix.conf`). The Nix flake provides matched Yosys + OpenROAD + OpenLane. Results in `build/openlane2/runs/`.

**Yosys flow** (`FLOW=yosys`): Quick sanity check with generic gates. Prerequisites: `sv2v`, `yosys` (system install). Results in `build/yosys/`.

Clean rebuild: `make clean && make synth`.

## Architecture

```
opensoc_top (hw/rtl/opensoc_top.sv)
├── ibex_top_tracing       — Ibex RISC-V core with trace output
├── axi_from_mem ×N        — OBI-to-AXI bridges (instr + data + PIO DMA + enabled accel DMAs)
├── axi_xbar               — AXI4 crossbar (N masters × M slaves, sized by enable params)
├── axi_to_mem ×M          — AXI-to-memory bridges (core peripherals + enabled accels)
├── ram_1p                 — 1 MB single-port SRAM (sim) / 64 KB block RAM (FPGA)
├── simulator_ctrl         — ASCII output and simulation halt (0x20000)
├── timer                  — Timer with interrupt (0x30000)
├── uart                   — UART TX/RX with 8-deep FIFOs (0x40000)
├── pio                    — Programmable I/O: 4 state machines, 32-instr shared memory, GPIO compat (0x50000)
├── i2c_controller         — I2C master controller (0x60000)
├── relu_accel             — ReLU accelerator with DMA (0x70000) [optional]
├── vec_mac                — INT8 vector MAC accelerator with DMA (0x80000) [optional]
├── sg_dma                 — Scatter-gather DMA engine (0x90000) [optional]
└── softmax                — Softmax pipeline with DMA (0xA0000) [optional]
```

`opensoc_top` has **no module parameters** — all configuration comes from `opensoc_derived_config_pkg` (imported via wildcard). The derived package selects between `opensoc_config_pkg` (unified: 512 KB RAM, all 4 accels, `CUT_ALL_PORTS`) and `opensoc_top_fpga_config_pkg` (Basys 3: 64 KB, no accels) based on preprocessor defines.

Accelerator enables (`EnableReLU`, `EnableVMAC`, `EnableSgDma`, `EnableSoftmax`) are set in the active config package. The crossbar dimensions (`NumMasters`, `NumSlaves`) and address map are computed dynamically from these enables in the derived package.

Memory map: RAM at 0x100000 (1 MB / 512 KB on unified FPGA), SimCtrl at 0x20000, Timer at 0x30000, UART at 0x40000, PIO at 0x50000, I2C at 0x60000, ReLU at 0x70000, VMAC at 0x80000, SG DMA at 0x90000, Softmax at 0xA0000. Boot address is 0x100000+0x80.

## Repository Structure

- `hw/rtl/` — OpenSoC RTL (top-level, UART, I2C, dual-UART wrapper, I2C loopback wrapper)
  - `opensoc_config_pkg.sv` — Unified config: ASIC + full-feature FPGA (512 KB, all accels, `CUT_ALL_PORTS`)
  - `opensoc_top_fpga_config_pkg.sv` — Basys 3 config: 64 KB RAM, no accels, `CUT_ALL_PORTS`, `RegFileFPGA`
  - `opensoc_derived_config_pkg.sv` — Selects active config via `ifdef`; computes all derived values (crossbar dims, AXI widths, typedefs, address map)
- `hw/fpga/basys3/` — Basys 3 FPGA target (XC7A35T): constraints, wrapper, synth script
- `hw/fpga/arty_a7/` — Arty A7-100T FPGA target (XC7A100T): constraints, wrapper, synth script
- `hw/asic/` — ASIC synthesis (sv2v + Yosys script, OpenLane 2 flow)
- `hw/synth/` — Shared source file list (`sources.f`) for all synth flows
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

Configurable via FuseSoC `vlogdefine` (command-line `+define+`): `RV32M`, `RV32B`, `RV32ZC`, `RegFile`. These are consumed by macro guards in `opensoc_config_pkg.sv` (defaults to `RV32MFast`, `RV32BNone`, `RV32ZcaZcbZcmp`, `RegFileFF`). `opensoc_top` has no module-level parameters — all values come from `opensoc_derived_config_pkg`.

## AXI Configuration

- AXI data width: 32 bits, address width: 32 bits
- Slave-port ID width: 1 bit (from `axi_from_mem`)
- Master-port ID width: computed as `$clog2(NumMasters) + 1` (4 bits with all accels enabled)
- User width: 1 bit
- Masters/slaves: parameterized — 3+N masters, 6+N slaves (N = number of enabled accelerators)
  - Default (sim): 7 masters, 10 slaves (all 4 accelerators enabled)
  - FPGA (Basys 3): 3 masters, 6 slaves (all accelerators disabled)
- Master order: instr, data, [accel DMAs in order], PIO DMA (always last)
- Slave order: RAM, SimCtrl, Timer, UART, PIO, I2C, [accel ctrls in order]
- `MaxRequests = 2` on all bridges; `MaxMstTrans = 4`, `MaxSlvTrans = 4` on xbar
- ATOPs disabled; `XbarLatencyMode`: `CUT_ALL_PORTS` in both unified and Basys 3 configs (pipeline registers for timing closure; harmless for ASIC); sim uses `NO_LATENCY` via direct parameter in the sim target

## FPGA Configuration

### Arty A7-100T (default, `FLOW=fpga-arty`)

- Part: XC7A100T-1CSG324C (Artix-7, 63K LUTs, 607 KB BRAM)
- System clock: 100 MHz board oscillator → `PLLE2_ADV` → 50 MHz
- RAM: 512 KB block RAM (`RamDepth = 131072`)
- Accelerators: all enabled (`EnableReLU/VMAC/SgDma/Softmax = 1`) → 7 masters, 10 slaves
- AXI latency: `CUT_ALL_PORTS`
- Reset: `btn[0]` active-high → 2-FF synchronizer → active-low `rst_n`
- Verilog defines: `SYNTHESIS=1`, `FPGA_XILINX=1` (no `FPGA_BASYS3`) → derived pkg selects `opensoc_config_pkg`
- Register file: `RegFileFPGA` (selected in derived pkg by `FPGA_XILINX` without `FPGA_BASYS3`)
- FPGA wrapper: `hw/fpga/arty_a7/opensoc_fpga_arty_a7_top.sv`
- Constraints: `hw/fpga/arty_a7/arty_a7.xdc`
- Synth script: `hw/fpga/arty_a7/synth.tcl`

### Basys 3 (`FLOW=fpga-basys3`)

- Part: XC7A35T-1CPG236C (Artix-7)
- System clock: 100 MHz board oscillator → Vivado `clk_wiz` PLL → 50 MHz
- RAM: 64 KB block RAM (`RamDepth = 16384`)
- Accelerators: all disabled (`EnableReLU/VMAC/SgDma/Softmax = 0`) → 3 masters, 6 slaves
- AXI latency: `CUT_ALL_PORTS`
- Reset: active-high `btnC` → 2-FF synchronizer → active-low `rst_n`
- Verilog defines: `SYNTHESIS=1`, `FPGA_XILINX=1`, `FPGA_BASYS3=1` → derived pkg selects `opensoc_top_fpga_config_pkg`
- Register file: `RegFileFPGA` (from `opensoc_top_fpga_config_pkg`)
- FPGA wrapper: `hw/fpga/basys3/opensoc_fpga_top.sv`
- Constraints: `hw/fpga/basys3/basys3.xdc`
- Synth script: `hw/fpga/basys3/synth.tcl` (in-process commands, not `launch_runs`)
