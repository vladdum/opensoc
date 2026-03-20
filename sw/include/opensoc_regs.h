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
// SIM_CTRL_BASE (0x20000) and TIMER_BASE (0x30000) are defined in
// simple_system_regs.h (included via simple_system_common.h).
#define UART_BASE       0x40000
#define GPIO_BASE       0x50000
#define I2C_BASE        0x60000
#define RELU_BASE       0x70000
#define VMAC_BASE       0x80000
#define SGDMA_BASE      0x90000
#define SMAX_BASE       0xA0000
#define RAM_BASE        0x100000

// Sim Control (0x20000) and Timer (0x30000) registers are in
// simple_system_regs.h — not duplicated here.

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
// GPIO (0x50000)
// ---------------------------------------------------------------------------
#define GPIO_DIR        (GPIO_BASE + 0x00)  // Direction (1=output)
#define GPIO_OUT        (GPIO_BASE + 0x04)  // Output data
#define GPIO_IN         (GPIO_BASE + 0x08)  // Input data (read-only)
#define GPIO_IRQ_EN     (GPIO_BASE + 0x0C)  // IRQ enable mask
#define GPIO_IRQ_STATUS (GPIO_BASE + 0x10)  // IRQ status (write-1-clear)

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

#define RELU_CTRL_GO        0x1
#define RELU_STATUS_BUSY    0x1
#define RELU_STATUS_DONE    0x2

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
// IRQ assignments (irq_fast_i bit positions)
// ---------------------------------------------------------------------------
#define IRQ_UART    0
#define IRQ_GPIO    1
#define IRQ_I2C     2
#define IRQ_RELU    3
#define IRQ_VMAC    4
#define IRQ_SGDMA   5
#define IRQ_SMAX    6

#endif  // OPENSOC_REGS_H__
