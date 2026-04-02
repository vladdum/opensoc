// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * PIO SDK Compatibility Test
 *
 * Same tests as pio_test.c but using Pico SDK-compatible API.
 * Verifies that the compatibility shim produces identical hardware behavior.
 *
 *  1. GPIO compat (via DEV_WRITE — SDK doesn't wrap GPIO compat regs)
 *  2. DBG_CFGINFO via struct access
 *  3. SET PINS via SDK config + program load
 *  4. FIFO loopback via pio_sm_put_blocking / pio_sm_get_blocking
 *  5. Clock divider via sm_config_set_clkdiv_int_frac8
 *  6. JMP X-- via pio_encode_jmp_x_dec
 *  7. MOV Y, X via pio_encode_mov
 *  8. FSTAT via pio_sm_is_tx_fifo_empty
 *  9. IRQ set/clear via struct access
 * 10. SM restart via pio_sm_restart
 * 11. Forced instruction via pio_sm_exec
 */

#include "simple_system_common.h"
#include "hardware/pio.h"

static int test_num = 0;
static int total_errors = 0;

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------
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

static void puthex_val(uint32_t v) {
    const char *hex = "0123456789ABCDEF";
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
        puthex_val(got);
        puts(" expected ");
        puthex_val(expected);
        putchar('\n');
        total_errors++;
    }
}

static void spin(int n) {
    for (volatile int i = 0; i < n; i++) ;
}

// -----------------------------------------------------------------------
// Test 1: GPIO compatibility — DIR/OUT registers
// (GPIO compat regs are OpenSoC-specific, not part of Pico SDK API)
// -----------------------------------------------------------------------
static void test_gpio_compat(void) {
    pio_sm_set_enabled(pio0, 0, false);

    DEV_WRITE(PIO_GPIO_DIR, 0x000000FF);
    DEV_WRITE(PIO_GPIO_OUT, 0x000000A5);

    uint32_t dir = DEV_READ(PIO_GPIO_DIR, 0);
    uint32_t out = DEV_READ(PIO_GPIO_OUT, 0);

    check("GPIO DIR readback", dir, 0x000000FF);
    check("GPIO OUT readback", out, 0x000000A5);
}

// -----------------------------------------------------------------------
// Test 2: DBG_CFGINFO via struct access
// -----------------------------------------------------------------------
static void test_cfginfo(void) {
    uint32_t info = pio0->dbg_cfginfo;
    uint32_t imem_size  = (info >> 16) & 0x3F;
    uint32_t num_sm     = (info >> 8)  & 0xF;
    uint32_t fifo_depth = info & 0x3F;

    check("CFGINFO imem_size=32", imem_size, 32);
    check("CFGINFO num_sm=4",     num_sm,     4);
    check("CFGINFO fifo_depth=4", fifo_depth, 4);
}

// -----------------------------------------------------------------------
// Test 3: SET PINS — using SDK program load + config
// -----------------------------------------------------------------------

static void test_set_pins(void) {
    // Reset SM0
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // Write instructions directly (small program, no pio_program_t needed)
    pio0->instr_mem[0] = pio_encode_set(pio_pins, 21);   // SET PINS, 21
    pio0->instr_mem[1] = pio_encode_jmp(1);               // JMP 1 (spin)

    // Configure SM0: SET_BASE=0, SET_COUNT=5
    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_set_pins(&c, 0, 5);
    sm_config_set_wrap(&c, 0, 1);

    pio_sm_init(pio0, 0, 0, &c);

    // Set OE for pins [4:0] via forced instruction
    pio_sm_exec(pio0, 0, pio_encode_set(pio_pindirs, 31));
    spin(4);

    pio_sm_set_enabled(pio0, 0, true);
    spin(20);

    uint32_t padout = pio0->dbg_padout;
    check("SET PINS output", padout & 0x1F, 0x15);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 4: FIFO loopback — PULL → MOV ISR,OSR → PUSH
// -----------------------------------------------------------------------
static void test_fifo_loopback(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // Program: PULL block → MOV ISR,OSR → PUSH block → JMP 0
    pio0->instr_mem[0] = pio_encode_pull(false, true);
    pio0->instr_mem[1] = pio_encode_mov(pio_isr, pio_osr);
    pio0->instr_mem[2] = pio_encode_push(false, true);
    pio0->instr_mem[3] = pio_encode_jmp(0);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_clkdiv_int_frac8(&c, 1, 0);
    sm_config_set_wrap(&c, 0, 3);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);

    // Use blocking put/get
    pio_sm_put_blocking(pio0, 0, 0xDEADBEEF);
    spin(50);
    uint32_t rxval = pio_sm_get_blocking(pio0, 0);

    check("FIFO loopback", rxval, 0xDEADBEEF);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 5: Clock divider — INT=4
// -----------------------------------------------------------------------
static void test_clock_divider(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    pio0->instr_mem[0] = pio_encode_set(pio_x, 0);
    pio0->instr_mem[1] = pio_encode_jmp(1);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_clkdiv_int_frac8(&c, 4, 0);
    sm_config_set_wrap(&c, 0, 1);

    pio_sm_init(pio0, 0, 0, &c);

    uint32_t clkdiv = pio0->sm[0].clkdiv;
    check("CLKDIV readback INT=4", clkdiv >> 16, 4);

    pio_sm_set_enabled(pio0, 0, true);
    spin(20);
    pio_sm_set_enabled(pio0, 0, false);

    uint32_t addr = pio_sm_get_pc(pio0, 0);
    check("SM0 PC after clkdiv=4 run", addr, 1);
}

// -----------------------------------------------------------------------
// Test 6: JMP X-- loop counting
// -----------------------------------------------------------------------
static void test_jmp_x_decrement(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // SET X,3 → JMP X--,1 → MOV ISR,X → PUSH block → JMP 4
    pio0->instr_mem[0] = pio_encode_set(pio_x, 3);
    pio0->instr_mem[1] = pio_encode_jmp_x_dec(1);
    pio0->instr_mem[2] = pio_encode_mov(pio_isr, pio_x);
    pio0->instr_mem[3] = pio_encode_push(false, true);
    pio0->instr_mem[4] = pio_encode_jmp(4);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, 0, 4);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(50);

    uint32_t rxval = pio_sm_get_blocking(pio0, 0);
    // JMP X-- is a true post-decrement (RP2040 TRM §3.4.2): X is decremented
    // unconditionally; the pre-decrement value determines the branch.
    // After 4 iterations (X: 3→2→1→0→0xFFFFFFFF), X wraps on the fall-through.
    check("JMP X-- loop result", rxval, 0xFFFFFFFF);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 7: MOV Y, X
// -----------------------------------------------------------------------
static void test_mov_x_y(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // SET X,17 → MOV Y,X → MOV ISR,Y → PUSH block → JMP 4
    pio0->instr_mem[0] = pio_encode_set(pio_x, 17);
    pio0->instr_mem[1] = pio_encode_mov(pio_y, pio_x);
    pio0->instr_mem[2] = pio_encode_mov(pio_isr, pio_y);
    pio0->instr_mem[3] = pio_encode_push(false, true);
    pio0->instr_mem[4] = pio_encode_jmp(4);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, 0, 4);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(40);

    uint32_t rxval = pio_sm_get_blocking(pio0, 0);
    check("MOV Y, X = 17", rxval, 17);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 8: FSTAT via SDK helpers
// -----------------------------------------------------------------------
static void test_fstat(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // All FIFOs should be empty after restart
    check("TX0 empty", pio_sm_is_tx_fifo_empty(pio0, 0), 1);
    check("RX0 empty", pio_sm_is_rx_fifo_empty(pio0, 0), 1);

    // Write to TX FIFO 0
    pio_sm_put(pio0, 0, 0x12345678);
    check("TX0 not empty after write", pio_sm_is_tx_fifo_empty(pio0, 0), 0);
}

// -----------------------------------------------------------------------
// Test 9: IRQ set and clear
// -----------------------------------------------------------------------
static void test_irq(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // Force-set IRQ flag 0 via struct
    pio0->irq_force = 0x01;
    uint32_t irq = pio0->irq;
    check("IRQ flag 0 set", irq & 1, 1);

    // Clear via W1C
    pio0->irq = 0x01;
    irq = pio0->irq;
    check("IRQ flag 0 cleared", irq & 1, 0);
}

// -----------------------------------------------------------------------
// Test 10: SM restart
// -----------------------------------------------------------------------
static void test_sm_restart(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    pio0->instr_mem[0] = pio_encode_set(pio_x, 7);
    pio0->instr_mem[1] = pio_encode_jmp(1);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, 0, 1);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(20);

    uint32_t addr = pio_sm_get_pc(pio0, 0);
    check("SM0 PC at 1 before restart", addr, 1);

    // Restart via SDK function
    pio_sm_restart(pio0, 0);
    spin(20);

    addr = pio_sm_get_pc(pio0, 0);
    check("SM0 PC after restart", addr, 1);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 11: Forced instruction execution
// -----------------------------------------------------------------------
static void test_forced_instr(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    pio0->instr_mem[0] = pio_encode_jmp(0);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, 0, 0);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(10);

    // Force SET X, 29
    pio_sm_exec(pio0, 0, pio_encode_set(pio_x, 29));
    spin(10);

    // Force MOV ISR, X and PUSH
    pio_sm_exec(pio0, 0, pio_encode_mov(pio_isr, pio_x));
    spin(10);
    pio_sm_exec(pio0, 0, pio_encode_push(false, false));
    spin(10);

    uint32_t rxval = pio_sm_get(pio0, 0);
    check("Forced SET X,29 readback", rxval, 29);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 12: pio_add_program / pio_claim_unused_sm (SDK program management)
// -----------------------------------------------------------------------
static const uint16_t loopback_prog_instrs[] = {
    // 0: PULL block
    // 1: MOV ISR, OSR
    // 2: PUSH block
    // 3: JMP 0
    0x8080,  // pio_encode_pull(false, true)
    0xa0e7,  // pio_encode_mov(pio_isr, pio_osr)
    0x8020,  // pio_encode_push(false, true)
    0x0000,  // pio_encode_jmp(0)
};

static const pio_program_t loopback_prog = {
    .instructions = loopback_prog_instrs,
    .length = 4,
    .origin = -1,
};

static void test_program_management(void) {
    // Reset tracking state
    _pio_used_instruction_space = 0;
    _pio_sm_claimed = 0;

    // Add program — should succeed and return an offset
    int offset = pio_add_program(pio0, &loopback_prog);
    check("pio_add_program succeeds", offset >= 0, 1);

    // Claim a SM
    int sm = pio_claim_unused_sm(pio0, true);
    check("pio_claim_unused_sm succeeds", sm >= 0, 1);

    // Can't add same program again if space is full? Try can_add
    bool can_add = pio_can_add_program_at_offset(pio0, &loopback_prog, (unsigned)offset);
    check("can_add at same offset = false", can_add, 0);

    // Remove and re-add
    pio_remove_program(pio0, &loopback_prog, (unsigned)offset);
    can_add = pio_can_add_program_at_offset(pio0, &loopback_prog, (unsigned)offset);
    check("can_add after remove = true", can_add, 1);

    // Unclaim SM
    pio_sm_unclaim(pio0, (unsigned)sm);
    check("SM unclaimed", pio_sm_is_claimed(pio0, (unsigned)sm), 0);
}

// -----------------------------------------------------------------------
// Test 13: SIDE_PINDIR — sideset targets pindirs (OE) not output
// -----------------------------------------------------------------------
static void test_sideset_pindirs(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    DEV_WRITE(PIO_GPIO_DIR, 0);
    DEV_WRITE(PIO_GPIO_OUT, 0);

    // With mandatory sideset (SIDE_EN=0), EVERY instruction applies sideset.
    // Both instructions must carry sideset=1 or the implicit value 0 will
    // clear the OE bit on alternate ticks.
    // SIDE_PINDIR=1 → sideset targets pins_oe_q, not pins_out_q.
    pio0->instr_mem[0] = pio_encode_set(pio_x, 0)
                       | pio_encode_sideset(1, 1);  // sideset value=1
    pio0->instr_mem[1] = pio_encode_jmp(0)
                       | pio_encode_sideset(1, 1);  // must also carry sideset=1

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_sideset(&c, 1, false, true);      // 1-bit, mandatory, pindirs
    sm_config_set_sideset_pins(&c, 2);              // sideset base = gpio2
    sm_config_set_wrap(&c, 0, 1);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(20);

    uint32_t padoe = pio0->dbg_padoe;
    check("SIDE_PINDIR: OE bit2=1 via sideset", (padoe >> 2) & 1, 1);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 14: Optional sideset (SIDE_EN) — sideset only when enable bit set
// -----------------------------------------------------------------------
static void test_optional_sideset(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    DEV_WRITE(PIO_GPIO_DIR, 0);
    DEV_WRITE(PIO_GPIO_OUT, 0);

    // Optional sideset: sideset_count=2 (1 enable + 1 data), SIDE_EN=1
    // sideset_base=3 (gpio3 for output)
    //
    // Use SET PINDIRS (targets pins_oe_q) with sideset (targets pins_out_q)
    // in the same instruction — no register conflict.
    //
    // Instr 0: SET PINDIRS, 31 + sideset opt value=1
    //   → OE bits 0-4 set, gpio3 output = 1
    // Instr 1: SET X, 0 (no sideset — enable=0, so gpio3 retains value)
    // Instr 2: JMP 2 (spin)
    pio0->instr_mem[0] = pio_encode_set(pio_pindirs, 31)
                       | pio_encode_sideset_opt(1, 1);  // opt enable=1, value=1
    pio0->instr_mem[1] = pio_encode_set(pio_x, 0);      // no sideset (enable=0)
    pio0->instr_mem[2] = pio_encode_jmp(2);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_set_pins(&c, 0, 5);              // SET range = gpio[4:0]
    sm_config_set_sideset(&c, 2, true, false);      // 2-bit (1 data + 1 enable), optional, output
    sm_config_set_sideset_pins(&c, 3);              // sideset base = gpio3
    sm_config_set_wrap(&c, 0, 2);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);
    spin(30);

    uint32_t padout = pio0->dbg_padout;

    // gpio3 should be 1 (set by instr 0's sideset), and retained because
    // instr 1 has no sideset (enable=0, so sideset not applied)
    check("OPT_SIDESET: gpio3=1 after opt sideset", (padout >> 3) & 1, 1);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 15: OUT EXEC — execute instruction shifted from OSR
// -----------------------------------------------------------------------
static void test_out_exec(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // Program:
    //   0: PULL block        — get instruction encoding from TX FIFO
    //   1: OUT EXEC, 16      — execute the shifted-out instruction
    //   2: MOV ISR, X        — read back X register
    //   3: PUSH noblock      — push result to RX FIFO
    //   4: JMP 4             — spin
    pio0->instr_mem[0] = pio_encode_pull(false, true);
    pio0->instr_mem[1] = pio_encode_out(pio_exec_out, 16);
    pio0->instr_mem[2] = pio_encode_mov(pio_isr, pio_x);
    pio0->instr_mem[3] = pio_encode_push(false, false);
    pio0->instr_mem[4] = pio_encode_jmp(4);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_out_shift(&c, false, false, 32);  // shift left, no autopull
    sm_config_set_wrap(&c, 0, 4);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);

    // Put "SET X, 23" instruction encoding into TX FIFO
    // OUT shifts left, so 16 MSBs are the instruction
    uint16_t set_x_23 = pio_encode_set(pio_x, 23);
    pio_sm_put_blocking(pio0, 0, (uint32_t)set_x_23 << 16);
    spin(100);

    uint32_t rxval = pio_sm_get(pio0, 0);
    check("OUT EXEC: SET X,23 via OSR", rxval, 23);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Test 16: MOV EXEC — execute instruction from scratch register
// -----------------------------------------------------------------------
static void test_mov_exec(void) {
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, false);
    spin(4);

    // Program:
    //   0: PULL block        — get instruction encoding from TX FIFO
    //   1: MOV X, OSR        — copy to X
    //   2: MOV EXEC, X       — execute instruction from X
    //   3: MOV ISR, Y        — read back Y (target of the executed instruction)
    //   4: PUSH noblock
    //   5: JMP 5             — spin
    pio0->instr_mem[0] = pio_encode_pull(false, true);
    pio0->instr_mem[1] = pio_encode_mov(pio_x, pio_osr);
    pio0->instr_mem[2] = pio_encode_mov(pio_exec_mov, pio_x);
    pio0->instr_mem[3] = pio_encode_mov(pio_isr, pio_y);
    pio0->instr_mem[4] = pio_encode_push(false, false);
    pio0->instr_mem[5] = pio_encode_jmp(5);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, 0, 5);

    pio_sm_init(pio0, 0, 0, &c);
    pio_sm_set_enabled(pio0, 0, true);

    // Put "SET Y, 19" instruction encoding into TX FIFO
    uint16_t set_y_19 = pio_encode_set(pio_y, 19);
    pio_sm_put_blocking(pio0, 0, (uint32_t)set_y_19);
    spin(100);

    uint32_t rxval = pio_sm_get(pio0, 0);
    check("MOV EXEC: SET Y,19 via X", rxval, 19);

    pio_sm_set_enabled(pio0, 0, false);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main(void) {
    puts("=== PIO SDK Compatibility Test ===\n");

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
    test_program_management();
    test_sideset_pindirs();
    test_optional_sideset();
    test_out_exec();
    test_mov_exec();

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
