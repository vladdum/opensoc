// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * PIO Block Test
 *
 * Exercises the Programmable I/O block:
 *  1. GPIO compat: DIR/OUT/IN register access
 *  2. DBG_CFGINFO readback
 *  3. Instruction memory write/execute
 *  4. SET PINS instruction
 *  5. FIFO write+read (TX→SM PULL→RX PUSH→CPU read)
 *  6. Clock divider
 *  7. JMP always
 *  8. JMP X-- decrement loop
 *  9. MOV X, Y
 * 10. FSTAT register
 * 11. IRQ set/clear
 * 12. WAIT GPIO instruction
 * 13. SM restart
 * 14. Forced instruction execution
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"
#include <stdint.h>

static int test_num = 0;
static int total_errors = 0;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void putdec(uint32_t v) {
  char buf[11];
  int pos = 0;
  if (v == 0) { putchar('0'); return; }
  while (v > 0) {
    buf[pos++] = '0' + (v % 10);
    v /= 10;
  }
  while (pos > 0) putchar(buf[--pos]);
}

static void puthex(uint32_t v) {
  const char hex[] = "0123456789ABCDEF";
  puts("0x");
  for (int i = 28; i >= 0; i -= 4)
    putchar(hex[(v >> i) & 0xF]);
}

static void check(const char *name, uint32_t got, uint32_t expected) {
  test_num++;
  if (got == expected) {
    puts("  PASS #");
    putdec(test_num);
    puts(": ");
    puts(name);
    putchar('\n');
  } else {
    puts("  FAIL #");
    putdec(test_num);
    puts(": ");
    puts(name);
    puts(" — got ");
    puthex(got);
    puts(" expected ");
    puthex(expected);
    putchar('\n');
    total_errors++;
  }
}

// Spin wait N cycles (approximate)
static void spin(int n) {
  for (volatile int i = 0; i < n; i++) ;
}

// Write a PIO instruction to instruction memory
static void pio_write_instr(int idx, uint16_t instr) {
  DEV_WRITE(PIO_INSTR_MEM0 + idx * 4, (uint32_t)instr);
}

// Disable all SMs, clear state
static void pio_reset(void) {
  DEV_WRITE(PIO_CTRL, 0);          // disable all SMs
  DEV_WRITE(PIO_CTRL, 0xF0);       // restart all SMs (bits [7:4])
  spin(4);
  DEV_WRITE(PIO_CTRL, 0);          // clear restart bits
}

// Enable SM n
static void pio_enable_sm(int sm) {
  uint32_t ctrl = DEV_READ(PIO_CTRL, 0);
  DEV_WRITE(PIO_CTRL, ctrl | (1u << sm));
}

// Disable SM n
static void pio_disable_sm(int sm) {
  uint32_t ctrl = DEV_READ(PIO_CTRL, 0);
  DEV_WRITE(PIO_CTRL, ctrl & ~(1u << sm));
}

// ---------------------------------------------------------------------------
// Test 1: GPIO compatibility — DIR/OUT registers
// ---------------------------------------------------------------------------
static void test_gpio_compat(void) {
  pio_reset();

  // Write direction and output
  DEV_WRITE(PIO_GPIO_DIR, 0x000000FF);
  DEV_WRITE(PIO_GPIO_OUT, 0x000000A5);

  uint32_t dir = DEV_READ(PIO_GPIO_DIR, 0);
  uint32_t out = DEV_READ(PIO_GPIO_OUT, 0);

  check("GPIO DIR readback", dir, 0x000000FF);
  check("GPIO OUT readback", out, 0x000000A5);
}

// ---------------------------------------------------------------------------
// Test 2: DBG_CFGINFO
// ---------------------------------------------------------------------------
static void test_cfginfo(void) {
  uint32_t info = DEV_READ(PIO_DBG_CFGINFO, 0);
  // Layout: [21:16]=ImemSize(32), [11:8]=NumSm(4), [5:0]=FifoDepth(4)
  uint32_t imem_size  = (info >> 16) & 0x3F;
  uint32_t num_sm     = (info >> 8)  & 0xF;
  uint32_t fifo_depth = info & 0x3F;

  check("CFGINFO imem_size=32", imem_size, 32);
  check("CFGINFO num_sm=4",     num_sm,     4);
  check("CFGINFO fifo_depth=4", fifo_depth, 4);
}

// ---------------------------------------------------------------------------
// Test 3: SET PINS instruction — write to pin output via SM
// ---------------------------------------------------------------------------
static void test_set_pins(void) {
  pio_reset();

  // Configure SM0: SET_BASE=0, SET_COUNT=5, OUT_BASE=0, OUT_COUNT=0
  // pinctrl: [31:29]=sideset_count, [28:26]=set_count, [25:20]=out_count,
  //          [19:15]=in_base, [14:10]=sideset_base, [9:5]=set_base, [4:0]=out_base
  uint32_t pinctrl = (5 << 26);  // set_count=5, all bases=0
  DEV_WRITE(PIO_SM_PINCTRL(0), pinctrl);

  // Instruction 0: SET PINS, 0x15 (= 10101 in 5 bits = 21)
  pio_write_instr(0, PIO_INSTR_SET(0, 21));   // SET PINS, 21
  // Instruction 1: JMP 1 (spin forever)
  pio_write_instr(1, PIO_INSTR_JMP(0, 1));

  // Enable SM0 OE for pins [4:0] via SET PINDIRS
  // First set OE: SET PINDIRS, 0x1F (all 5 pins as output)
  pio_write_instr(2, PIO_INSTR_SET(4, 31));   // SET PINDIRS, 31

  // Use forced instruction to set pin dirs first
  DEV_WRITE(PIO_SM_INSTR(0), PIO_INSTR_SET(4, 31));
  spin(4);

  // Enable SM0
  pio_enable_sm(0);

  // Wait for the SM to execute
  spin(20);

  // Read DBG_PADOUT — should have bits [4:0] = 10101 = 0x15
  uint32_t padout = DEV_READ(PIO_DBG_PADOUT, 0);
  check("SET PINS output", padout & 0x1F, 0x15);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Test 4: TX FIFO → PULL → process → PUSH → RX FIFO
// ---------------------------------------------------------------------------
static void test_fifo_loopback(void) {
  pio_reset();

  // Configure SM0: no autopull/autopush, default shift dirs
  DEV_WRITE(PIO_SM_CLKDIV(0), 0x00010000);  // clkdiv INT=1
  DEV_WRITE(PIO_SM_SHIFTCTRL(0), 0);
  DEV_WRITE(PIO_SM_PINCTRL(0), 0);

  // Program:
  //   0: PULL block     — pop TX FIFO into OSR
  //   1: MOV ISR, OSR   — copy OSR to ISR
  //   2: PUSH block     — push ISR to RX FIFO
  //   3: JMP 0          — loop
  pio_write_instr(0, PIO_INSTR_PULL(0, 1));       // PULL block
  pio_write_instr(1, PIO_INSTR_MOV(6, 0, 7));     // MOV ISR, OSR
  pio_write_instr(2, PIO_INSTR_PUSH(0, 1));        // PUSH block
  pio_write_instr(3, PIO_INSTR_JMP(0, 0));         // JMP 0

  // Enable SM0
  pio_enable_sm(0);

  // Write test word to TX FIFO
  DEV_WRITE(PIO_TXF0, 0xDEADBEEF);

  // Wait for processing
  spin(50);

  // Read from RX FIFO
  uint32_t rxval = DEV_READ(PIO_RXF0, 0);
  check("FIFO loopback", rxval, 0xDEADBEEF);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Test 5: Clock divider — SM runs slower with INT=4
// ---------------------------------------------------------------------------
static void test_clock_divider(void) {
  pio_reset();

  // Program: SET X, 0 → loop forever (just to see SM is running)
  pio_write_instr(0, PIO_INSTR_SET(1, 0));     // SET X, 0
  pio_write_instr(1, PIO_INSTR_JMP(0, 1));     // JMP 1 (spin)

  // Set SM0 CLKDIV INT=4
  DEV_WRITE(PIO_SM_CLKDIV(0), 4 << 16);

  // Read back CLKDIV
  uint32_t clkdiv = DEV_READ(PIO_SM_CLKDIV(0), 0);
  check("CLKDIV readback INT=4", clkdiv >> 16, 4);

  pio_enable_sm(0);
  spin(20);
  pio_disable_sm(0);

  // Just verify we didn't hang — SM0 ADDR should have advanced
  uint32_t addr = DEV_READ(PIO_SM_ADDR(0), 0);
  // Should be at addr 1 (spinning on JMP 1)
  check("SM0 PC after clkdiv=4 run", addr, 1);
}

// ---------------------------------------------------------------------------
// Test 6: JMP X-- loop counting
// ---------------------------------------------------------------------------
static void test_jmp_x_decrement(void) {
  pio_reset();

  // Program:
  //   0: SET X, 3          — X = 3
  //   1: JMP X--, 1        — X-- (jmp cond=2), loop while X != 0
  //   2: MOV ISR, X        — copy X to ISR (should be 0)
  //   3: PUSH block        — push ISR
  //   4: JMP 4             — spin
  pio_write_instr(0, PIO_INSTR_SET(1, 3));         // SET X, 3
  pio_write_instr(1, PIO_INSTR_JMP(2, 1));         // JMP X--, 1
  pio_write_instr(2, PIO_INSTR_MOV(6, 0, 1));     // MOV ISR, X
  pio_write_instr(3, PIO_INSTR_PUSH(0, 1));        // PUSH block
  pio_write_instr(4, PIO_INSTR_JMP(0, 4));         // JMP 4

  DEV_WRITE(PIO_SM_SHIFTCTRL(0), 0);
  pio_enable_sm(0);
  spin(50);

  uint32_t rxval = DEV_READ(PIO_RXF0, 0);
  // After JMP X-- loop: X starts at 3, decrements each iteration.
  // Iteration 1: X=3 (!=0, jump), X becomes 2
  // Iteration 2: X=2 (!=0, jump), X becomes 1
  // Iteration 3: X=1 (!=0, jump), X becomes 0
  // Iteration 4: X=0 (==0, fall through), MOV ISR,X → ISR=0
  // Note: JMP X-- decrements X AND checks if old X was nonzero
  check("JMP X-- loop result", rxval, 0);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Test 7: MOV Y, X
// ---------------------------------------------------------------------------
static void test_mov_x_y(void) {
  pio_reset();

  // Program:
  //   0: SET X, 17         — X = 17
  //   1: MOV Y, X          — Y = X
  //   2: MOV ISR, Y        — ISR = Y
  //   3: PUSH block
  //   4: JMP 4
  pio_write_instr(0, PIO_INSTR_SET(1, 17));         // SET X, 17
  pio_write_instr(1, PIO_INSTR_MOV(2, 0, 1));      // MOV Y, X
  pio_write_instr(2, PIO_INSTR_MOV(6, 0, 2));      // MOV ISR, Y
  pio_write_instr(3, PIO_INSTR_PUSH(0, 1));         // PUSH block
  pio_write_instr(4, PIO_INSTR_JMP(0, 4));          // JMP 4

  DEV_WRITE(PIO_SM_SHIFTCTRL(0), 0);
  pio_enable_sm(0);
  spin(40);

  uint32_t rxval = DEV_READ(PIO_RXF0, 0);
  check("MOV Y, X = 17", rxval, 17);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Test 8: FSTAT register
// ---------------------------------------------------------------------------
static void test_fstat(void) {
  pio_reset();

  // Check initial state: all TX FIFOs empty, all RX FIFOs empty
  uint32_t fstat = DEV_READ(PIO_FSTAT, 0);
  // TX empty bits [27:24], RX empty bits [11:8]
  uint32_t tx_empty = (fstat >> 24) & 0xF;
  uint32_t rx_empty = (fstat >> 8) & 0xF;
  check("FSTAT TX all empty", tx_empty, 0xF);
  check("FSTAT RX all empty", rx_empty, 0xF);

  // Write to TX FIFO 0 — should no longer be empty
  DEV_WRITE(PIO_TXF0, 0x12345678);
  fstat = DEV_READ(PIO_FSTAT, 0);
  tx_empty = (fstat >> 24) & 0xF;
  check("FSTAT TX0 not empty after write", tx_empty & 1, 0);
}

// ---------------------------------------------------------------------------
// Test 9: IRQ set and clear
// ---------------------------------------------------------------------------
static void test_irq(void) {
  pio_reset();

  // Force-set IRQ flag 0
  DEV_WRITE(PIO_IRQ_FORCE, 0x01);
  uint32_t irq = DEV_READ(PIO_IRQ, 0);
  check("IRQ flag 0 set", irq & 1, 1);

  // Clear via W1C
  DEV_WRITE(PIO_IRQ, 0x01);
  irq = DEV_READ(PIO_IRQ, 0);
  check("IRQ flag 0 cleared", irq & 1, 0);
}

// ---------------------------------------------------------------------------
// Test 10: SM restart
// ---------------------------------------------------------------------------
static void test_sm_restart(void) {
  pio_reset();

  // Program SM0: SET X, 7; JMP 1
  pio_write_instr(0, PIO_INSTR_SET(1, 7));
  pio_write_instr(1, PIO_INSTR_JMP(0, 1));

  pio_enable_sm(0);
  spin(20);

  // SM0 PC should be at 1
  uint32_t addr = DEV_READ(PIO_SM_ADDR(0), 0);
  check("SM0 PC at 1 before restart", addr, 1);

  // Restart SM0 — PC should go to wrap_bot (default 0)
  DEV_WRITE(PIO_CTRL, (1 << 4) | 1);  // restart SM0 + keep SM0 enabled
  spin(10);
  DEV_WRITE(PIO_CTRL, 1);  // clear restart, keep enabled

  spin(20);
  addr = DEV_READ(PIO_SM_ADDR(0), 0);
  // After restart, SM re-executes from wrap_bot=0, then JMP 1 → PC=1
  check("SM0 PC after restart", addr, 1);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Test 11: Forced instruction execution
// ---------------------------------------------------------------------------
static void test_forced_instr(void) {
  pio_reset();

  // Program SM0: JMP 0 (spin at instruction 0)
  pio_write_instr(0, PIO_INSTR_JMP(0, 0));

  DEV_WRITE(PIO_SM_SHIFTCTRL(0), 0);
  pio_enable_sm(0);
  spin(10);

  // SM0 spinning at PC=0. Force SET X, 29
  DEV_WRITE(PIO_SM_INSTR(0), PIO_INSTR_SET(1, 29));
  spin(10);

  // Force MOV ISR, X and PUSH to capture X in RX FIFO
  DEV_WRITE(PIO_SM_INSTR(0), PIO_INSTR_MOV(6, 0, 1));  // MOV ISR, X
  spin(10);
  DEV_WRITE(PIO_SM_INSTR(0), PIO_INSTR_PUSH(0, 0));     // PUSH noblock
  spin(10);

  uint32_t rxval = DEV_READ(PIO_RXF0, 0);
  check("Forced SET X,29 readback", rxval, 29);

  pio_disable_sm(0);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(void) {
  puts("=== PIO Test Suite ===\n");

  test_gpio_compat();
  test_cfginfo();
  test_set_pins();
  test_fifo_loopback();
  test_clock_divider();
  test_jmp_x_decrement();
  test_mov_x_y();
  test_fstat();
  test_irq();
  test_sm_restart();
  test_forced_instr();

  puts("\n--- Results: ");
  putdec(test_num - total_errors);
  puts("/");
  putdec(test_num);
  puts(" passed");
  if (total_errors > 0) {
    puts(" (");
    putdec(total_errors);
    puts(" FAILED)");
  }
  puts(" ---\n");

  return total_errors;
}
