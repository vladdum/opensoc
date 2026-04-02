// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * AES Crypto Cluster Integration Test
 *
 * Tests basic AES-128 ECB encryption/decryption through the crypto_cluster
 * wrapper (mem interface → TL-UL → OpenTitan AES).
 *
 * Uses NIST FIPS-197 Appendix B test vector:
 *   Key:       2b7e1516 28aed2a6 abf71588 09cf4f3c
 *   Plaintext: 3243f6a8 885a308d 313198a2 e0370734
 *   Ciphertext:3925841d 02dc09fb dc118597 196a0b32
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"

// NIST FIPS-197 Appendix B test vector
// OpenTitan AES uses native little-endian word ordering — the NIST test vector
// bytes map directly to 32-bit LE words without byte swapping.
// Key bytes:  2b 7e 15 16 | 28 ae d2 a6 | ab f7 15 88 | 09 cf 4f 3c
// As LE u32:  0x16157e2b    0xa6d2ae28    0x8815f7ab    0x3c4fcf09
static const uint32_t key[4] = {
  0x16157e2b, 0xa6d2ae28, 0x8815f7ab, 0x3c4fcf09
};

// Plaintext bytes: 32 43 f6 a8 | 88 5a 30 8d | 31 31 98 a2 | e0 37 07 34
static const uint32_t plaintext[4] = {
  0xa8f64332, 0x8d305a88, 0xa2983131, 0x340737e0
};

// Expected ciphertext bytes: 39 25 84 1d | 02 dc 09 fb | dc 11 85 97 | 19 6a 0b 32
static const uint32_t expected_ciphertext[4] = {
  0x1d842539, 0xfb09dc02, 0x978511dc, 0x320b6a19
};

static int errors = 0;

static void check32(const char *name, uint32_t actual, uint32_t expected) {
  if (actual == expected) {
    puts("[PASS] ");
    puts(name);
    puts(": 0x");
    puthex(actual);
    putchar('\n');
  } else {
    puts("[FAIL] ");
    puts(name);
    puts(": got 0x");
    puthex(actual);
    puts(", expected 0x");
    puthex(expected);
    putchar('\n');
    errors++;
  }
}

// Wait for a specific status bit to be set
static void wait_for_status(uint32_t mask) {
  uint32_t status;
  int timeout = 100000;
  do {
    status = DEV_READ(AES_STATUS, 0);
    timeout--;
  } while (!(status & mask) && timeout > 0);

  if (timeout <= 0) {
    puts("TIMEOUT waiting for status 0x");
    puthex(mask);
    putchar('\n');
    errors++;
  }
}

// Write to a shadowed register (must be written twice with same value)
static void write_shadowed(uint32_t addr, uint32_t val) {
  DEV_WRITE(addr, val);
  DEV_WRITE(addr, val);
}

int main(int argc, char **argv) {
  uint32_t status;
  uint32_t data_out[4];

  puts("=== AES Crypto Cluster Integration Test ===\n\n");

  // -----------------------------------------------------------------------
  // Phase 1: Check initial status (IDLE after reset)
  // -----------------------------------------------------------------------
  puts("--- Phase 1: Reset status ---\n");
  wait_for_status(AES_STATUS_IDLE);
  status = DEV_READ(AES_STATUS, 0);
  puts("STATUS after reset: 0x");
  puthex(status);
  putchar('\n');

  if (!(status & AES_STATUS_IDLE)) {
    puts("FAIL: AES not idle after reset\n");
    return 1;
  }
  puts("AES is idle\n\n");

  // -----------------------------------------------------------------------
  // Phase 2: Configure AES-128 ECB encryption (auto mode)
  // -----------------------------------------------------------------------
  puts("--- Phase 2: Configure AES-128 ECB encrypt ---\n");

  // CTRL is a shadowed register — write twice
  uint32_t ctrl_val = AES_OP_ENC | AES_MODE_ECB | AES_KEY_128;
  write_shadowed(AES_CTRL, ctrl_val);
  puts("CTRL written: 0x");
  puthex(ctrl_val);
  putchar('\n');

  // -----------------------------------------------------------------------
  // Phase 3: Load key (share 0 only, share 1 = 0 since no masking)
  // -----------------------------------------------------------------------
  puts("--- Phase 3: Load key ---\n");
  for (int i = 0; i < 4; i++) {
    DEV_WRITE(AES_KEY_SHARE0(i), key[i]);
  }
  // Clear upper key words (128-bit key uses only words 0-3)
  for (int i = 4; i < 8; i++) {
    DEV_WRITE(AES_KEY_SHARE0(i), 0);
  }
  // Key share 1 = 0 (no masking)
  for (int i = 0; i < 8; i++) {
    DEV_WRITE(AES_KEY_SHARE1(i), 0);
  }
  puts("Key loaded\n");

  // -----------------------------------------------------------------------
  // Phase 4: Load plaintext (triggers encryption in auto mode)
  // -----------------------------------------------------------------------
  puts("--- Phase 4: Load plaintext & encrypt ---\n");

  // Wait for INPUT_READY
  wait_for_status(AES_STATUS_INPUT_READY);

  for (int i = 0; i < 4; i++) {
    DEV_WRITE(AES_DATA_IN(i), plaintext[i]);
  }
  puts("Plaintext loaded, encryption started\n");

  // -----------------------------------------------------------------------
  // Phase 5: Wait for output and read ciphertext
  // -----------------------------------------------------------------------
  puts("--- Phase 5: Read ciphertext ---\n");

  wait_for_status(AES_STATUS_OUTPUT_VALID);

  for (int i = 0; i < 4; i++) {
    data_out[i] = DEV_READ(AES_DATA_OUT(i), 0);
  }

  puts("Ciphertext:\n");
  for (int i = 0; i < 4; i++) {
    puts("  DATA_OUT[");
    putchar('0' + i);
    puts("] = 0x");
    puthex(data_out[i]);
    putchar('\n');
  }

  // Verify against NIST vector
  putchar('\n');
  check32("CT[0]", data_out[0], expected_ciphertext[0]);
  check32("CT[1]", data_out[1], expected_ciphertext[1]);
  check32("CT[2]", data_out[2], expected_ciphertext[2]);
  check32("CT[3]", data_out[3], expected_ciphertext[3]);

  // -----------------------------------------------------------------------
  // Phase 6: Decrypt the ciphertext back to plaintext
  // -----------------------------------------------------------------------
  puts("\n--- Phase 6: Decrypt back to plaintext ---\n");

  // Reconfigure for decryption
  ctrl_val = AES_OP_DEC | AES_MODE_ECB | AES_KEY_128;
  write_shadowed(AES_CTRL, ctrl_val);

  // Reload key (key registers are cleared after use)
  for (int i = 0; i < 4; i++) {
    DEV_WRITE(AES_KEY_SHARE0(i), key[i]);
  }
  for (int i = 4; i < 8; i++) {
    DEV_WRITE(AES_KEY_SHARE0(i), 0);
  }
  for (int i = 0; i < 8; i++) {
    DEV_WRITE(AES_KEY_SHARE1(i), 0);
  }

  // Wait for INPUT_READY, then load ciphertext
  wait_for_status(AES_STATUS_INPUT_READY);

  for (int i = 0; i < 4; i++) {
    DEV_WRITE(AES_DATA_IN(i), data_out[i]);
  }
  puts("Ciphertext loaded, decryption started\n");

  // Wait for output
  wait_for_status(AES_STATUS_OUTPUT_VALID);

  uint32_t dec_out[4];
  for (int i = 0; i < 4; i++) {
    dec_out[i] = DEV_READ(AES_DATA_OUT(i), 0);
  }

  puts("Decrypted:\n");
  for (int i = 0; i < 4; i++) {
    puts("  DATA_OUT[");
    putchar('0' + i);
    puts("] = 0x");
    puthex(dec_out[i]);
    putchar('\n');
  }

  // Verify round-trip
  putchar('\n');
  check32("PT[0]", dec_out[0], plaintext[0]);
  check32("PT[1]", dec_out[1], plaintext[1]);
  check32("PT[2]", dec_out[2], plaintext[2]);
  check32("PT[3]", dec_out[3], plaintext[3]);

  // -----------------------------------------------------------------------
  // Phase 7: Clear and check idle
  // -----------------------------------------------------------------------
  puts("\n--- Phase 7: Clear and verify idle ---\n");
  DEV_WRITE(AES_TRIGGER, AES_TRIGGER_KEY_IV_DATA_CLEAR
                        | AES_TRIGGER_DATA_OUT_CLEAR);

  wait_for_status(AES_STATUS_IDLE);
  status = DEV_READ(AES_STATUS, 0);
  puts("STATUS after clear: 0x");
  puthex(status);
  putchar('\n');

  if (!(status & AES_STATUS_IDLE)) {
    puts("FAIL: not idle after clear\n");
    errors++;
  }

  // -----------------------------------------------------------------------
  // Result
  // -----------------------------------------------------------------------
  putchar('\n');
  if (errors == 0) {
    puts("PASS: AES-128 ECB encrypt + decrypt verified (NIST FIPS-197)\n");
  } else {
    puts("FAIL: ");
    puthex(errors);
    puts(" errors\n");
  }

  return errors;
}
