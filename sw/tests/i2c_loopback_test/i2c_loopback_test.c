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
#define TIMEOUT_CYCLES 5000   // Max spin iterations before declaring timeout

static int test_num = 0;
static int total_errors = 0;
static int timed_out = 0;      // Set on first timeout — aborts remaining tests

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

static void dump_debug_state(void) {
    puts("  DEBUG: I2C STATUS=");
    puthex_val(DEV_READ(I2C_STATUS, 0));
    puts(" PIO FSTAT=");
    puthex_val(pio0->fstat);
    puts(" FDEBUG=");
    puthex_val(pio0->fdebug);
    puts(" IRQ=");
    puthex_val(pio0->irq);
    puts("\n  SM0: ADDR=");
    puthex_val(pio0->sm[0].addr);
    puts(" EXECCTRL=");
    puthex_val(pio0->sm[0].execctrl);
    puts(" PINCTRL=");
    puthex_val(pio0->sm[0].pinctrl);
    puts("\n  SM1: ADDR=");
    puthex_val(pio0->sm[1].addr);
    puts("\n  GPIO: IN=");
    puthex_val(DEV_READ(PIO_GPIO_IN, 0));
    puts(" OUT=");
    puthex_val(DEV_READ(PIO_GPIO_OUT, 0));
    puts(" OE=");
    puthex_val(DEV_READ(PIO_GPIO_DIR, 0));
    puts("\n");
}

// -----------------------------------------------------------------------
// HW I2C master helpers
// -----------------------------------------------------------------------
static int i2c_wait_idle(void) {
    for (int i = 0; i < TIMEOUT_CYCLES; i++) {
        if (!(DEV_READ(I2C_STATUS, 0) & I2C_STATUS_BUSY))
            return 0;
    }
    puts("  TIMEOUT: i2c_wait_idle\n");
    dump_debug_state();
    total_errors++;
    timed_out = 1;
    return -1;
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

// Send START + address byte (7-bit addr + R bit) for master-read
static void i2c_master_start_read(uint8_t addr) {
    DEV_WRITE(I2C_TX_DATA, (addr << 1) | 1);  // address + read bit
    DEV_WRITE(I2C_CTRL, I2C_CTRL_START);
    i2c_wait_idle();
}

// Read a data byte from slave (master ACK, no STOP — for multi-byte reads)
static uint32_t i2c_master_read_byte_ack(void) {
    DEV_WRITE(I2C_CTRL, I2C_CTRL_RW | I2C_CTRL_ACK_EN);
    if (i2c_wait_idle()) return 0xFFFFFFFF;
    return DEV_READ(I2C_RX_DATA, 0) & 0xFF;
}

// Read a data byte from slave (master NAK + STOP — for last byte)
static uint32_t i2c_master_read_byte_nak_stop(void) {
    DEV_WRITE(I2C_CTRL, I2C_CTRL_RW | I2C_CTRL_STOP);
    if (i2c_wait_idle()) return 0xFFFFFFFF;
    return DEV_READ(I2C_RX_DATA, 0) & 0xFF;
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

// Read a byte from the PIO slave RX FIFO (SM0) with timeout
// Returns byte on success, 0xFFFFFFFF on timeout
static uint32_t slave_read_byte(void) {
    for (int i = 0; i < TIMEOUT_CYCLES; i++) {
        if (!pio_sm_is_rx_fifo_empty(pio0, 0)) {
            uint32_t raw = pio_sm_get(pio0, 0);
            uint8_t byte = raw & 0xFF;
            pio0->irq = (1u << 0);  // Clear SM0's IRQ flag
            return byte;
        }
    }
    puts("  TIMEOUT: slave_read_byte (RX FIFO empty)\n");
    dump_debug_state();
    total_errors++;
    timed_out = 1;
    return 0xFFFFFFFF;
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
    uint32_t addr_byte = slave_read_byte();
    if (addr_byte == 0xFFFFFFFF) return;  // timed out
    check("Slave received addr byte", addr_byte, (SLAVE_ADDR << 1) | 0);

    // Check ACK was received by master
    uint32_t status = DEV_READ(I2C_STATUS, 0);
    check("Master got ACK for addr", (status >> 1) & 1, 1);

    // Send data byte with STOP
    i2c_master_send_byte_stop(0xAB);

    // Read data byte from PIO slave
    uint32_t data = slave_read_byte();
    if (data == 0xFFFFFFFF) return;  // timed out
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
    uint32_t addr = slave_read_byte();
    if (addr == 0xFFFFFFFF) return;
    check("Multi: addr byte", addr, (SLAVE_ADDR << 1) | 0);

    // Send data bytes
    for (int i = 0; i < 3; i++) {
        i2c_master_send_byte(tx_data[i]);
        uint32_t got = slave_read_byte();
        if (got == 0xFFFFFFFF) return;
        if (i == 0) check("Multi: data[0]=0x11", got, 0x11);
        else if (i == 1) check("Multi: data[1]=0x22", got, 0x22);
        else check("Multi: data[2]=0x33", got, 0x33);
    }

    // Last byte with STOP
    i2c_master_send_byte_stop(tx_data[3]);
    uint32_t last = slave_read_byte();
    if (last == 0xFFFFFFFF) return;
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
    if (slave_read_byte() == 0xFFFFFFFF) return;  // address byte

    for (int i = 0; i < 4; i++) {
        if (i < 3)
            i2c_master_send_byte(patterns[i]);
        else
            i2c_master_send_byte_stop(patterns[i]);

        uint32_t got = slave_read_byte();
        if (got == 0xFFFFFFFF) return;
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
    if (slave_read_byte() == 0xFFFFFFFF) return;  // address
    i2c_master_send_byte_stop(0xDE);
    uint32_t got1 = slave_read_byte();
    if (got1 == 0xFFFFFFFF) return;
    check("Back-to-back: tx1 data=0xDE", got1, 0xDE);

    // Restart slave between transactions (PIO program has no STOP detection)
    pio_sm_restart(pio0, 0);
    pio_sm_set_enabled(pio0, 0, true);
    spin(200);

    // Second transaction
    i2c_master_start_write(SLAVE_ADDR);
    if (slave_read_byte() == 0xFFFFFFFF) return;  // address
    i2c_master_send_byte_stop(0xAD);
    uint32_t got2 = slave_read_byte();
    if (got2 == 0xFFFFFFFF) return;
    check("Back-to-back: tx2 data=0xAD", got2, 0xAD);
}

// -----------------------------------------------------------------------
// Test 6: Single byte read (master reads from PIO slave via SM1)
// -----------------------------------------------------------------------
static void test_single_byte_read(void) {
    puts("\n[Test: Single Byte Read]\n");

    // Restart both SMs, clear FIFOs
    pio_sm_restart(pio0, 0);
    pio_sm_restart(pio0, 1);
    pio_sm_clear_fifos(pio0, 0);
    pio_sm_clear_fifos(pio0, 1);
    pio_sm_set_enabled(pio0, 0, true);
    pio_sm_set_enabled(pio0, 1, true);
    spin(100);

    // Master sends START + addr(0x42, R)
    i2c_master_start_read(SLAVE_ADDR);
    if (timed_out) return;

    // SM0 received address byte
    uint32_t addr_byte = slave_read_byte();
    if (addr_byte == 0xFFFFFFFF) return;
    check("Read: addr byte", addr_byte, (SLAVE_ADDR << 1) | 1);

    // Disable SM0 so it doesn't try to read data bits or drive ACK
    pio_sm_set_enabled(pio0, 0, false);

    // Load data into SM1 TX FIFO (bit-inverted, left-aligned for shift-left)
    uint8_t tx_val = 0xBE;
    pio_sm_put_blocking(pio0, 1, (uint32_t)(~tx_val & 0xFFu) << 24);

    // Signal SM1 to start transmitting
    pio0->irq_force = (1u << 4);
    spin(10);  // SM1 wakes, pulls data, sets up first bit on SDA

    // Master reads byte with NAK + STOP (single byte read)
    uint32_t rx_val = i2c_master_read_byte_nak_stop();
    if (rx_val == 0xFFFFFFFF) return;
    check("Read: data=0xBE", rx_val, 0xBE);
}

// -----------------------------------------------------------------------
// Test 7: Multi-byte read (master reads 4 bytes from PIO slave)
// -----------------------------------------------------------------------
static void test_multi_byte_read(void) {
    puts("\n[Test: Multi-Byte Read]\n");

    uint8_t tx_data[] = {0x11, 0x22, 0x33, 0x44};

    // Restart both SMs, clear FIFOs
    pio_sm_restart(pio0, 0);
    pio_sm_restart(pio0, 1);
    pio_sm_clear_fifos(pio0, 0);
    pio_sm_clear_fifos(pio0, 1);
    pio_sm_set_enabled(pio0, 0, true);
    pio_sm_set_enabled(pio0, 1, true);
    spin(100);

    // Master sends START + addr(0x42, R)
    i2c_master_start_read(SLAVE_ADDR);
    if (timed_out) return;

    // SM0 received address byte
    uint32_t addr = slave_read_byte();
    if (addr == 0xFFFFFFFF) return;
    check("Multi-read: addr byte", addr, (SLAVE_ADDR << 1) | 1);

    // Disable SM0 to prevent interference during data phase
    pio_sm_set_enabled(pio0, 0, false);

    // Read 4 bytes: SM1 transmits, master reads
    for (int i = 0; i < 4; i++) {
        // Load byte into SM1 FIFO and signal it
        pio_sm_put_blocking(pio0, 1, (uint32_t)(~tx_data[i] & 0xFFu) << 24);
        pio0->irq_force = (1u << 4);  // Wake SM1 via IRQ 4
        spin(10);

        // Master reads byte
        uint32_t got;
        if (i < 3) {
            // Middle bytes: ACK, no STOP
            got = i2c_master_read_byte_ack();
        } else {
            // Last byte: NAK + STOP
            got = i2c_master_read_byte_nak_stop();
        }
        if (got == 0xFFFFFFFF) return;

        if (i == 0) check("Multi-read: data[0]=0x11", got, 0x11);
        else if (i == 1) check("Multi-read: data[1]=0x22", got, 0x22);
        else if (i == 2) check("Multi-read: data[2]=0x33", got, 0x33);
        else check("Multi-read: data[3]=0x44", got, 0x44);

        // Clear SM1's IRQ (relative flag 0 for SM1 = flag 1)
        // so it returns to wait_signal for the next byte
        if (i < 3) {
            spin(10);
            pio0->irq = (1u << 1);
        }
    }
}

// -----------------------------------------------------------------------
// Test 8: Clock stretching (delayed CPU servicing)
// -----------------------------------------------------------------------
static void test_clock_stretching(void) {
    puts("\n[Test: Clock Stretching]\n");

    // Restart SM0 for write test
    pio_sm_restart(pio0, 0);
    pio_sm_clear_fifos(pio0, 0);
    pio_sm_set_enabled(pio0, 0, true);
    spin(100);

    // Master sends START + addr + 2 data bytes + STOP
    // The CPU deliberately delays between sending and reading
    // to verify the master-slave handshake tolerates processing delays
    // (master holds SCL low in WAIT_NEXT while CPU is busy)
    i2c_master_start_write(SLAVE_ADDR);

    uint32_t addr = slave_read_byte();
    if (addr == 0xFFFFFFFF) return;

    // Long CPU processing delay — master waits in WAIT_NEXT
    spin(1000);

    // Send first data byte
    i2c_master_send_byte(0xCA);

    // Another long delay before reading slave FIFO
    spin(1000);

    uint32_t got1 = slave_read_byte();
    if (got1 == 0xFFFFFFFF) return;
    check("Stretch: data[0]=0xCA after delay", got1, 0xCA);

    // Send second data byte with STOP
    i2c_master_send_byte_stop(0xFE);

    spin(500);

    uint32_t got2 = slave_read_byte();
    if (got2 == 0xFFFFFFFF) return;
    check("Stretch: data[1]=0xFE after delay", got2, 0xFE);
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------
int main(void) {
    puts("=== I2C Loopback Test ===\n");

    setup_pio_slave();
    test_program_load();
    if (!timed_out) test_single_byte_write();
    if (!timed_out) test_multi_byte_write();
    if (!timed_out) test_data_patterns();
    if (!timed_out) test_back_to_back();
    if (!timed_out) test_single_byte_read();
    if (!timed_out) test_multi_byte_read();
    if (!timed_out) test_clock_stretching();
    if (timed_out) puts("\n*** ABORTED: timeout — remaining tests skipped ***\n");

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
