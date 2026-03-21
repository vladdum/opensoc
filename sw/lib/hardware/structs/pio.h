// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// PIO hardware register structs — Pico SDK compatible
// Matches RP2040 pio_hw_t layout with OpenSoC-specific stride adjustments

#ifndef HARDWARE_STRUCTS_PIO_H
#define HARDWARE_STRUCTS_PIO_H

#include <stdint.h>

// -----------------------------------------------------------------------
// Volatile I/O type aliases (Pico SDK convention)
// -----------------------------------------------------------------------
typedef volatile uint32_t io_rw_32;
typedef const volatile uint32_t io_ro_32;
typedef volatile uint32_t io_wo_32;

// -----------------------------------------------------------------------
// Per-SM register block
// RP2040 stride = 0x18 (6 regs), OpenSoC stride = 0x20 (6 regs + 2 pad)
// -----------------------------------------------------------------------
typedef struct {
    io_rw_32 clkdiv;       // +0x00  Clock divider: INT[31:16], FRAC[15:8]
    io_rw_32 execctrl;     // +0x04  Execution control
    io_rw_32 shiftctrl;    // +0x08  Shift register control
    io_ro_32 addr;         // +0x0C  Current PC [4:0]
    io_rw_32 instr;        // +0x10  Current/forced instruction [15:0]
    io_rw_32 pinctrl;      // +0x14  Pin mapping configuration
    uint32_t _pad[2];      // +0x18  Padding to 0x20 stride (OpenSoC-specific)
} pio_sm_hw_t;

// -----------------------------------------------------------------------
// PIO register block (overlaid at PIO_BASE = 0x50000)
// -----------------------------------------------------------------------
typedef struct {
    io_rw_32 ctrl;         // 0x000  SM enable[3:0], restart[7:4], clkdiv_restart[11:8]
    io_ro_32 fstat;        // 0x004  FIFO status
    io_rw_32 fdebug;       // 0x008  FIFO debug (not implemented, reads 0)
    io_ro_32 flevel;       // 0x00C  FIFO levels (not implemented, reads 0)
    io_wo_32 txf[4];       // 0x010  TX FIFO write ports [SM0..SM3]
    io_ro_32 rxf[4];       // 0x020  RX FIFO read ports [SM0..SM3]
    io_rw_32 irq;          // 0x030  IRQ flags [7:0] (W1C)
    io_wo_32 irq_force;    // 0x034  IRQ force [7:0] (W1S)
    io_rw_32 input_sync_bypass; // 0x038  Input sync bypass (not implemented, reads 0)
    io_ro_32 dbg_padout;   // 0x03C  Debug: pin output state
    io_ro_32 dbg_padoe;    // 0x040  Debug: pin output enable state
    io_ro_32 dbg_cfginfo;  // 0x044  Debug: config info
    io_wo_32 instr_mem[32]; // 0x048  Instruction memory [0..31]
    pio_sm_hw_t sm[4];     // 0x0C8  Per-SM registers (stride 0x20)
} pio_hw_t;

// -----------------------------------------------------------------------
// Register bit-field positions (_LSB) and masks (_BITS)
// Named to match Pico SDK conventions
// -----------------------------------------------------------------------

// CTRL register
#define PIO_CTRL_SM_ENABLE_LSB         0
#define PIO_CTRL_SM_ENABLE_BITS        0x0000000fu
#define PIO_CTRL_SM_RESTART_LSB        4
#define PIO_CTRL_SM_RESTART_BITS       0x000000f0u
#define PIO_CTRL_CLKDIV_RESTART_LSB    8
#define PIO_CTRL_CLKDIV_RESTART_BITS   0x00000f00u

// FSTAT register
#define PIO_FSTAT_RXFULL_LSB           0
#define PIO_FSTAT_RXFULL_BITS          0x0000000fu
#define PIO_FSTAT_RXEMPTY_LSB          8
#define PIO_FSTAT_RXEMPTY_BITS         0x00000f00u
#define PIO_FSTAT_TXFULL_LSB           16
#define PIO_FSTAT_TXFULL_BITS          0x000f0000u
#define PIO_FSTAT_TXEMPTY_LSB          24
#define PIO_FSTAT_TXEMPTY_BITS         0x0f000000u

// FDEBUG register
#define PIO_FDEBUG_RXSTALL_LSB         0
#define PIO_FDEBUG_RXUNDER_LSB         8
#define PIO_FDEBUG_TXOVER_LSB          16
#define PIO_FDEBUG_TXSTALL_LSB         24

// SM0_CLKDIV
#define PIO_SM0_CLKDIV_FRAC_LSB        8
#define PIO_SM0_CLKDIV_FRAC_BITS       0x0000ff00u
#define PIO_SM0_CLKDIV_INT_LSB         16
#define PIO_SM0_CLKDIV_INT_BITS        0xffff0000u

// SM0_EXECCTRL
#define PIO_SM0_EXECCTRL_STATUS_N_LSB         0
#define PIO_SM0_EXECCTRL_STATUS_N_BITS        0x0000000fu
#define PIO_SM0_EXECCTRL_STATUS_SEL_LSB       4
#define PIO_SM0_EXECCTRL_STATUS_SEL_BITS      0x00000010u
#define PIO_SM0_EXECCTRL_WRAP_BOTTOM_LSB      7
#define PIO_SM0_EXECCTRL_WRAP_BOTTOM_BITS     0x00000f80u
#define PIO_SM0_EXECCTRL_WRAP_TOP_LSB         12
#define PIO_SM0_EXECCTRL_WRAP_TOP_BITS        0x0001f000u
#define PIO_SM0_EXECCTRL_OUT_STICKY_LSB       17
#define PIO_SM0_EXECCTRL_OUT_STICKY_BITS      0x00020000u
#define PIO_SM0_EXECCTRL_INLINE_OUT_EN_LSB    18
#define PIO_SM0_EXECCTRL_INLINE_OUT_EN_BITS   0x00040000u
#define PIO_SM0_EXECCTRL_OUT_EN_SEL_LSB       19
#define PIO_SM0_EXECCTRL_OUT_EN_SEL_BITS      0x00f80000u
#define PIO_SM0_EXECCTRL_JMP_PIN_LSB          24
#define PIO_SM0_EXECCTRL_JMP_PIN_BITS         0x1f000000u
#define PIO_SM0_EXECCTRL_SIDE_PINDIR_LSB      29
#define PIO_SM0_EXECCTRL_SIDE_PINDIR_BITS     0x20000000u
#define PIO_SM0_EXECCTRL_SIDE_EN_LSB          30
#define PIO_SM0_EXECCTRL_SIDE_EN_BITS         0x40000000u
#define PIO_SM0_EXECCTRL_EXEC_STALLED_LSB     31
#define PIO_SM0_EXECCTRL_EXEC_STALLED_BITS    0x80000000u

// SM0_SHIFTCTRL
#define PIO_SM0_SHIFTCTRL_AUTOPUSH_LSB        16
#define PIO_SM0_SHIFTCTRL_AUTOPUSH_BITS       0x00010000u
#define PIO_SM0_SHIFTCTRL_AUTOPULL_LSB        17
#define PIO_SM0_SHIFTCTRL_AUTOPULL_BITS       0x00020000u
#define PIO_SM0_SHIFTCTRL_IN_SHIFTDIR_LSB     18
#define PIO_SM0_SHIFTCTRL_IN_SHIFTDIR_BITS    0x00040000u
#define PIO_SM0_SHIFTCTRL_OUT_SHIFTDIR_LSB    19
#define PIO_SM0_SHIFTCTRL_OUT_SHIFTDIR_BITS   0x00080000u
#define PIO_SM0_SHIFTCTRL_PUSH_THRESH_LSB     20
#define PIO_SM0_SHIFTCTRL_PUSH_THRESH_BITS    0x01f00000u
#define PIO_SM0_SHIFTCTRL_PULL_THRESH_LSB     25
#define PIO_SM0_SHIFTCTRL_PULL_THRESH_BITS    0x3e000000u
#define PIO_SM0_SHIFTCTRL_FJOIN_TX_LSB        30
#define PIO_SM0_SHIFTCTRL_FJOIN_TX_BITS       0x40000000u
#define PIO_SM0_SHIFTCTRL_FJOIN_RX_LSB        31
#define PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS       0x80000000u

// SM0_PINCTRL
#define PIO_SM0_PINCTRL_OUT_BASE_LSB          0
#define PIO_SM0_PINCTRL_OUT_BASE_BITS         0x0000001fu
#define PIO_SM0_PINCTRL_SET_BASE_LSB          5
#define PIO_SM0_PINCTRL_SET_BASE_BITS         0x000003e0u
#define PIO_SM0_PINCTRL_SIDESET_BASE_LSB      10
#define PIO_SM0_PINCTRL_SIDESET_BASE_BITS     0x00007c00u
#define PIO_SM0_PINCTRL_IN_BASE_LSB           15
#define PIO_SM0_PINCTRL_IN_BASE_BITS          0x000f8000u
#define PIO_SM0_PINCTRL_OUT_COUNT_LSB         20
#define PIO_SM0_PINCTRL_OUT_COUNT_BITS        0x03f00000u
#define PIO_SM0_PINCTRL_SET_COUNT_LSB         26
#define PIO_SM0_PINCTRL_SET_COUNT_BITS        0x1c000000u
#define PIO_SM0_PINCTRL_SIDESET_COUNT_LSB     29
#define PIO_SM0_PINCTRL_SIDESET_COUNT_BITS    0xe0000000u

#endif // HARDWARE_STRUCTS_PIO_H
