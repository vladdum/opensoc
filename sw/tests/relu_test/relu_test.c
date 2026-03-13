// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * ReLU Accelerator Throughput Test
 *
 * Exercises the ReLU accelerator's full DMA data path by processing a large
 * array through the crossbar (ReLU DMA master → RAM slave). Measures
 * sustained throughput in cycles using hardware performance counters, then
 * verifies every output word.
 *
 * Data pattern: src[i] = (i even) ? +(i+1) : -(i+1)
 *   → expected[i] = (i even) ? (i+1) : 0
 */

#include "simple_system_common.h"

// ---------------------------------------------------------------------------
// ReLU accelerator registers (base 0x70000)
// ---------------------------------------------------------------------------
#define RELU_BASE       0x70000
#define RELU_SRC_ADDR   (RELU_BASE + 0x00)
#define RELU_DST_ADDR   (RELU_BASE + 0x04)
#define RELU_LEN        (RELU_BASE + 0x08)
#define RELU_CTRL       (RELU_BASE + 0x0C)
#define RELU_STATUS     (RELU_BASE + 0x10)
#define RELU_IER        (RELU_BASE + 0x14)

#define RELU_STATUS_BUSY 0x1
#define RELU_STATUS_DONE 0x2

// ---------------------------------------------------------------------------
// Test buffer size — 8192 words (32 KB per array, 64 KB total)
// ---------------------------------------------------------------------------
#define NUM_WORDS 8192

static int32_t src_data[NUM_WORDS] __attribute__((aligned(4)));
static int32_t dst_data[NUM_WORDS] __attribute__((aligned(4)));

// ---------------------------------------------------------------------------
// Helper: print uint32 in decimal (up to 10 digits)
// ---------------------------------------------------------------------------
static void putdec(uint32_t v) {
  char buf[11];
  int pos = 0;

  if (v == 0) {
    putchar('0');
    return;
  }
  while (v > 0) {
    buf[pos++] = '0' + (v % 10);
    v /= 10;
  }
  // Print in reverse
  while (pos > 0) {
    putchar(buf[--pos]);
  }
}

int main(int argc, char **argv) {
  uint32_t cycles;
  uint32_t status;
  int errors = 0;

  puts("=== ReLU Accelerator Throughput Test ===\n");
  puts("Buffer: ");
  putdec(NUM_WORDS);
  puts(" words (");
  putdec(NUM_WORDS * 4 / 1024);
  puts(" KB per array)\n");

  // -----------------------------------------------------------------------
  // Phase 1: Fill source buffer
  // -----------------------------------------------------------------------
  //   even indices: positive  (1, 3, 5, ...)
  //   odd indices:  negative  (-2, -4, -6, ...)
  for (int i = 0; i < NUM_WORDS; i++) {
    src_data[i] = (i & 1) ? -(int32_t)(i + 1) : (int32_t)(i + 1);
  }

  // Clear destination
  for (int i = 0; i < NUM_WORDS; i++) {
    dst_data[i] = (int32_t)0xDEADBEEF;
  }

  // -----------------------------------------------------------------------
  // Phase 2: Configure and launch accelerator
  // -----------------------------------------------------------------------
  DEV_WRITE(RELU_SRC_ADDR, (uint32_t)src_data);
  DEV_WRITE(RELU_DST_ADDR, (uint32_t)dst_data);
  DEV_WRITE(RELU_LEN,      NUM_WORDS);

  // Verify config readback
  if (DEV_READ(RELU_SRC_ADDR, 0) != (uint32_t)src_data) {
    puts("FAIL: SRC_ADDR readback mismatch\n");
    return 1;
  }
  if (DEV_READ(RELU_DST_ADDR, 0) != (uint32_t)dst_data) {
    puts("FAIL: DST_ADDR readback mismatch\n");
    return 1;
  }
  if (DEV_READ(RELU_LEN, 0) != NUM_WORDS) {
    puts("FAIL: LEN readback mismatch\n");
    return 1;
  }
  puts("Config registers verified\n");

  // Confirm idle before start
  status = DEV_READ(RELU_STATUS, 0);
  if (status & RELU_STATUS_BUSY) {
    puts("FAIL: accelerator busy before GO\n");
    return 1;
  }

  // -----------------------------------------------------------------------
  // Phase 3: Timed DMA run
  // -----------------------------------------------------------------------
  pcount_reset();
  pcount_enable(1);

  // Fire!
  DEV_WRITE(RELU_CTRL, 1);

  // Confirm it went busy
  status = DEV_READ(RELU_STATUS, 0);
  if (!(status & RELU_STATUS_BUSY)) {
    puts("WARN: not BUSY immediately after GO\n");
  }

  // Poll until done
  do {
    status = DEV_READ(RELU_STATUS, 0);
  } while (!(status & RELU_STATUS_DONE));

  pcount_enable(0);

  // Read cycle count (counters were reset before GO, so this is total)
  PCOUNT_READ(mcycle, cycles);

  // -----------------------------------------------------------------------
  // Phase 4: Report throughput
  // -----------------------------------------------------------------------
  puts("\n--- Throughput ---\n");
  puts("Total cycles:  ");
  putdec(cycles);
  puts(" (0x");
  puthex(cycles);
  puts(")\n");

  puts("Words processed: ");
  putdec(NUM_WORDS);
  putchar('\n');

  uint32_t cycles_per_word = cycles / NUM_WORDS;
  uint32_t remainder       = cycles % NUM_WORDS;
  puts("Cycles/word:   ");
  putdec(cycles_per_word);
  putchar('.');
  // One decimal place
  putdec((remainder * 10) / NUM_WORDS);
  putchar('\n');

  uint32_t dma_reads  = NUM_WORDS;
  uint32_t dma_writes = NUM_WORDS;
  puts("DMA transfers: ");
  putdec(dma_reads + dma_writes);
  puts(" (");
  putdec(dma_reads);
  puts("R + ");
  putdec(dma_writes);
  puts("W)\n");

  // -----------------------------------------------------------------------
  // Phase 5: Verify every output word
  // -----------------------------------------------------------------------
  puts("\n--- Verification ---\n");
  for (int i = 0; i < NUM_WORDS; i++) {
    int32_t expected = (src_data[i] < 0) ? 0 : src_data[i];
    if (dst_data[i] != expected) {
      errors++;
      if (errors <= 8) {
        puts("  MISMATCH [");
        putdec((uint32_t)i);
        puts("]: src=0x");
        puthex((uint32_t)src_data[i]);
        puts(" got=0x");
        puthex((uint32_t)dst_data[i]);
        puts(" exp=0x");
        puthex((uint32_t)expected);
        putchar('\n');
      }
    }
  }

  if (errors > 8) {
    puts("  ... and ");
    putdec((uint32_t)(errors - 8));
    puts(" more errors\n");
  }

  // -----------------------------------------------------------------------
  // Result
  // -----------------------------------------------------------------------
  putchar('\n');
  if (errors == 0) {
    puts("PASS: all ");
    putdec(NUM_WORDS);
    puts(" words correct\n");
  } else {
    puts("FAIL: ");
    putdec((uint32_t)errors);
    puts(" / ");
    putdec(NUM_WORDS);
    puts(" words incorrect\n");
  }

  return 0;
}
