# OpenSoC Programmable I/O (PIO) Block

## Overview

The PIO block is a programmable pin-level protocol engine inspired by the RP2040's PIO architecture. It replaces the simple GPIO peripheral at address `0x50000` and provides:

- **4 independent state machines** — each with its own program counter, shift registers, scratch registers, clock divider, and pin mapping
- **32-instruction shared memory** — 16-bit instructions loaded by the CPU, executed by state machines
- **9-instruction ISA** — JMP, WAIT, IN, OUT, PUSH, PULL, MOV, IRQ, SET
- **4-word TX/RX FIFOs per SM** — buffered data transfer between CPU and state machines
- **DMA master port** — bulk FIFO transfers without CPU intervention
- **GPIO compatibility** — basic DIR/OUT/IN registers for simple pin control
- **8 IRQ flags** — shared between state machines, exposed as single interrupt to Ibex

PIO enables autonomous execution of bit-banged protocols without CPU intervention.

## Use Cases

PIO is designed for any situation where the CPU would otherwise waste cycles toggling pins or where precise, jitter-free timing is required:

- **SPI master/slave** — clock + data lines driven at exact rates, full-duplex via two SMs
- **I2C master** — open-drain clock stretching and arbitration handled in hardware
- **WS2812 / NeoPixel LEDs** — strict 800 kHz timing with ±150 ns tolerance that software bit-bang cannot reliably meet
- **UART TX/RX** — custom baud rates without a dedicated UART peripheral, multiple simultaneous channels
- **JTAG / SWD** — debug probe interface at precise clock rates
- **Parallel bus interfaces** — 8/16-bit parallel data capture or output (e.g., camera, LCD)
- **Quadrature encoder** — decode rotary encoder signals with zero CPU overhead
- **PWM** — up to 4 independent PWM channels with arbitrary resolution
- **Custom serial protocols** — one-wire, Manchester encoding, infrared remote, DMX512
- **Logic analyzer / pattern generator** — capture or replay pin transitions at SM clock rate

Each state machine runs independently, so multiple protocols can operate simultaneously on different pins (e.g., SPI on pins 0-3 while driving WS2812 on pin 4).

## Architecture

```
pio.sv (top-level: registers + FIFO + GPIO compat + DMA FSM)
├── pio_sm.sv ×4     — State machine (PC, decoder, ISR/OSR, X/Y, shift counters)
├── instr_mem[32]    — Shared 16-bit instruction memory
├── tx_fifo[4][4]    — 4-word TX FIFOs (one per SM)
├── rx_fifo[4][4]    — 4-word RX FIFOs (one per SM)
├── irq_flags[8]     — Shared IRQ flag register
├── gpio_compat      — DIR/OUT/IN registers
└── dma_fsm          — DMA master port FSM
```

### SoC Integration

The PIO block occupies the GPIO slot in the AXI4 crossbar:

- **Slave port** (control registers): `axi_to_mem` bridge at crossbar slave index 4 (address `0x50000`, 1 kB window)
- **Master port** (DMA): `axi_from_mem` bridge at crossbar master index 6
- **Interrupt**: `irq_fast_i[1]` (replaces GPIO IRQ)
- **Pin I/O**: `gpio_i[31:0]`, `gpio_o[31:0]`, `gpio_oe[31:0]`

### Pin I/O

```
                    ┌──────────────────┐
    gpio_i[31:0] ──►│  2-FF Sync       │──► synced_pins ──► SM IN sources
                    └──────────────────┘                ──► GPIO_IN register

   SM0 out ──┐
   SM1 out ──┤     ┌──────────────────┐
   SM2 out ──┼────►│  Pin Mux (reg'd) │──► gpio_o[31:0]
   SM3 out ──┘     │  SM3>SM2>SM1>SM0 │──► gpio_oe[31:0]
   GPIO_OUT ──────►│  >GPIO compat    │
   GPIO_DIR ──────►│                  │
                   └──────────────────┘
```

**Pin mux priority:** SM3 > SM2 > SM1 > SM0 > GPIO compat registers. A pin belongs to an SM's driven set if it falls within that SM's configured OUT, SET, or SIDE-SET pin range and the SM is enabled. Pins not claimed by any enabled SM are controlled by GPIO compat registers.

**Pin output registration:** The mux output is registered (one FF stage) to break combinational depth. This adds one system clock cycle of latency to all pin changes uniformly.

**Inputs** are always readable by all SMs and GPIO_IN simultaneously, regardless of output ownership.

---

## State Machine

Each of the 4 state machines contains:

| Component | Width | Description |
|-----------|-------|-------------|
| PC | 5-bit | Program counter (0-31) |
| ISR | 32-bit | Input shift register |
| OSR | 32-bit | Output shift register |
| X | 32-bit | Scratch register |
| Y | 32-bit | Scratch register |
| ISR shift count | 6-bit | Bits shifted into ISR |
| OSR shift count | 6-bit | Bits shifted out of OSR |

### Execution Model

Each SM executes one instruction per divided clock tick:

1. Fetch instruction from `instr_mem[pc]`
2. Decode and execute (may stall on FIFO or WAIT condition)
3. Apply side-set outputs (same clock edge as execution)
4. Count delay cycles (side-set held steady during delay)
5. Advance PC (wrap from `wrap_top` back to `wrap_bottom`)

### Clock Divider

The clock divider produces a tick-enable signal from the system clock:

```
SM tick rate = sysclk / INT
```

`INT` is the 16-bit integer field from `SMn_CLKDIV[31:16]`. Values of 0 and 1 both produce every-cycle ticks.

> **Note:** The FRAC[15:8] fractional divider field is reserved for future use. Only integer division is supported in Phase 1.

### Stall Behavior

An SM stalls when:
- **WAIT** condition is not met
- **PUSH** to a full RX FIFO (with BLOCK=1)
- **PULL** from an empty TX FIFO (with BLOCK=1)
- **IRQ WAIT** flag is still set

During a stall:
- Side-set still takes effect on the first stall cycle
- Delay counter does NOT advance
- The SM re-evaluates the stall condition each tick

### Forced Instruction

Writing to `SMn_INSTR` forces the SM to execute that instruction on the next tick, preempting any delay or stall. The PC is not advanced after a forced instruction unless the instruction itself modifies the PC (JMP, OUT PC, MOV PC).

Use forced instructions for initialization before enabling the SM (e.g., `SET PINDIRS` to configure pin directions).

### SM Restart

Writing 1 to `CTRL[7:4]` (SM_RESTART) for an SM:
- Resets PC to `wrap_bottom`
- Clears ISR, OSR, X, Y, and shift counters
- Does **NOT** clear FIFOs
- Does **NOT** disable the SM

### Autopush / Autopull

- **Autopush:** When `AUTOPUSH` is enabled and the ISR shift count reaches `PUSH_THRESH`, the ISR is automatically pushed to the RX FIFO and cleared. If the RX FIFO is full, the SM stalls.
- **Autopull:** When `AUTOPULL` is enabled and the OSR shift count reaches `PULL_THRESH`, the OSR is automatically refilled from the TX FIFO. If the TX FIFO is empty, the SM stalls.

Threshold value of 0 means 32 bits.

---

## Instruction Set Architecture

All instructions are 16 bits wide:

```
┌───────────┬───────────────┬─────────────────────┐
│  15:13    │    12:8       │       7:0           │
│  Opcode   │ Delay/Sideset │ Instruction operands│
└───────────┴───────────────┴─────────────────────┘
```

### Delay and Side-set Field (bits 12:8)

The 5-bit field is split based on `SIDESET_COUNT` in `SMn_PINCTRL`:

| SIDESET_COUNT | Side-set bits | Delay bits | Max delay |
|---------------|---------------|------------|-----------|
| 0 | none | [12:8] | 31 |
| 1 | [12] | [11:8] | 15 |
| 2 | [12:11] | [10:8] | 7 |
| 3 | [12:10] | [9:8] | 3 |
| 4 | [12:9] | [8] | 1 |
| 5 | [12:8] | none | 0 |

Side-set values are applied to consecutive pins starting from `SIDESET_BASE`.

### JMP (opcode 000)

Conditional branch.

```
┌─────┬───────────┬─────────┬───────────┐
│ 000 │ delay/ss  │  cond   │  address  │
│15:13│   12:8    │  7:5    │   4:0     │
└─────┴───────────┴─────────┴───────────┘
```

| Condition (7:5) | Mnemonic | Description |
|-----------------|----------|-------------|
| 000 | (always) | Unconditional jump |
| 001 | !X | Jump if X is zero |
| 010 | X-- | Jump if X is nonzero, then post-decrement X |
| 011 | !Y | Jump if Y is zero |
| 100 | Y-- | Jump if Y is nonzero, then post-decrement Y |
| 101 | X!=Y | Jump if X does not equal Y |
| 110 | PIN | Jump if input pin is high (pin selected by `JMP_PIN` in EXECCTRL) |
| 111 | !OSRE | Jump if OSR is not empty (shift count < threshold) |

Target address in bits 4:0.

### WAIT (opcode 001)

Stall until a condition is met.

```
┌─────┬───────────┬────┬────────┬───────────┐
│ 001 │ delay/ss  │ pol│ source │   index   │
│15:13│   12:8    │ 7  │  6:5   │   4:0     │
└─────┴───────────┴────┴────────┴───────────┘
```

| Source (6:5) | Description |
|-------------|-------------|
| 00 | GPIO — absolute pin number in bits 4:0 |
| 01 | PIN — relative to `IN_BASE`, offset in bits 4:0 |
| 10 | IRQ — flag index in bits 4:0 (bit 4 = relative to SM number) |

Polarity (bit 7): 1 = wait for high/set, 0 = wait for low/clear.

For `WAIT IRQ`, once the condition is met, the flag is automatically cleared.

### IN (opcode 010)

Shift bits into ISR from a source.

```
┌─────┬───────────┬──────────┬───────────┐
│ 010 │ delay/ss  │  source  │ bit_count │
│15:13│   12:8    │   7:5    │   4:0     │
└─────┴───────────┴──────────┴───────────┘
```

| Source (7:5) | Description |
|-------------|-------------|
| 000 | PINS — from IN pin group (`IN_BASE`, `IN_COUNT`) |
| 001 | X |
| 010 | Y |
| 011 | NULL (zeros) |
| 110 | ISR |
| 111 | OSR |

Bit count in bits 4:0 (value 0 means 32 bits). Bits are shifted into ISR according to `IN_SHIFTDIR` (0=left, 1=right). The ISR shift count is incremented by the bit count.

### OUT (opcode 011)

Shift bits from OSR to a destination.

```
┌─────┬───────────┬─────────────┬───────────┐
│ 011 │ delay/ss  │ destination │ bit_count │
│15:13│   12:8    │    7:5      │   4:0     │
└─────┴───────────┴─────────────┴───────────┘
```

| Destination (7:5) | Description |
|-------------------|-------------|
| 000 | PINS — to OUT pin group (`OUT_BASE`, `OUT_COUNT`) |
| 001 | X |
| 010 | Y |
| 011 | NULL (discard) |
| 100 | PINDIRS |
| 101 | PC (jump to shifted-out value) |
| 110 | ISR (copy into ISR, reset ISR shift count) |
| 111 | EXEC (reserved — Phase 2) |

Bit count in bits 4:0 (value 0 means 32 bits). Bits are shifted out of OSR according to `OUT_SHIFTDIR` (0=left, 1=right). The OSR shift count is incremented by the bit count.

### PUSH / PULL (opcode 100)

Transfer data between shift registers and FIFOs.

```
┌─────┬───────────┬────┬────┬────┬─────────┐
│ 100 │ delay/ss  │ P  │ IF │ BLK│  (rsvd) │
│15:13│   12:8    │ 7  │ 6  │  5 │  4:0    │
└─────┴───────────┴────┴────┴────┴─────────┘
```

| Bit | Name | Description |
|-----|------|-------------|
| 7 | P | 0 = PUSH (ISR → RX FIFO), 1 = PULL (TX FIFO → OSR) |
| 6 | IF | PUSH: IF_FULL (only push if ISR shift count reaches threshold). PULL: IF_EMPTY (only pull if OSR shift count reaches threshold) |
| 5 | BLK | BLOCK: 1 = stall if FIFO is full (PUSH) or empty (PULL). 0 = no-op if FIFO is full/empty |

**PUSH:** Copies ISR to RX FIFO and clears ISR and shift count.
**PULL:** Copies TX FIFO entry to OSR and clears shift count. If non-blocking and FIFO is empty, copies X into OSR instead.

### MOV (opcode 101)

Copy data between registers with optional transformation.

```
┌─────┬───────────┬─────────────┬──────┬──────────┐
│ 101 │ delay/ss  │ destination │  op  │  source  │
│15:13│   12:8    │    7:5      │ 4:3  │   2:0    │
└─────┴───────────┴─────────────┴──────┴──────────┘
```

**Sources (2:0):**

| Code | Source |
|------|--------|
| 0 | PINS (input pins) |
| 1 | X |
| 2 | Y |
| 3 | NULL (all zeros) |
| 5 | STATUS (returns 0 in Phase 1) |
| 6 | ISR |
| 7 | OSR |

**Destinations (7:5):**

| Code | Destination |
|------|-------------|
| 0 | PINS (output pins) |
| 1 | X |
| 2 | Y |
| 4 | EXEC (reserved — Phase 2) |
| 5 | PC |
| 6 | ISR (also clears ISR shift count) |
| 7 | OSR |

**Operations (4:3):**

| Code | Operation |
|------|-----------|
| 00 | None (pass through) |
| 01 | Invert (bitwise NOT) |
| 10 | Bit-reverse (returns input unchanged in Phase 1) |

### IRQ (opcode 110)

Set, clear, or wait on IRQ flags.

```
┌─────┬───────────┬─────┬────┬─────┬───────────┐
│ 110 │ delay/ss  │(rsvd)│WAIT│ CLR │   index  │
│15:13│   12:8    │  7  │  6 │  5  │   4:0     │
└─────┴───────────┴─────┴────┴─────┴───────────┘
```

| Bit | Name | Description |
|-----|------|-------------|
| 6 | WAIT | Stall until the flag is cleared by another entity |
| 5 | CLR | 0 = set flag, 1 = clear flag |
| 4:0 | Index | IRQ flag index. Bit 4: if set, actual index = `(index[2:0] + sm_number) % 4` |

**Relative IRQ indexing:** When bit 4 is set, flags 0-3 are SM-relative. Flags 4-7 are shared (not SM-relative, always absolute).

### SET (opcode 111)

Write a 5-bit immediate value to a destination.

```
┌─────┬───────────┬─────────────┬───────────┐
│ 111 │ delay/ss  │ destination │   data    │
│15:13│   12:8    │    7:5      │   4:0     │
└─────┴───────────┴─────────────┴───────────┘
```

| Destination (7:5) | Description |
|-------------------|-------------|
| 000 | PINS — write to SET pin group (`SET_BASE`, `SET_COUNT`) |
| 001 | X (5-bit immediate, zero-extended to 32) |
| 010 | Y (5-bit immediate, zero-extended to 32) |
| 100 | PINDIRS — set pin directions for SET pin group |

### Instruction Encoding Quick Reference

| Opcode | 15:13 | 7:5 / 7 | 4:0 |
|--------|-------|---------|-----|
| JMP | 000 | condition | address |
| WAIT | 001 | pol + source | index |
| IN | 010 | source | bit_count |
| OUT | 011 | destination | bit_count |
| PUSH | 100 | 0 + IF + BLK | (reserved) |
| PULL | 100 | 1 + IF + BLK | (reserved) |
| MOV | 101 | destination | op + source |
| IRQ | 110 | (rsvd) + WAIT + CLR | index |
| SET | 111 | destination | data |

---

## Register Map

Base address: `0x50000`. Total register space: 348 bytes (0x15C).

### Global Registers

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x000 | CTRL | RW | SM enable [3:0], SM restart [7:4] (W1S), CLKDIV restart [11:8] (W1S) |
| 0x004 | FSTAT | RO | FIFO status (see below) |
| 0x008 | FDEBUG | W1C | FIFO debug (reserved — Phase 2) |
| 0x00C | FLEVEL | RO | FIFO levels (reserved — Phase 2) |
| 0x010 | TXF0 | WO | SM0 TX FIFO write |
| 0x014 | TXF1 | WO | SM1 TX FIFO write |
| 0x018 | TXF2 | WO | SM2 TX FIFO write |
| 0x01C | TXF3 | WO | SM3 TX FIFO write |
| 0x020 | RXF0 | RO | SM0 RX FIFO read |
| 0x024 | RXF1 | RO | SM1 RX FIFO read |
| 0x028 | RXF2 | RO | SM2 RX FIFO read |
| 0x02C | RXF3 | RO | SM3 RX FIFO read |
| 0x030 | IRQ | W1C | 8 IRQ flags [7:0] |
| 0x034 | IRQ_FORCE | WO | Force-set IRQ flags [7:0] |
| 0x038 | (reserved) | — | INPUT_SYNC_BYPASS (Phase 2) |
| 0x03C | DBG_PADOUT | RO | Current pin output values [31:0] |
| 0x040 | DBG_PADOE | RO | Current pin output enable [31:0] |
| 0x044 | DBG_CFGINFO | RO | FIFO_DEPTH[5:0], SM_COUNT[11:8], IMEM_SIZE[21:16] |

#### CTRL (0x000)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 3:0 | SM_EN | RW | State machine enable (1 bit per SM) |
| 7:4 | SM_RESTART | W1S | Reset SM state (PC, registers, shift counters). Self-clearing. |
| 11:8 | CLKDIV_RESTART | W1S | Reset clock divider phase. Self-clearing. |

#### FSTAT (0x004)

| Bits | Name | Description |
|------|------|-------------|
| 3:0 | RXFULL | RX FIFO full (1 bit per SM) |
| 11:8 | RXEMPTY | RX FIFO empty (1 bit per SM) |
| 19:16 | TXFULL | TX FIFO full (1 bit per SM) |
| 27:24 | TXEMPTY | TX FIFO empty (1 bit per SM) |

#### IRQ (0x030)

8 flags, directly set/cleared by PIO programs. CPU interrupt output:

```
irq_o = |irq_flags | (dma_done & DONE_IE)
```

No enable mask — software reads the register to determine which flag fired, writes 1 to clear.

#### DBG_CFGINFO (0x044)

| Bits | Name | Value | Description |
|------|------|-------|-------------|
| 5:0 | FIFO_DEPTH | 4 | Words per FIFO |
| 11:8 | SM_COUNT | 4 | Number of state machines |
| 21:16 | IMEM_SIZE | 32 | Instruction memory entries |

### Instruction Memory (0x048 - 0x0C4)

32 write-only registers, one per instruction slot:

| Offset | Name |
|--------|------|
| 0x048 | INSTR_MEM0 |
| 0x04C | INSTR_MEM1 |
| ... | ... |
| 0x0C4 | INSTR_MEM31 |

Only bits [15:0] are used. Write all instructions before enabling state machines.

### Per-SM Registers

Stride: 0x20 (32 bytes). Base offsets:

| SM | Base Offset |
|----|-------------|
| SM0 | 0x0C8 |
| SM1 | 0x0E8 |
| SM2 | 0x108 |
| SM3 | 0x128 |

Address decode: `sm_idx = addr[6:5]`

#### SMn_CLKDIV (+0x00)

| Bits | Name | Description |
|------|------|-------------|
| 31:16 | INT | Integer clock divider (0 and 1 both mean divide-by-1) |
| 15:8 | FRAC | Fractional divider (reserved — Phase 2, reads 0) |

#### SMn_EXECCTRL (+0x04)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 31 | EXEC_STALLED | RO | SM is stalled |
| 30 | SIDE_EN | RW | Reserved (Phase 2) |
| 29 | SIDE_PINDIR | RW | Reserved (Phase 2) |
| 28:24 | JMP_PIN | RW | GPIO number for JMP PIN condition |
| 16:12 | WRAP_TOP | RW | PC wraps from this address (default 31) |
| 11:7 | WRAP_BOTTOM | RW | PC wraps to this address (default 0) |

#### SMn_SHIFTCTRL (+0x08)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 31 | FJOIN_RX | RW | Reserved (Phase 2) |
| 30 | FJOIN_TX | RW | Reserved (Phase 2) |
| 29:25 | PULL_THRESH | RW | Autopull threshold (0 = 32 bits) |
| 24:20 | PUSH_THRESH | RW | Autopush threshold (0 = 32 bits) |
| 19 | OUT_SHIFTDIR | RW | OUT shifts right (1) or left (0) |
| 18 | IN_SHIFTDIR | RW | IN shifts right (1) or left (0) |
| 17 | AUTOPULL | RW | Enable automatic pull from TX FIFO |
| 16 | AUTOPUSH | RW | Enable automatic push to RX FIFO |

#### SMn_ADDR (+0x0C)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 4:0 | PC | RO | Current program counter value |

#### SMn_INSTR (+0x10)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 15:0 | INSTR | RW | Read: current executing instruction. Write: force-execute instruction on next tick. |

#### SMn_PINCTRL (+0x14)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 31:29 | SIDESET_COUNT | RW | Number of side-set pins (0-5) |
| 28:26 | SET_COUNT | RW | Number of SET pins (0-5) |
| 25:20 | OUT_COUNT | RW | Number of OUT pins (0-32) |
| 19:15 | IN_BASE | RW | IN pin group base GPIO number |
| 14:10 | SIDESET_BASE | RW | Side-set base GPIO number |
| 9:5 | SET_BASE | RW | SET base GPIO number |
| 4:0 | OUT_BASE | RW | OUT base GPIO number |

Pin groups wrap around at pin 31 (e.g., `OUT_BASE=30`, `OUT_COUNT=4` drives pins 30, 31, 0, 1).

### GPIO Compatibility Registers

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x148 | GPIO_DIR | RW | Pin direction (0=input, 1=output) [31:0] |
| 0x14C | GPIO_OUT | RW | Pin output value [31:0] |
| 0x150 | GPIO_IN | RO | Sampled pin input (after 2-FF sync) [31:0] |

GPIO compat registers control pins not claimed by any enabled SM. Both GPIO_DIR and GPIO_OUT support byte enables for partial writes.

> **Note:** The original GPIO's IRQ_EN and IRQ_STATUS registers are removed. Edge detection is implemented via PIO programs using `WAIT GPIO` + `IRQ SET`.

### DMA Control Registers

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| 0x154 | DMA_CTRL | RW | DMA control (see below) |
| 0x158 | DMA_ADDR | RW | Memory address (source for TX, destination for RX) |

#### DMA_CTRL (0x154)

| Bits | Name | Access | Description |
|------|------|--------|-------------|
| 0 | GO | W1S | Start DMA transfer |
| 1 | BUSY | RO | Transfer in progress |
| 2 | DONE | RO/W1C | Transfer complete (write 1 to clear) |
| 3 | DIR | RW | 0 = TX (memory → FIFO), 1 = RX (FIFO → memory) |
| 5:4 | SM_SEL | RW | Target state machine (0-3) |
| 21:6 | LEN | RW | Transfer length in words |
| 31 | DONE_IE | RW | Enable DONE interrupt (merged into irq_o) |

The DMA FSM stalls when the target FIFO is full (TX direction) or empty (RX direction), naturally throttling to match the SM's rate. Throughput is approximately 3 system clock cycles per word.

---

## Programming Guide

### Basic Setup Sequence

```c
// 1. Disable all SMs
DEV_WRITE(PIO_CTRL, 0);

// 2. Load program into instruction memory
DEV_WRITE(PIO_INSTR_MEM0, instr0);
DEV_WRITE(PIO_INSTR_MEM1, instr1);
// ...

// 3. Configure SM0
DEV_WRITE(PIO_SM0_CLKDIV,   (10 << 16));        // divide by 10
DEV_WRITE(PIO_SM0_PINCTRL,  (1 << 26) |          // SET_COUNT=1
                             (0 << 5));            // SET_BASE=pin 0
DEV_WRITE(PIO_SM0_EXECCTRL, (wrap_top << 12) |
                             (wrap_bottom << 7));
DEV_WRITE(PIO_SM0_SHIFTCTRL, 0);                 // defaults

// 4. Force-execute SET PINDIRS to configure pin directions
DEV_WRITE(PIO_SM0_INSTR, 0xE081);  // SET PINDIRS, 1

// 5. Enable SM0
DEV_WRITE(PIO_CTRL, 0x1);  // SM_EN bit 0
```

### Pin Toggle Example

This 3-instruction program toggles a pin at half the SM clock rate:

```
.program blink
    set pins, 1      ; Drive pin high
    set pins, 0      ; Drive pin low
    jmp 0             ; Loop back
```

Instruction encoding:
```c
// SET PINS, 1  →  111 00000 000 00001  →  0xE001
// SET PINS, 0  →  111 00000 000 00000  →  0xE000
// JMP 0        →  000 00000 000 00000  →  0x0000
```

### TX FIFO Output Example

This program pulls 32-bit words from the TX FIFO and shifts them out 1 bit at a time:

```
.program serial_tx
    pull block        ; Wait for data in TX FIFO → OSR
    set x, 31         ; Bit counter
bitloop:
    out pins, 1       ; Shift one bit to pin
    jmp x-- bitloop   ; Loop 32 times
```

### Using DMA

```c
// Buffer in memory
uint32_t tx_data[64] = { ... };

// Configure DMA: TX direction, SM0, 64 words
DEV_WRITE(PIO_DMA_ADDR, (uint32_t)tx_data);
DEV_WRITE(PIO_DMA_CTRL, (64 << 6) |   // LEN=64
                         (0 << 4)  |   // SM_SEL=0
                         (0 << 3)  |   // DIR=TX
                         (1 << 0));    // GO

// Poll for completion
while (!(DEV_READ(PIO_DMA_CTRL, 0) & 0x4))
    ;  // wait for DONE
```

### IRQ Synchronization Between SMs

SM0 produces data, SM1 consumes it, synchronized via IRQ flag 0:

```
; SM0 program (producer)
    ; ... produce data ...
    irq set 0         ; Signal SM1
    irq wait 1        ; Wait for SM1 acknowledgment

; SM1 program (consumer)
    wait irq 0        ; Wait for SM0 signal
    ; ... consume data ...
    irq set 1         ; Acknowledge
```

### GPIO Compatibility

For simple pin control without PIO programs, use GPIO compat registers:

```c
// Set pins 0-7 as output
DEV_WRITE(PIO_GPIO_DIR, 0xFF);

// Write pattern
DEV_WRITE(PIO_GPIO_OUT, 0xA5);

// Read input pins
uint32_t pins = DEV_READ(PIO_GPIO_IN, 0);
```

GPIO compat registers only control pins not driven by any enabled SM.

---

## C Header Definitions

The following defines will be added to `sw/include/opensoc_regs.h`:

```c
// ---------------------------------------------------------------------------
// PIO (0x50000) — replaces GPIO
// ---------------------------------------------------------------------------
#define PIO_BASE        0x50000

// Global registers
#define PIO_CTRL        (PIO_BASE + 0x000)
#define PIO_FSTAT       (PIO_BASE + 0x004)
#define PIO_TXF0        (PIO_BASE + 0x010)
#define PIO_TXF1        (PIO_BASE + 0x014)
#define PIO_TXF2        (PIO_BASE + 0x018)
#define PIO_TXF3        (PIO_BASE + 0x01C)
#define PIO_RXF0        (PIO_BASE + 0x020)
#define PIO_RXF1        (PIO_BASE + 0x024)
#define PIO_RXF2        (PIO_BASE + 0x028)
#define PIO_RXF3        (PIO_BASE + 0x02C)
#define PIO_IRQ         (PIO_BASE + 0x030)
#define PIO_IRQ_FORCE   (PIO_BASE + 0x034)
#define PIO_DBG_PADOUT  (PIO_BASE + 0x03C)
#define PIO_DBG_PADOE   (PIO_BASE + 0x040)
#define PIO_DBG_CFGINFO (PIO_BASE + 0x044)

// Instruction memory (0x048 - 0x0C4)
#define PIO_INSTR_MEM0  (PIO_BASE + 0x048)
// PIO_INSTR_MEM(n) = PIO_BASE + 0x048 + (n * 4), n = 0..31

// Per-SM registers (stride = 0x20)
#define PIO_SM0_CLKDIV    (PIO_BASE + 0x0C8)
#define PIO_SM0_EXECCTRL  (PIO_BASE + 0x0CC)
#define PIO_SM0_SHIFTCTRL (PIO_BASE + 0x0D0)
#define PIO_SM0_ADDR      (PIO_BASE + 0x0D4)
#define PIO_SM0_INSTR     (PIO_BASE + 0x0D8)
#define PIO_SM0_PINCTRL   (PIO_BASE + 0x0DC)
// SM1 at +0x20, SM2 at +0x40, SM3 at +0x60

// GPIO compatibility
#define PIO_GPIO_DIR    (PIO_BASE + 0x148)
#define PIO_GPIO_OUT    (PIO_BASE + 0x14C)
#define PIO_GPIO_IN     (PIO_BASE + 0x150)

// DMA
#define PIO_DMA_CTRL    (PIO_BASE + 0x154)
#define PIO_DMA_ADDR    (PIO_BASE + 0x158)

// CTRL bits
#define PIO_CTRL_SM0_EN       (1 << 0)
#define PIO_CTRL_SM1_EN       (1 << 1)
#define PIO_CTRL_SM2_EN       (1 << 2)
#define PIO_CTRL_SM3_EN       (1 << 3)
#define PIO_CTRL_SM0_RESTART  (1 << 4)
#define PIO_CTRL_SM1_RESTART  (1 << 5)
#define PIO_CTRL_SM2_RESTART  (1 << 6)
#define PIO_CTRL_SM3_RESTART  (1 << 7)

// FSTAT bits
#define PIO_FSTAT_RXFULL(sm)   (1 << (0 + (sm)))
#define PIO_FSTAT_RXEMPTY(sm)  (1 << (8 + (sm)))
#define PIO_FSTAT_TXFULL(sm)   (1 << (16 + (sm)))
#define PIO_FSTAT_TXEMPTY(sm)  (1 << (24 + (sm)))

// DMA_CTRL bits
#define PIO_DMA_GO        (1 << 0)
#define PIO_DMA_BUSY      (1 << 1)
#define PIO_DMA_DONE      (1 << 2)
#define PIO_DMA_DIR_RX    (1 << 3)
#define PIO_DMA_DONE_IE   (1 << 31)

// IRQ assignment
#define IRQ_PIO    1   // replaces IRQ_GPIO
```

---

## Interrupt Behavior

The PIO asserts a single interrupt to the Ibex core on `irq_fast_i[1]` (replacing GPIO):

```
irq_o = |irq_flags[7:0] | (dma_done & DONE_IE)
```

The CPU ISR should:
1. Read `PIO_IRQ` (0x030) to identify which flags are set
2. Write 1 to clear the relevant flags
3. If using DMA, check `DMA_CTRL.DONE` and write 1 to clear

There is no per-flag interrupt enable mask. Software ignores flags it doesn't use.

---

## File Structure

```
hw/ip/pio/
├── pio.core              — FuseSoC core file (opensoc:ip:pio)
└── rtl/
    ├── pio.sv            — Top-level: registers, FIFOs, pin mux, DMA FSM
    └── pio_sm.sv         — State machine engine: PC, decoder, shift regs
```

---

## Phase 2 Features (reserved, not implemented)

The following register fields and features exist in the register map but are reserved:

| Feature | Register | Status |
|---------|----------|--------|
| Fractional clock divider | SMn_CLKDIV[15:8] | Reads 0 |
| FIFO join mode | SMn_SHIFTCTRL[31:30] | Ignored |
| Input sync bypass | 0x038 | Reserved |
| SIDE_EN / SIDE_PINDIR | SMn_EXECCTRL[30:29] | Ignored |
| MOV bit-reverse | MOV op=10 | Returns input unchanged |
| OUT/MOV EXEC destination | OUT/MOV dst=EXEC | No effect |
| STATUS source | SMn_EXECCTRL[4:0] | STATUS returns 0 |
| FDEBUG | 0x008 | Reads 0 |
| FLEVEL | 0x00C | Reads 0 |
