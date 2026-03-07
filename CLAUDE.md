# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenSoC is a RISC-V SoC built on the lowRISC **Ibex** CPU core. The top-level module (`opensoc_top`) is a fork of `ibex_simple_system` — a minimal system with Ibex, 1 MB dual-port SRAM, a simulation control module, and a timer, connected via a simple bus.

## Build Commands

All builds use **FuseSoC** and must run under WSL/Linux (not native Windows):

```bash
# Verilator lint (the primary build target today)
make lint

# Equivalent manual command
fusesoc --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
  run --target=lint opensoc:soc:opensoc_top
```

After cloning, initialize submodules: `git submodule update --init --recursive`

## Architecture

```
opensoc_top (hw/rtl/opensoc_top.sv)
├── ibex_top_tracing    — Ibex RISC-V core with trace output
├── bus                 — Simple address-decoded interconnect (1 host, 3 devices)
├── ram_2p              — 1 MB dual-port SRAM (instruction + data)
├── simulator_ctrl      — ASCII output and simulation halt (0x20000)
└── timer               — Timer with interrupt (0x30000)
```

Memory map: RAM at 0x100000 (1 MB), SimCtrl at 0x20000 (1 kB), Timer at 0x30000 (1 kB). Boot address is 0x100000+0x80.

## Repository Structure

- `hw/rtl/` — OpenSoC RTL (our code)
- `hw/opensoc_top.core` — FuseSoC core file defining dependencies and build targets
- `hw/lint/` — Verilator waiver files
- `hw/ip/ibex/` — Ibex submodule (CPU core + shared sim RTL like bus, ram, timer)
- `hw/ip/pulp_axi/` — PULP AXI submodule (for future use)
- `hw/ip/pulp_obi/` — PULP OBI submodule (for future use)
- `dv/` — Design verification (empty, future)
- `sw/` — Software (empty, future)

## FuseSoC Core Dependencies

The core `opensoc:soc:opensoc_top` depends on:
- `lowrisc:ibex:ibex_top_tracing` — Ibex CPU with tracing
- `lowrisc:ibex:sim_shared` — Shared simulation RTL (bus, ram_1p, ram_2p, simulator_ctrl, timer)

Three `--cores-root` paths are needed: repo root, `hw/ip/ibex`, and `hw/ip/ibex/vendor/lowrisc_ip` (for `lowrisc:prim` primitives).

## Key Ibex Parameters

Configurable via FuseSoC `vlogdefine` (command-line `+define+`): RV32M, RV32B, RV32ZC, RegFile. Other parameters (SecureIbex, PMPEnable, ICache, etc.) are set as module-level parameters in `opensoc_top.sv` and use their defaults during lint.
