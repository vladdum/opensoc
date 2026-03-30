# OpenSoC

A RISC-V System-on-Chip built on the lowRISC [Ibex](https://github.com/lowRISC/ibex) CPU core, using an AXI4 crossbar from [PULP Platform](https://github.com/pulp-platform/axi) to connect the CPU to memory and peripherals.

## Architecture

```
opensoc_top (hw/rtl/opensoc_top.sv)
├── ibex_top_tracing    — Ibex RISC-V core with trace output
├── axi_from_mem ×N     — OBI-to-AXI bridges (CPU instr/data + PIO DMA + accel DMAs)
├── axi_xbar            — AXI4 crossbar (parameterized masters × slaves)
├── axi_to_mem ×M       — AXI-to-memory bridges
├── ram_1p              — 512 KB SRAM (unified FPGA/ASIC) / 64 KB block RAM (Basys 3)
├── simulator_ctrl      — ASCII output and simulation halt
├── timer               — Timer with interrupt
├── uart                — UART with TX/RX FIFOs
├── pio                 — Programmable I/O: 4 state machines, GPIO compat, DMA (hw/ip/pio/)
├── i2c_controller      — I2C master controller
├── relu_accel          — ReLU accelerator with DMA (hw/ip/relu_accel/) [optional]
├── vec_mac             — INT8 vector MAC accelerator with DMA (hw/ip/vec_mac/) [optional]
├── sg_dma              — Scatter-gather DMA engine (hw/ip/sg_dma/) [optional]
└── softmax             — Softmax pipeline accelerator with DMA (hw/ip/softmax/) [optional]
```

### Memory Map

| Peripheral     | Base Address | Size  | IRQ        |
|----------------|--------------|-------|------------|
| Simulator Ctrl | `0x20000`    | 1 kB  | —          |
| Timer          | `0x30000`    | 1 kB  | mtimer     |
| UART           | `0x40000`    | 1 kB  | fast[0]    |
| PIO            | `0x50000`    | 1 kB  | fast[1]    |
| I2C            | `0x60000`    | 1 kB  | fast[2]    |
| ReLU Accel     | `0x70000`    | 1 kB  | fast[3]    |
| Vector MAC     | `0x80000`    | 1 kB  | fast[4]    |
| SG DMA         | `0x90000`    | 1 kB  | fast[5]    |
| Softmax        | `0xA0000`    | 1 kB  | fast[6]    |
| RAM            | `0x100000`   | 512 KB (unified) / 64 KB (Basys 3) | — |

Register definitions for all peripherals: [`sw/include/opensoc_regs.h`](sw/include/opensoc_regs.h)

Boot address: `0x100080` (RAM base + 0x80).

## Getting Started

### Installing Ubuntu via WSL (Windows only)

All builds require a Linux environment. On Windows, use **WSL (Windows Subsystem for Linux)** to run Ubuntu:

1. Open **PowerShell as Administrator** and run:
   ```powershell
   wsl --install
   ```
   This installs WSL 2 and Ubuntu by default. Restart your PC when prompted.

2. After reboot, Ubuntu will launch automatically to finish setup. Create a Unix username and password when asked.

3. To verify the installation, open PowerShell and run:
   ```powershell
   wsl -l -v
   ```
   You should see Ubuntu listed with VERSION 2.

4. Launch Ubuntu from the Start menu, or type `wsl` in PowerShell/Terminal.

5. Update packages inside Ubuntu:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

> **Tip:** To install a specific Ubuntu version, run `wsl --install -d Ubuntu-24.04`.
> Run `wsl --list --online` to see all available distributions.

All build commands below should be run inside the WSL/Ubuntu terminal.

### Prerequisites

- **WSL / Linux** — builds do not run under native Windows.
- **[Verilator](https://www.veripool.org/verilator/)** (≥ 4.210) — for linting and simulation.
  Linux package managers often ship an old version; building from source is
  recommended (see [full install guide](https://verilator.org/guide/latest/install.html)):
  ```bash
  sudo apt-get install git help2man perl python3 make autoconf g++ flex bison ccache
  sudo apt-get install libgoogle-perftools-dev numactl perl-doc
  sudo apt-get install libfl2 libfl-dev        # Ubuntu only (ignore errors)
  sudo apt-get install zlib1g zlib1g-dev       # Ubuntu only (ignore errors)
  git clone https://github.com/verilator/verilator.git
  cd verilator
  git checkout v5.020   # or latest stable tag
  autoconf
  ./configure
  make -j $(nproc)
  sudo make install
  ```
- **FuseSoC and Python dependencies** — install with:
  ```bash
  pip3 install fusesoc
  pip3 install -U -r hw/ip/ibex/python-requirements.txt
  ```
- **RISC-V GCC toolchain** — lowRISC provides pre-built toolchains at
  <https://github.com/lowRISC/lowrisc-toolchains/releases>.
  The compiler prefix should be `riscv32-unknown-elf-`.
- **libelf** — on Debian/Ubuntu: `sudo apt-get install libelf-dev`.
- **GTKWave** (optional, for waveform viewing) — on Debian/Ubuntu: `sudo apt-get install gtkwave`.
  Requires WSLg (WSL2 on Windows 10 21H2+) or an X server (e.g. VcXsrv) for GUI display.
- **srecord** (optional, for vmem files) — on Debian/Ubuntu: `sudo apt-get install srecord`.

#### Synthesis-specific prerequisites

| Flow | Command | Prerequisites |
|------|---------|---------------|
| **FPGA / Arty A7-100T** (default) | `make synth` | [Vivado](https://www.xilinx.com/products/design-tools/vivado.html) |
| **FPGA / Basys 3** | `make synth FLOW=fpga-basys3` | [Vivado](https://www.xilinx.com/products/design-tools/vivado.html) (free WebPACK edition) |
| **OpenLane 2** | `make synth FLOW=ol2` | [Nix](https://nixos.org/download/) with flakes enabled, [sv2v](https://github.com/zachjs/sv2v) |
| **Yosys generic** | `make synth FLOW=yosys` | [sv2v](https://github.com/zachjs/sv2v), [Yosys](https://github.com/YosysHQ/yosys) |

**Nix setup** (for OpenLane 2 flow):
```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
# After install, restart your terminal, then enable flakes:
sudo sh -c 'echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf'
sudo systemctl restart nix-daemon
```
The first `make synth` run downloads the OpenLane 2 toolchain via Nix (~2 GB, cached afterwards).

**Vivado setup** (for FPGA flow — add to `~/.bashrc`):
```bash
source /opt/Xilinx/2025.2/Vivado/settings64.sh
```

### Clone and initialize

```bash
git clone https://github.com/vladdum/opensoc.git
cd opensoc
git submodule update --init --recursive
```

## Build Commands

Run `make help` to list all targets:

```
make lint                        Run Verilator lint
make build                       Build Verilator simulator (default TOP=opensoc_top)
make build TOP=dual_uart         Build dual-UART simulator
make build TOP=i2c_loopback      Build I2C loopback simulator
make run-<test>                  Build SW and run simulation (e.g. make run-relu)
make synth                       Synthesize (default: Arty A7-100T FPGA)
make synth FLOW=fpga-arty        FPGA synthesis (Vivado / Arty A7-100T, all accels)
make synth FLOW=fpga-basys3      FPGA synthesis (Vivado / Basys 3, no accels)
make synth FLOW=yosys            ASIC synthesis (sv2v + Yosys, generic gates)
make synth FLOW=ol2              ASIC synthesis (OpenLane 2 / Sky130 + STA)
make clean                       Remove build directory
```

Available tests: `hello`, `uart`, `pio`, `pio-sdk`, `pio-i2c`, `i2c`, `relu`, `vmac`, `sg-dma`, `softmax`, `dual-uart`, `i2c-loopback`.

Options: `FLOW=fpga-arty|fpga-basys3|yosys|ol2` selects synthesis flow (default: `fpga-arty`). `TRACE=1` enables FST waveform dump, `WAVES=1` enables trace + opens GTKWave.

### Synthesis

Four synthesis flows are available, selected via the `FLOW` variable:

```bash
make synth                    # FPGA: Vivado / Arty A7-100T XC7A100T (default)
make synth FLOW=fpga-arty     # FPGA: Vivado / Arty A7-100T XC7A100T (all accels)
make synth FLOW=fpga-basys3   # FPGA: Vivado / Basys 3 XC7A35T (no accels)
make synth FLOW=yosys         # ASIC: sv2v + Yosys generic gates (quick sanity check)
make synth FLOW=ol2           # ASIC: OpenLane 2 / Sky130 synthesis + STA
```

Each flow calls its own FuseSoC setup internally. `hw/synth/sources.f` is the shared file list for the non-Vivado flows. Use `make clean` to force a fresh setup.

#### FPGA / Vivado — Arty A7-100T (default)

Targets the Digilent Arty A7-100T (Xilinx Artix-7 XC7A100T, 63K LUTs / 607 KB BRAM). All 4 accelerators enabled; 512 KB block RAM. Full flow: synth → opt → place → phys_opt → route → bitstream.

**Two-step build** (useful when iterating in the Vivado GUI):
```bash
make synth-setup-arty
vivado -mode batch -source hw/fpga/arty_a7/synth.tcl
```

Reports: `build/vivado/` — `post_synth_timing.txt`, `post_route_timing.txt`, `post_synth_utilization.txt`, `post_route_utilization.txt`, `opensoc_arty_a7.bit`.

#### FPGA / Vivado — Basys 3

Targets the Digilent Basys 3 (Xilinx Artix-7 XC7A35T). Accelerators disabled; 64 KB block RAM. Full flow: synth → opt → place → phys_opt → route → bitstream.

**Two-step build** (useful when iterating in the Vivado GUI):
```bash
make synth-setup
vivado -mode batch -source hw/fpga/basys3/synth.tcl
```

Reports: `build/vivado/` — `post_synth_timing.txt`, `post_route_timing.txt`, `post_synth_utilization.txt`, `post_route_utilization.txt`, `opensoc_basys3.bit`.

#### OpenLane 2 / Sky130

Runs sv2v → Yosys synthesis mapped to Sky130 standard cells → pre-PNR static timing analysis (OpenROAD). All tools are provided by the OpenLane 2 Nix flake — no manual tool installation needed beyond Nix itself.

Results: `build/openlane2/runs/<tag>/` — synthesis stats + STA reports.

#### Yosys generic gates

Quick sanity check — converts SystemVerilog via sv2v, then synthesizes to technology-independent gates with Yosys. No timing analysis.

Results: `build/yosys/opensoc_top_netlist.v`, `build/yosys/yosys.log`.

**Clean rebuild:** `make clean && make synth`.

**Arty A7-100T pin mapping (`FLOW=fpga-arty`):**

| Board resource  | SoC signal       | Notes                            |
|-----------------|------------------|----------------------------------|
| LED[3:0]        | gpio_o[3:0]      | Active-high                      |
| SW[3:0]         | gpio_i[3:0]      | Direct sample                    |
| BTN[3:1]        | gpio_i[6:4]      | Direct sample                    |
| Pmod JA[0]      | I2C SDA          | Open-drain (external pullup)     |
| Pmod JA[1]      | I2C SCL          | Open-drain (external pullup)     |
| Pmod JD[7:0]    | gpio[15:8]       | Bidirectional with OE            |
| USB-UART        | UART TX/RX       | Via on-board FTDI bridge         |
| BTN[0]          | Reset            | Active-high, inverted internally |

Clock: 100 MHz board oscillator → PLLE2_ADV → 50 MHz system clock. RAM: 512 KB block RAM. All 4 accelerators enabled.

**Basys 3 pin mapping (`FLOW=fpga-basys3`):**

| Board resource | SoC signal        | Notes                           |
|----------------|-------------------|---------------------------------|
| LED[15:0]      | gpio_o[15:0]      | Active-high                     |
| SW[15:0]       | gpio_i[15:0]      | Direct sample                   |
| Pmod JB[7:0]   | gpio[23:16]       | Bidirectional with OE           |
| Pmod JA[0]     | I2C SDA           | Open-drain (external pullup)    |
| Pmod JA[1]     | I2C SCL           | Open-drain (external pullup)    |
| USB-UART       | UART TX/RX        | Via on-board FTDI bridge        |
| btnC           | Reset             | Active-high, inverted internally|

Clock: 100 MHz board oscillator → clk_wiz PLL → 50 MHz system clock. RAM: 64 KB block RAM. Accelerators disabled to fit XC7A35T.

### Waveform Viewing

Install [GTKWave](http://gtkwave.sourceforge.net/) (`sudo apt install gtkwave` on Ubuntu/WSL).

Use `WAVES=1` to automatically open GTKWave with a saved signal view after simulation:

```bash
make run-dual-uart WAVES=1
```

Or use `TRACE=1` to generate the FST trace and open it manually:

```bash
make run-hello TRACE=1
gtkwave build/opensoc_soc_opensoc_top_0/sim-verilator/sim.fst
```

Saved waveform views (`.gtkw` files) are stored in `dv/verilator/`.

## Repository Structure

```
hw/rtl/              — OpenSoC RTL (top-level, config pkgs, peripherals)
  opensoc_config_pkg.sv            — Unified config: ASIC + full-feature FPGA
  opensoc_top_fpga_config_pkg.sv   — Basys 3 config: 64 KB, no accels
  opensoc_derived_config_pkg.sv    — Derived values: crossbar dims, AXI types, addr map
hw/opensoc_top.core  — FuseSoC core file (dependencies & build targets)
hw/lint/             — Verilator waiver files
hw/ip/ibex/          — Ibex submodule (CPU core + shared sim RTL)
hw/ip/pulp_axi/      — PULP AXI submodule (crossbar, bridges)
hw/ip/common_cells/  — PULP common_cells submodule (required by pulp_axi)
hw/ip/pulp_obi/      — PULP OBI submodule (for future use)
hw/ip/pio/           — Programmable I/O block (4 SMs, GPIO compat, DMA)
hw/ip/relu_accel/    — ReLU accelerator IP (reusable DMA framework)
hw/ip/vec_mac/       — Vector MAC accelerator IP (INT8 dot product)
hw/ip/sg_dma/        — Scatter-gather DMA engine IP
hw/ip/softmax/       — Softmax pipeline IP (3-pass, exp LUT)
hw/fpga/basys3/      — Basys 3 FPGA target (XC7A35T): constraints, wrapper, synth.tcl
hw/fpga/arty_a7/     — Arty A7-100T FPGA target (XC7A100T): constraints, wrapper, synth.tcl
hw/asic/             — ASIC synthesis (sv2v + Yosys, OpenLane 2 flow)
hw/synth/            — Shared source file list (sources.f) for non-Vivado flows
dv/verilator/        — Verilator simulation testbench
sw/lib/              — Pico SDK-compatible PIO library (header-only)
sw/include/          — Shared headers (opensoc_regs.h)
sw/tests/            — Test software
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
