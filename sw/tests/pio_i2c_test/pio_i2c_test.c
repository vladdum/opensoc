// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * PIO I2C Test
 *
 * Tests the PIO-based I2C bit-bang implementation using the Pico SDK-compatible
 * PIO library and a pioasm-format .pio.h program header.
 *
 *  1. Program loading — i2c_tx_program loads into instruction memory
 *  2. Default config — sideset, wrap, shift settings are correct
 *  3. I2C TX single byte — sends address byte, verifies SM completes
 *  4. Pin state after STOP — SDA and SCL released (OE=0)
 *  5. ACK/NAK readback — RX FIFO contains ACK status
 *  6. pio_i2c_write helper — multi-byte write transaction
 *  7. Program management — add, remove, re-add
 *
 * Note: No I2C slave exists in simulation. The open-drain wrapper drives
 * sda_bus HIGH when no side asserts OE, so the ACK bit reads as 1 (NACK).
 * Pin behavior is verified via dbg_padout/padoe.
 */

#include "simple_system_common.h"
#include "hardware/pio.h"
#include "pio_programs/i2c.pio.h"

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
// Test 1: Program loading
// -----------------------------------------------------------------------
static int prog_offset;

static void test_program_load(void) {
    _pio_used_instruction_space = 0;
    _pio_sm_claimed = 0;

    prog_offset = pio_add_program(pio0, &i2c_tx_program);
    check("i2c_tx_program loaded", prog_offset >= 0, 1);
    check("program length = 15", i2c_tx_program.length, 15);
    check("program origin = -1 (relocatable)", (uint32_t)(int32_t)i2c_tx_program.origin, (uint32_t)(int32_t)-1);
}

// -----------------------------------------------------------------------
// Test 2: Default config verification
// -----------------------------------------------------------------------
static void test_default_config(void) {
    pio_sm_config c = i2c_tx_program_get_default_config((uint)prog_offset);

    // Check wrap: wrap_target=offset+0, wrap_top=offset+14
    uint32_t wrap_bottom = (c.execctrl >> PIO_SM0_EXECCTRL_WRAP_BOTTOM_LSB) & 0x1F;
    uint32_t wrap_top    = (c.execctrl >> PIO_SM0_EXECCTRL_WRAP_TOP_LSB) & 0x1F;
    check("wrap_bottom = offset+0", wrap_bottom, (uint32_t)prog_offset + 0);
    check("wrap_top = offset+14", wrap_top, (uint32_t)prog_offset + 14);

    // Check sideset: count=2 (1 bit + optional enable)
    uint32_t sideset_count = (c.pinctrl >> PIO_SM0_PINCTRL_SIDESET_COUNT_LSB) & 0x7;
    check("sideset_count = 2", sideset_count, 2);

    // Check SIDE_EN (optional sideset) and SIDE_PINDIR (pindirs mode)
    uint32_t side_en = (c.execctrl >> PIO_SM0_EXECCTRL_SIDE_EN_LSB) & 1;
    uint32_t side_pindir = (c.execctrl >> PIO_SM0_EXECCTRL_SIDE_PINDIR_LSB) & 1;
    check("SIDE_EN = 1 (optional)", side_en, 1);
    check("SIDE_PINDIR = 1 (pindirs)", side_pindir, 1);
}

// -----------------------------------------------------------------------
// Test 3: I2C TX single byte
// -----------------------------------------------------------------------
static void test_i2c_tx_byte(void) {
    uint sm = 0;
    uint sda_pin = 0;
    uint scl_pin = 1;

    pio_i2c_init(pio0, sm, (uint)prog_offset, sda_pin, scl_pin, 100000);
    pio_sm_set_enabled(pio0, sm, true);

    // Send address byte 0xA0 (device 0x50, write)
    pio_i2c_put_byte(pio0, sm, 0xA0);

    // Wait for SM to complete the frame (START + 8 bits + ACK + STOP)
    // At clkdiv ~ 31 and 15 instructions with delays, this takes many cycles
    spin(2000);

    // SM should be stalled at PULL (instruction 0), waiting for next byte
    uint32_t pc = pio_sm_get_pc(pio0, sm);
    check("SM stalled at PULL", pc, (uint32_t)prog_offset + 0);

    pio_sm_set_enabled(pio0, sm, false);
}

// -----------------------------------------------------------------------
// Test 4: Pin state after STOP
// -----------------------------------------------------------------------
static void test_pin_state_after_stop(void) {
    uint sda_pin = 0;
    uint scl_pin = 1;

    // After STOP, both SDA and SCL should be released (OE=0)
    uint32_t padoe = pio0->dbg_padoe;
    check("SDA OE=0 after STOP", (padoe >> sda_pin) & 1, 0);
    check("SCL OE=0 after STOP", (padoe >> scl_pin) & 1, 0);

    // Pin output values should be 0 (set during init, never changed)
    uint32_t padout = pio0->dbg_padout;
    check("SDA output=0", (padout >> sda_pin) & 1, 0);
    check("SCL output=0", (padout >> scl_pin) & 1, 0);
}

// -----------------------------------------------------------------------
// Test 5: ACK/NAK readback
// -----------------------------------------------------------------------
static void test_ack_readback(void) {
    // RX FIFO should have 1 entry (ACK bit from the byte we sent)
    check("RX FIFO not empty", pio_sm_is_rx_fifo_empty(pio0, 0) == 0, 1);

    uint32_t ack_word = pio_sm_get(pio0, 0);
    // Open-drain wrapper: sda_bus = ~i2c_sda_oe & ~gpio_oe[0].
    // With no slave pulling SDA low, sda_bus = HIGH (1) = NACK.
    check("ACK bit = 1 (NACK, no slave)", ack_word & 1, 1);
}

// -----------------------------------------------------------------------
// Test 6: pio_i2c_write helper
// -----------------------------------------------------------------------
static void test_i2c_write_helper(void) {
    uint sm = 0;
    uint sda_pin = 0;
    uint scl_pin = 1;

    // Re-initialize SM
    pio_sm_restart(pio0, sm);
    pio_i2c_init(pio0, sm, (uint)prog_offset, sda_pin, scl_pin, 100000);
    pio_sm_set_enabled(pio0, sm, true);

    // Write 2 data bytes to address 0x50
    uint8_t data[] = { 0x42, 0x55 };
    bool ok = pio_i2c_write(pio0, sm, 0x50, data, 2);
    // No slave in simulation — SDA floats HIGH (NACK), so write returns false
    check("pio_i2c_write returns false (NACK, no slave)", ok, 0);

    spin(2000);

    // Verify SM completed all 3 frames (addr + 2 data bytes)
    uint32_t pc = pio_sm_get_pc(pio0, sm);
    check("SM at PULL after write", pc, (uint32_t)prog_offset + 0);

    pio_sm_set_enabled(pio0, sm, false);
}

// -----------------------------------------------------------------------
// Test 7: Program management
// -----------------------------------------------------------------------
static void test_program_management(void) {
    // Can't add at same offset (already loaded)
    bool can_add = pio_can_add_program_at_offset(pio0, &i2c_tx_program, (uint)prog_offset);
    check("can_add at same offset = false", can_add, 0);

    // Remove
    pio_remove_program(pio0, &i2c_tx_program, (uint)prog_offset);
    can_add = pio_can_add_program_at_offset(pio0, &i2c_tx_program, (uint)prog_offset);
    check("can_add after remove = true", can_add, 1);

    // Re-add
    int offset2 = pio_add_program_at_offset(pio0, &i2c_tx_program, (uint)prog_offset);
    check("re-add at same offset", offset2, prog_offset);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main(void) {
    puts("=== PIO I2C Test ===\n");

    test_program_load();
    test_default_config();
    test_i2c_tx_byte();
    test_pin_state_after_stop();
    test_ack_readback();
    test_i2c_write_helper();
    test_program_management();

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
