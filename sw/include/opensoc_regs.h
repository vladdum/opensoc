// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENSOC_REGS_H__
#define OPENSOC_REGS_H__

// ===========================================================================
// OpenSoC Unified Register Map
// ===========================================================================

// ---------------------------------------------------------------------------
// Memory Map — Base Addresses
// ---------------------------------------------------------------------------
// SIM_CTRL_BASE (0x40000000) and TIMER_BASE (0x40010000) are defined in
// sw/common/simple_system_regs.h, which shadows the ibex version.
#define RAM_BASE        0x20000000UL
#define UART_BASE       0x40020000UL
#define PIO_BASE        0x40030000UL
#define I2C_BASE        0x40040000UL
#define RELU_BASE       0x40050000UL
#define VMAC_BASE       0x40060000UL
#define SGDMA_BASE      0x40070000UL
#define SMAX_BASE       0x40080000UL
#define CONV1D_BASE     0x40090000UL
#define CONV2D_BASE     0x400A0000UL
#define GEMM_BASE       0x400B0000UL
#define CRYPTO_BASE     0x40100000UL

// SIM_CTRL_BASE and TIMER_BASE are defined in sw/common/simple_system_regs.h.

// ---------------------------------------------------------------------------
// UART (0x40000)
// ---------------------------------------------------------------------------
#define UART_THR        (UART_BASE + 0x00)  // TX holding register (write)
#define UART_RBR        (UART_BASE + 0x00)  // RX buffer register (read)
#define UART_LSR        (UART_BASE + 0x04)  // Line status register
#define UART_IER        (UART_BASE + 0x08)  // Interrupt enable register
#define UART_DIV        (UART_BASE + 0x0C)  // Baud rate divisor

#define UART_LSR_TX_READY  (1 << 0)
#define UART_LSR_RX_READY  (1 << 1)

// ---------------------------------------------------------------------------
// PIO (0x40030000) — Programmable I/O block (replaces GPIO)
// ---------------------------------------------------------------------------
#define PIO_CTRL        (PIO_BASE + 0x000)  // SM enable[3:0], restart[7:4], clkdiv_restart[11:8]
#define PIO_FSTAT       (PIO_BASE + 0x004)  // FIFO status (TX empty/full, RX empty/full)
#define PIO_TXF0        (PIO_BASE + 0x010)  // TX FIFO SM0 (write)
#define PIO_TXF1        (PIO_BASE + 0x014)  // TX FIFO SM1 (write)
#define PIO_TXF2        (PIO_BASE + 0x018)  // TX FIFO SM2 (write)
#define PIO_TXF3        (PIO_BASE + 0x01C)  // TX FIFO SM3 (write)
#define PIO_RXF0        (PIO_BASE + 0x020)  // RX FIFO SM0 (read)
#define PIO_RXF1        (PIO_BASE + 0x024)  // RX FIFO SM1 (read)
#define PIO_RXF2        (PIO_BASE + 0x028)  // RX FIFO SM2 (read)
#define PIO_RXF3        (PIO_BASE + 0x02C)  // RX FIFO SM3 (read)
#define PIO_IRQ         (PIO_BASE + 0x030)  // IRQ flags (W1C)
#define PIO_IRQ_FORCE   (PIO_BASE + 0x034)  // IRQ force (W1S)
#define PIO_DBG_PADOUT  (PIO_BASE + 0x03C)  // Debug: pin output state
#define PIO_DBG_PADOE   (PIO_BASE + 0x040)  // Debug: pin OE state
#define PIO_DBG_CFGINFO (PIO_BASE + 0x044)  // Debug: config info
#define PIO_INSTR_MEM0  (PIO_BASE + 0x048)  // Instruction memory [0]
// INSTR_MEM[n] = PIO_BASE + 0x048 + n*4 (n=0..31)

// Per-SM registers: base = PIO_BASE + 0x0C8 + sm*0x20
#define PIO_SM0_BASE    (PIO_BASE + 0x0C8)
#define PIO_SM_STRIDE   0x20
#define PIO_SM_CLKDIV(sm)    (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x00)
#define PIO_SM_EXECCTRL(sm)  (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x04)
#define PIO_SM_SHIFTCTRL(sm) (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x08)
#define PIO_SM_ADDR(sm)      (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x0C)
#define PIO_SM_INSTR(sm)     (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x10)
#define PIO_SM_PINCTRL(sm)   (PIO_SM0_BASE + (sm)*PIO_SM_STRIDE + 0x14)

// GPIO-compatible registers
#define PIO_GPIO_DIR    (PIO_BASE + 0x148)  // Direction (1=output)
#define PIO_GPIO_OUT    (PIO_BASE + 0x14C)  // Output data
#define PIO_GPIO_IN     (PIO_BASE + 0x150)  // Input data (read-only)

// DMA registers
#define PIO_DMA_CTRL    (PIO_BASE + 0x154)  // DMA control: GO[0], BUSY[1], DONE[2], DIR[3], SM[5:4], LEN[21:6], IE[31]
#define PIO_DMA_ADDR    (PIO_BASE + 0x158)  // DMA base address

// PIO instruction operand constants (named alternatives to magic numbers)
// JMP conditions (bits 7:5)
#define PIO_JMP_ALWAYS    0  // Unconditional
#define PIO_JMP_NOT_X     1  // !X (X is zero)
#define PIO_JMP_X_DEC     2  // X-- (post-decrement, jump if old X nonzero)
#define PIO_JMP_NOT_Y     3  // !Y (Y is zero)
#define PIO_JMP_Y_DEC     4  // Y-- (post-decrement, jump if old Y nonzero)
#define PIO_JMP_X_NE_Y    5  // X != Y
#define PIO_JMP_PIN       6  // Input pin
#define PIO_JMP_NOT_OSRE  7  // !OSRE (output shift register not empty)

// IN sources / OUT destinations / MOV sources & destinations / SET destinations
#define PIO_PINS      0  // IN src, OUT dst, SET dst, MOV src/dst
#define PIO_X         1  // IN src, OUT dst, SET dst, MOV src/dst
#define PIO_Y         2  // IN src, OUT dst, SET dst, MOV src/dst
#define PIO_NULL      3  // IN src, OUT dst
#define PIO_PINDIRS   4  // OUT dst, SET dst
#define PIO_EXEC_MOV  4  // MOV dst only (execute shifted value)
#define PIO_STATUS    5  // MOV src only
#define PIO_PC        5  // OUT dst, MOV dst
#define PIO_ISR       6  // IN src, OUT dst, MOV src/dst
#define PIO_OSR       7  // IN src, MOV src/dst
#define PIO_EXEC_OUT  7  // OUT dst only (execute shifted value)

// MOV operations (bits 4:3)
#define PIO_MOV_OP_NONE    0  // No operation
#define PIO_MOV_OP_INVERT  1  // Bitwise invert
#define PIO_MOV_OP_REVERSE 2  // Bit-reverse

// WAIT sources (bits 6:5)
#define PIO_WAIT_GPIO  0  // Absolute GPIO number
#define PIO_WAIT_PIN   1  // Relative to IN_BASE
#define PIO_WAIT_IRQ   2  // IRQ flag

// PIO instruction encoding helpers
#define PIO_INSTR_JMP(cond, addr)         (((0) << 13) | ((cond) << 5) | (addr))
#define PIO_INSTR_WAIT(pol, src, idx)     (((1) << 13) | ((pol) << 7) | ((src) << 5) | (idx))
#define PIO_INSTR_IN(src, cnt)            (((2) << 13) | ((src) << 5) | (cnt))
#define PIO_INSTR_OUT(dst, cnt)           (((3) << 13) | ((dst) << 5) | (cnt))
#define PIO_INSTR_PUSH(if_f, blk)         (((4) << 13) | ((if_f) << 6) | ((blk) << 5))
#define PIO_INSTR_PULL(if_e, blk)         (((4) << 13) | (1 << 7) | ((if_e) << 6) | ((blk) << 5))
#define PIO_INSTR_MOV(dst, op, src)       (((5) << 13) | ((dst) << 5) | ((op) << 3) | (src))
#define PIO_INSTR_IRQ(wait, clr, idx)     (((6) << 13) | ((wait) << 6) | ((clr) << 5) | (idx))
#define PIO_INSTR_SET(dst, data)          (((7) << 13) | ((dst) << 5) | (data))
#define PIO_INSTR_NOP                     PIO_INSTR_MOV(0, 0, 0)  // MOV PINS, PINS (no-op equivalent)

// With delay: OR in (delay << 8) to any instruction
#define PIO_DELAY(instr, d)               ((instr) | ((d) << 8))

// FSTAT bit positions
#define PIO_FSTAT_TX_EMPTY(sm)  (1 << (24 + (sm)))
#define PIO_FSTAT_TX_FULL(sm)   (1 << (16 + (sm)))
#define PIO_FSTAT_RX_EMPTY(sm)  (1 << (8  + (sm)))
#define PIO_FSTAT_RX_FULL(sm)   (1 << (0  + (sm)))

// Legacy GPIO compatibility (same bus address, different register offsets)
#define GPIO_DIR        PIO_GPIO_DIR
#define GPIO_OUT        PIO_GPIO_OUT
#define GPIO_IN         PIO_GPIO_IN

// ---------------------------------------------------------------------------
// I2C Controller (0x60000)
// ---------------------------------------------------------------------------
#define I2C_CTRL        (I2C_BASE + 0x00)
#define I2C_STATUS      (I2C_BASE + 0x04)
#define I2C_TX_DATA     (I2C_BASE + 0x08)
#define I2C_RX_DATA     (I2C_BASE + 0x0C)
#define I2C_PRESCALE    (I2C_BASE + 0x10)
#define I2C_IER         (I2C_BASE + 0x14)

#define I2C_CTRL_START    (1 << 0)
#define I2C_CTRL_STOP     (1 << 1)
#define I2C_CTRL_RW       (1 << 2)  // 1=read, 0=write
#define I2C_CTRL_ACK_EN   (1 << 3)

#define I2C_STATUS_BUSY     (1 << 0)
#define I2C_STATUS_ACK      (1 << 1)
#define I2C_STATUS_ARB_LOST (1 << 2)

// ---------------------------------------------------------------------------
// ReLU Accelerator (0x70000)
// ---------------------------------------------------------------------------
#define RELU_SRC_ADDR   (RELU_BASE + 0x00)
#define RELU_DST_ADDR   (RELU_BASE + 0x04)
#define RELU_LEN        (RELU_BASE + 0x08)
#define RELU_CTRL       (RELU_BASE + 0x0C)
#define RELU_STATUS     (RELU_BASE + 0x10)
#define RELU_IER        (RELU_BASE + 0x14)

#define RELU_CTRL_GO          0x1
#define RELU_CTRL_STREAM_MODE 0x4
#define RELU_STATUS_BUSY      0x1
#define RELU_STATUS_DONE      0x2

// ---------------------------------------------------------------------------
// Vector MAC Accelerator (0x80000)
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// Scatter-Gather DMA Engine (0x90000)
// ---------------------------------------------------------------------------
#define SGDMA_DESC_ADDR     (SGDMA_BASE + 0x00)
#define SGDMA_CTRL          (SGDMA_BASE + 0x04)
#define SGDMA_STATUS        (SGDMA_BASE + 0x08)
#define SGDMA_IER           (SGDMA_BASE + 0x0C)
#define SGDMA_COMPLETED_CNT (SGDMA_BASE + 0x10)
#define SGDMA_ACTIVE_SRC    (SGDMA_BASE + 0x14)
#define SGDMA_ACTIVE_DST    (SGDMA_BASE + 0x18)
#define SGDMA_ACTIVE_LEN    (SGDMA_BASE + 0x1C)

#define SGDMA_CTRL_GO       0x1
#define SGDMA_STATUS_BUSY   0x1
#define SGDMA_STATUS_DONE   0x2

#define SGDMA_DESC_CTRL_IRQ_ON_DONE 0x1
#define SGDMA_DESC_CTRL_CHAIN       0x2

// ---------------------------------------------------------------------------
// Softmax Pipeline (0xA0000)
// ---------------------------------------------------------------------------
#define SMAX_CTRL      (SMAX_BASE + 0x00)
#define SMAX_STATUS    (SMAX_BASE + 0x04)
#define SMAX_SRC_ADDR  (SMAX_BASE + 0x08)
#define SMAX_DST_ADDR  (SMAX_BASE + 0x0C)
#define SMAX_VEC_LEN   (SMAX_BASE + 0x10)
#define SMAX_IER       (SMAX_BASE + 0x14)
#define SMAX_MAX_VAL   (SMAX_BASE + 0x18)
#define SMAX_SUM_VAL   (SMAX_BASE + 0x1C)

#define SMAX_CTRL_GO      0x1
#define SMAX_STATUS_BUSY  0x1
#define SMAX_STATUS_DONE  0x2

// ---------------------------------------------------------------------------
// 1D Convolution Engine (0x40090000)
// ---------------------------------------------------------------------------
#define CONV1D_CTRL         (CONV1D_BASE + 0x00)
#define CONV1D_STATUS       (CONV1D_BASE + 0x04)
#define CONV1D_SRC_ADDR     (CONV1D_BASE + 0x08)
#define CONV1D_DST_ADDR     (CONV1D_BASE + 0x0C)
#define CONV1D_LENGTH       (CONV1D_BASE + 0x10)
#define CONV1D_IER          (CONV1D_BASE + 0x14)
#define CONV1D_KERNEL_SIZE  (CONV1D_BASE + 0x18)
#define CONV1D_PADDING_MODE (CONV1D_BASE + 0x1C)
#define CONV1D_KERNEL_W(n)  (CONV1D_BASE + 0x20 + (n) * 4)

#define CONV1D_CTRL_GO           0x1
#define CONV1D_CTRL_SOFT_RESET   0x2
#define CONV1D_CTRL_STREAM_MODE  0x4

#define CONV1D_STATUS_BUSY  0x1
#define CONV1D_STATUS_DONE  0x2

#define CONV1D_IER_DONE     0x1

#define CONV1D_PAD_VALID    0x0
#define CONV1D_PAD_SAME     0x3

// ---------------------------------------------------------------------------
// 2D Convolution Engine (0x400B0000)
// ---------------------------------------------------------------------------
#define CONV2D_CTRL          (CONV2D_BASE + 0x00)
#define CONV2D_STATUS        (CONV2D_BASE + 0x04)
#define CONV2D_SRC_ADDR      (CONV2D_BASE + 0x08)
#define CONV2D_DST_ADDR      (CONV2D_BASE + 0x0C)
#define CONV2D_IER           (CONV2D_BASE + 0x14)
#define CONV2D_IMG_WIDTH     (CONV2D_BASE + 0x18)
#define CONV2D_IMG_HEIGHT    (CONV2D_BASE + 0x1C)
#define CONV2D_KERNEL_SIZE   (CONV2D_BASE + 0x20)
#define CONV2D_PADDING_MODE  (CONV2D_BASE + 0x24)
#define CONV2D_KERNEL_W(n)   (CONV2D_BASE + 0x28 + (n) * 4)

#define CONV2D_CTRL_GO          0x1
#define CONV2D_CTRL_SOFT_RESET  0x2

#define CONV2D_STATUS_BUSY  0x1
#define CONV2D_STATUS_DONE  0x2

#define CONV2D_IER_DONE     0x1

#define CONV2D_PAD_VALID    0x0
#define CONV2D_PAD_SAME     0x1

// ---------------------------------------------------------------------------
// GEMM Accelerator (0x400C0000)
// ---------------------------------------------------------------------------
#define GEMM_CTRL          (GEMM_BASE + 0x00)
#define GEMM_STATUS        (GEMM_BASE + 0x04)
#define GEMM_SRC_ADDR      (GEMM_BASE + 0x08)  // A matrix base address
#define GEMM_DST_ADDR      (GEMM_BASE + 0x0C)  // C matrix base address
#define GEMM_IER           (GEMM_BASE + 0x14)
#define GEMM_MAT_M         (GEMM_BASE + 0x18)  // A rows
#define GEMM_MAT_K         (GEMM_BASE + 0x1C)  // A cols = B rows
#define GEMM_MAT_N         (GEMM_BASE + 0x20)  // B cols
#define GEMM_WEIGHT_ADDR   (GEMM_BASE + 0x24)  // PE select: k[5:3], n[2:0]
#define GEMM_WEIGHT_DATA   (GEMM_BASE + 0x28)  // INT8 weight value
#define GEMM_ARRAY_SIZE    (GEMM_BASE + 0x2C)  // R/O: [15:8]=ARRAY_M, [7:0]=ARRAY_N

#define GEMM_CTRL_GO          0x1
#define GEMM_CTRL_SOFT_RESET  0x2

#define GEMM_STATUS_BUSY  0x1
#define GEMM_STATUS_DONE  0x2

#define GEMM_IER_DONE     0x1

// ---------------------------------------------------------------------------
// AES / Crypto Cluster (0x400A0000) — OpenTitan AES register map
// ---------------------------------------------------------------------------
#define AES_KEY_SHARE0(n)   (CRYPTO_BASE + 0x04 + (n)*4)  // n=0..7
#define AES_KEY_SHARE1(n)   (CRYPTO_BASE + 0x24 + (n)*4)  // n=0..7
#define AES_IV(n)           (CRYPTO_BASE + 0x44 + (n)*4)  // n=0..3
#define AES_DATA_IN(n)      (CRYPTO_BASE + 0x54 + (n)*4)  // n=0..3
#define AES_DATA_OUT(n)     (CRYPTO_BASE + 0x64 + (n)*4)  // n=0..3
#define AES_CTRL            (CRYPTO_BASE + 0x74)  // Shadowed control
#define AES_CTRL_AUX        (CRYPTO_BASE + 0x78)  // Auxiliary control
#define AES_CTRL_AUX_REGWEN (CRYPTO_BASE + 0x7C)
#define AES_TRIGGER         (CRYPTO_BASE + 0x80)
#define AES_STATUS          (CRYPTO_BASE + 0x84)

// AES_CTRL field values (write twice for shadowed register)
#define AES_OP_ENC          0x01  // bits[1:0] = 2'b01
#define AES_OP_DEC          0x02  // bits[1:0] = 2'b10
#define AES_MODE_ECB        (0x01 << 2)  // bits[7:2]
#define AES_MODE_CBC        (0x02 << 2)
#define AES_MODE_CTR        (0x04 << 2)
#define AES_KEY_128         (0x01 << 8)  // bits[10:8]
#define AES_KEY_192         (0x02 << 8)
#define AES_KEY_256         (0x04 << 8)
#define AES_MANUAL_OP       (1 << 15)    // bit 15

// AES_TRIGGER bits
#define AES_TRIGGER_START              (1 << 0)
#define AES_TRIGGER_KEY_IV_DATA_CLEAR  (1 << 1)
#define AES_TRIGGER_DATA_OUT_CLEAR     (1 << 2)
#define AES_TRIGGER_PRNG_RESEED        (1 << 3)

// AES_STATUS bits
#define AES_STATUS_IDLE          (1 << 0)
#define AES_STATUS_STALL         (1 << 1)
#define AES_STATUS_OUTPUT_LOST   (1 << 2)
#define AES_STATUS_OUTPUT_VALID  (1 << 3)
#define AES_STATUS_INPUT_READY   (1 << 4)

// ---------------------------------------------------------------------------
// IRQ assignments (irq_fast_i bit positions)
// ---------------------------------------------------------------------------
#define IRQ_UART    0
#define IRQ_PIO     1
#define IRQ_I2C     2
#define IRQ_RELU    3
#define IRQ_VMAC    4
#define IRQ_SGDMA   5
#define IRQ_SMAX    6
#define IRQ_CONV1D  7
#define IRQ_CONV2D  8
#define IRQ_GEMM    9

#endif  // OPENSOC_REGS_H__
