// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * I2C Loopback Test
 *
 * Tests communication between the HW I2C master controller (0x60000) and a
 * PIO-based I2C slave running on SM0 (receiver) and SM1 (transmitter).
 *
 * Requires the opensoc_i2c_loopback wrapper which bridges HW I2C pins with
 * PIO GPIO pins via open-drain wired-AND logic.
 *
 * Tests:
 *   1. PIO slave program loading
 *   2. Single byte write (master → slave)
 *   3. Multi-byte write (master → slave, 4 bytes)
 *   4. Data patterns (0x00, 0x55, 0xAA, 0xFF)
 *   5. Back-to-back transactions
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"
#include "hardware/pio.h"
#include "pio_programs/i2c_slave.pio.h"

#define SLAVE_ADDR 0x42

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
        puts(" -- got ");
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
// HW I2C master helpers
// -----------------------------------------------------------------------
static void i2c_wait_idle(void) {
    while (DEV_READ(I2C_STATUS, 0) & I2C_STATUS_BUSY) ;
}

// Send START + address byte (7-bit addr + W bit)
static void i2c_master_start_write(uint8_t addr) {
    DEV_WRITE(I2C_TX_DATA, (addr << 1) | 0);  // address + write bit
    DEV_WRITE(I2C_CTRL, I2C_CTRL_START);
    i2c_wait_idle();
}

// Send data byte (no START/STOP)
static void i2c_master_send_byte(uint8_t data) {
    DEV_WRITE(I2C_TX_DATA, data);
    DEV_WRITE(I2C_CTRL, 0);  // no start, no stop
    i2c_wait_idle();
}

// Send data byte + STOP
static void i2c_master_send_byte_stop(uint8_t data) {
    DEV_WRITE(I2C_TX_DATA, data);
    DEV_WRITE(I2C_CTRL, I2C_CTRL_STOP);
    i2c_wait_idle();
}

// -----------------------------------------------------------------------
// PIO slave setup
// -----------------------------------------------------------------------
static int rx_offset, tx_offset;

static void setup_pio_slave(void) {
    // Reset PIO state
    _pio_used_instruction_space = 0;
    _pio_sm_claimed = 0;

    // Load RX program at offset 0
    rx_offset = pio_add_program(pio0, &i2c_slave_rx_program);

    // Load TX program at offset 18
    tx_offset = pio_add_program(pio0, &i2c_slave_tx_program);

    // Initialize SM0 as receiver
    pio_i2c_slave_rx_init(pio0, 0, (uint)rx_offset, 0, 1);  // SDA=gpio0, SCL=gpio1

    // Initialize SM1 as transmitter
    pio_i2c_slave_tx_init(pio0, 1, (uint)tx_offset, 0, 1);

    // Enable both SMs
    pio_sm_set_enabled(pio0, 0, true);
    pio_sm_set_enabled(pio0, 1, true);

    // Give SMs time to start and reach wait_start
    spin(100);
}

// Read a byte from the PIO slave RX FIFO (SM0) and clear its IRQ
static uint8_t slave_read_byte(void) {
    uint32_t raw = pio_sm_get_blocking(pio0, 0);
    uint8_t byte = (raw >> 24) & 0xFF;
    pio0->irq = (1u << 0);  // Clear SM0's IRQ flag
    return byte;
}

// -----------------------------------------------------------------------
// Test 1: Program loading
// -----------------------------------------------------------------------
static void test_program_load(void) {
    puts("\n[Test: Program Loading]\n");

    check("RX program loaded at offset 0", rx_offset, 0);
    check("RX program length = 18", i2c_slave_rx_program.length, 18);
    check("TX program loaded at offset 18", tx_offset, 18);
    check("TX program length = 14", i2c_slave_tx_program.length, 14);
}

// -----------------------------------------------------------------------
// Test 2: Single byte write (master → slave)
// -----------------------------------------------------------------------
static void test_single_byte_write(void) {
    puts("\n[Test: Single Byte Write]\n");

    // Set up I2C master prescaler
    DEV_WRITE(I2C_PRESCALE, 8);

    // Master sends: START + addr(0x42, W) + data(0xAB) + STOP
    i2c_master_start_write(SLAVE_ADDR);

    // Read address byte from PIO slave
    uint8_t addr_byte = slave_read_byte();
    check("Slave received addr byte", addr_byte, (SLAVE_ADDR << 1) | 0);

    // Check ACK was received by master
    uint32_t status = DEV_READ(I2C_STATUS, 0);
    check("Master got ACK for addr", (status >> 1) & 1, 1);

    // Send data byte with STOP
    i2c_master_send_byte_stop(0xAB);

    // Read data byte from PIO slave
    uint8_t data = slave_read_byte();
    check("Slave received data 0xAB", data, 0xAB);
}

// -----------------------------------------------------------------------
// Test 3: Multi-byte write (master → slave, 4 bytes)
// -----------------------------------------------------------------------
static void test_multi_byte_write(void) {
    puts("\n[Test: Multi-Byte Write]\n");

    uint8_t tx_data[] = {0x11, 0x22, 0x33, 0x44};

    // Restart slave SMs for clean state
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, true);
    spin(100);

    // Master sends START + addr + 4 data bytes + STOP
    i2c_master_start_write(SLAVE_ADDR);

    // Read and release address byte
    uint8_t addr = slave_read_byte();
    check("Multi: addr byte", addr, (SLAVE_ADDR << 1) | 0);

    // Send data bytes
    for (int i = 0; i < 3; i++) {
        i2c_master_send_byte(tx_data[i]);
        uint8_t got = slave_read_byte();
        if (i == 0) check("Multi: data[0]=0x11", got, 0x11);
        else if (i == 1) check("Multi: data[1]=0x22", got, 0x22);
        else check("Multi: data[2]=0x33", got, 0x33);
    }

    // Last byte with STOP
    i2c_master_send_byte_stop(tx_data[3]);
    uint8_t last = slave_read_byte();
    check("Multi: data[3]=0x44", last, 0x44);
}

// -----------------------------------------------------------------------
// Test 4: Data patterns
// -----------------------------------------------------------------------
static void test_data_patterns(void) {
    puts("\n[Test: Data Patterns]\n");

    uint8_t patterns[] = {0x00, 0x55, 0xAA, 0xFF};

    // Restart slave
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, true);
    spin(100);

    i2c_master_start_write(SLAVE_ADDR);
    slave_read_byte();  // address byte — discard
    pio0->irq = (1u << 0);  // Already cleared by slave_read_byte, but be safe

    for (int i = 0; i < 4; i++) {
        if (i < 3)
            i2c_master_send_byte(patterns[i]);
        else
            i2c_master_send_byte_stop(patterns[i]);

        uint8_t got = slave_read_byte();
        if (i == 0) check("Pattern 0x00", got, 0x00);
        else if (i == 1) check("Pattern 0x55", got, 0x55);
        else if (i == 2) check("Pattern 0xAA", got, 0xAA);
        else check("Pattern 0xFF", got, 0xFF);
    }
}

// -----------------------------------------------------------------------
// Test 5: Back-to-back transactions
// -----------------------------------------------------------------------
static void test_back_to_back(void) {
    puts("\n[Test: Back-to-Back]\n");

    // Restart slave
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, true);
    spin(100);

    // First transaction
    i2c_master_start_write(SLAVE_ADDR);
    slave_read_byte();  // address
    i2c_master_send_byte_stop(0xDE);
    uint8_t got1 = slave_read_byte();
    check("Back-to-back: tx1 data=0xDE", got1, 0xDE);

    // Small gap
    spin(200);

    // Second transaction (slave should be back at wait_start)
    i2c_master_start_write(SLAVE_ADDR);
    slave_read_byte();  // address
    i2c_master_send_byte_stop(0xAD);
    uint8_t got2 = slave_read_byte();
    check("Back-to-back: tx2 data=0xAD", got2, 0xAD);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main(void) {
    puts("=== I2C Loopback Test ===\n");

    setup_pio_slave();
    test_program_load();
    test_single_byte_write();
    test_multi_byte_write();
    test_data_patterns();
    test_back_to_back();

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
