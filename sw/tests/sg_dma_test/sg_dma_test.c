// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Scatter-Gather DMA Engine Test
 *
 * Exercises the descriptor-based DMA engine with test cases:
 * single descriptor copy, chained transfers, zero-length descriptors,
 * register readback, GO while BUSY, back-to-back, and throughput.
 */

#include "simple_system_common.h"
#include <stdint.h>

// ---------------------------------------------------------------------------
// SG DMA registers (base 0x90000)
// ---------------------------------------------------------------------------
#define SGDMA_BASE          0x90000
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

// ---------------------------------------------------------------------------
// Descriptor struct layout (must be word-aligned, 20 bytes)
// ---------------------------------------------------------------------------
typedef struct __attribute__((packed, aligned(4))) {
  uint32_t src_addr;
  uint32_t dst_addr;
  uint32_t word_len;
  uint32_t ctrl;       // [0] IRQ_ON_DONE, [1] CHAIN
  uint32_t next_desc_addr;
} sg_desc_t;

#define DESC_CTRL_IRQ_ON_DONE 0x1
#define DESC_CTRL_CHAIN       0x2

// ---------------------------------------------------------------------------
// Test buffers
// ---------------------------------------------------------------------------
static uint32_t src_buf[256] __attribute__((aligned(4)));
static uint32_t dst_buf[256] __attribute__((aligned(4)));

// Separate source regions for chained tests
static uint32_t src_a[4] __attribute__((aligned(4)));
static uint32_t src_b[4] __attribute__((aligned(4)));
static uint32_t src_c[4] __attribute__((aligned(4)));
static uint32_t dst_a[4] __attribute__((aligned(4)));
static uint32_t dst_b[4] __attribute__((aligned(4)));
static uint32_t dst_c[4] __attribute__((aligned(4)));

// Descriptors
static sg_desc_t desc1 __attribute__((aligned(4)));
static sg_desc_t chain_descs[3] __attribute__((aligned(4)));

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

static void run_sgdma(sg_desc_t *desc) {
  DEV_WRITE(SGDMA_DESC_ADDR, (uint32_t)desc);
  DEV_WRITE(SGDMA_CTRL, SGDMA_CTRL_GO);

  // Poll until done
  uint32_t status;
  do {
    status = DEV_READ(SGDMA_STATUS, 0);
  } while (!(status & SGDMA_STATUS_DONE));
}

static void check(const char *name, int pass) {
  test_num++;
  if (pass) {
    puts("  PASS #");
    putdec(test_num);
    puts(": ");
    puts(name);
    putchar('\n');
  } else {
    total_errors++;
    puts("  FAIL #");
    putdec(test_num);
    puts(": ");
    puts(name);
    putchar('\n');
  }
}

static void check_val(const char *name, uint32_t got, uint32_t expected) {
  test_num++;
  if (got == expected) {
    puts("  PASS #");
    putdec(test_num);
    puts(": ");
    puts(name);
    putchar('\n');
  } else {
    total_errors++;
    puts("  FAIL #");
    putdec(test_num);
    puts(": ");
    puts(name);
    puts(" got=");
    putdec(got);
    puts(" exp=");
    putdec(expected);
    putchar('\n');
  }
}

// ---------------------------------------------------------------------------
// Test 1: Single descriptor, 8-word copy
// ---------------------------------------------------------------------------
static void test_single_8word(void) {
  for (int i = 0; i < 8; i++) {
    src_buf[i] = 0xA0000000 + i;
    dst_buf[i] = 0;
  }
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 8;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  run_sgdma(&desc1);

  int ok = 1;
  for (int i = 0; i < 8; i++) {
    if (dst_buf[i] != src_buf[i]) ok = 0;
  }
  check("single desc 8-word copy", ok);
}

// ---------------------------------------------------------------------------
// Test 2: Single descriptor, 1-word copy
// ---------------------------------------------------------------------------
static void test_single_1word(void) {
  src_buf[0] = 0xDEADBEEF;
  dst_buf[0] = 0;

  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 1;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  run_sgdma(&desc1);

  check_val("single desc 1-word copy", dst_buf[0], 0xDEADBEEF);
}

// ---------------------------------------------------------------------------
// Test 3: Single descriptor, word_len=0 (should complete immediately)
// ---------------------------------------------------------------------------
static void test_zero_len(void) {
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 0;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  run_sgdma(&desc1);

  uint32_t cnt = DEV_READ(SGDMA_COMPLETED_CNT, 0);
  check_val("zero-length desc COMPLETED_CNT=1", cnt, 1);
}

// ---------------------------------------------------------------------------
// Test 4: Chained 3-descriptor transfer
// ---------------------------------------------------------------------------
static void test_chain_3desc(void) {
  // Set up source data
  for (int i = 0; i < 4; i++) {
    src_a[i] = 0x1000 + i;
    src_b[i] = 0x2000 + i;
    src_c[i] = 0x3000 + i;
    dst_a[i] = 0;
    dst_b[i] = 0;
    dst_c[i] = 0;
  }

  // Descriptor chain: A → B → C
  chain_descs[0].src_addr       = (uint32_t)src_a;
  chain_descs[0].dst_addr       = (uint32_t)dst_a;
  chain_descs[0].word_len       = 4;
  chain_descs[0].ctrl           = DESC_CTRL_CHAIN;
  chain_descs[0].next_desc_addr = (uint32_t)&chain_descs[1];

  chain_descs[1].src_addr       = (uint32_t)src_b;
  chain_descs[1].dst_addr       = (uint32_t)dst_b;
  chain_descs[1].word_len       = 4;
  chain_descs[1].ctrl           = DESC_CTRL_CHAIN;
  chain_descs[1].next_desc_addr = (uint32_t)&chain_descs[2];

  chain_descs[2].src_addr       = (uint32_t)src_c;
  chain_descs[2].dst_addr       = (uint32_t)dst_c;
  chain_descs[2].word_len       = 4;
  chain_descs[2].ctrl           = 0; // Last descriptor, no chain
  chain_descs[2].next_desc_addr = 0;

  run_sgdma(&chain_descs[0]);

  // Verify all copies
  int ok = 1;
  for (int i = 0; i < 4; i++) {
    if (dst_a[i] != src_a[i]) ok = 0;
    if (dst_b[i] != src_b[i]) ok = 0;
    if (dst_c[i] != src_c[i]) ok = 0;
  }
  check("3-desc chain data correct", ok);

  uint32_t cnt = DEV_READ(SGDMA_COMPLETED_CNT, 0);
  check_val("3-desc chain COMPLETED_CNT=3", cnt, 3);
}

// ---------------------------------------------------------------------------
// Test 5: Register readback
// ---------------------------------------------------------------------------
static void test_register_readback(void) {
  DEV_WRITE(SGDMA_DESC_ADDR, 0x12345678);
  DEV_WRITE(SGDMA_IER, 1);

  int ok = 1;
  if (DEV_READ(SGDMA_DESC_ADDR, 0) != 0x12345678) ok = 0;
  if (DEV_READ(SGDMA_IER, 0) != 1) ok = 0;
  // STATUS should show DONE from previous test, not busy
  uint32_t status = DEV_READ(SGDMA_STATUS, 0);
  if (status & SGDMA_STATUS_BUSY) ok = 0;

  check("register readback", ok);

  // Clean up
  DEV_WRITE(SGDMA_IER, 0);
}

// ---------------------------------------------------------------------------
// Test 6: GO while BUSY is ignored
// ---------------------------------------------------------------------------
static void test_go_while_busy(void) {
  // Set up a large transfer (64 words)
  for (int i = 0; i < 64; i++) {
    src_buf[i] = 0xBB000000 + i;
    dst_buf[i] = 0;
  }
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 64;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  DEV_WRITE(SGDMA_DESC_ADDR, (uint32_t)&desc1);
  DEV_WRITE(SGDMA_CTRL, SGDMA_CTRL_GO);

  // Immediately try a second GO — should be ignored
  DEV_WRITE(SGDMA_CTRL, SGDMA_CTRL_GO);

  // Wait for completion
  uint32_t status;
  do {
    status = DEV_READ(SGDMA_STATUS, 0);
  } while (!(status & SGDMA_STATUS_DONE));

  // Verify first transfer completed correctly
  int ok = 1;
  for (int i = 0; i < 64; i++) {
    if (dst_buf[i] != src_buf[i]) ok = 0;
  }
  check("GO while BUSY ignored", ok);
}

// ---------------------------------------------------------------------------
// Test 7: Back-to-back operations
// ---------------------------------------------------------------------------
static void test_back_to_back(void) {
  // First transfer
  for (int i = 0; i < 4; i++) {
    src_buf[i] = 0xCC000000 + i;
    dst_buf[i] = 0;
  }
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 4;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  run_sgdma(&desc1);

  // Second transfer with different data
  for (int i = 0; i < 4; i++) {
    src_buf[i] = 0xDD000000 + i;
    dst_buf[i + 4] = 0;
  }
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)(dst_buf + 4);
  desc1.word_len       = 4;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  run_sgdma(&desc1);

  int ok = 1;
  for (int i = 0; i < 4; i++) {
    if (dst_buf[i] != (0xCC000000 + (uint32_t)i)) ok = 0;
    if (dst_buf[i + 4] != (0xDD000000 + (uint32_t)i)) ok = 0;
  }
  check("back-to-back operations", ok);
}

// ---------------------------------------------------------------------------
// Test 8: Chain with zero-length descriptor in the middle
// ---------------------------------------------------------------------------
static void test_chain_with_zero_len(void) {
  for (int i = 0; i < 4; i++) {
    src_a[i] = 0x4000 + i;
    dst_a[i] = 0;
    src_c[i] = 0x6000 + i;
    dst_c[i] = 0;
  }

  // Desc 0: 4-word copy → chain → desc 1 (zero-len) → chain → desc 2 (4-word copy)
  chain_descs[0].src_addr       = (uint32_t)src_a;
  chain_descs[0].dst_addr       = (uint32_t)dst_a;
  chain_descs[0].word_len       = 4;
  chain_descs[0].ctrl           = DESC_CTRL_CHAIN;
  chain_descs[0].next_desc_addr = (uint32_t)&chain_descs[1];

  chain_descs[1].src_addr       = 0;
  chain_descs[1].dst_addr       = 0;
  chain_descs[1].word_len       = 0; // Zero length — skip
  chain_descs[1].ctrl           = DESC_CTRL_CHAIN;
  chain_descs[1].next_desc_addr = (uint32_t)&chain_descs[2];

  chain_descs[2].src_addr       = (uint32_t)src_c;
  chain_descs[2].dst_addr       = (uint32_t)dst_c;
  chain_descs[2].word_len       = 4;
  chain_descs[2].ctrl           = 0;
  chain_descs[2].next_desc_addr = 0;

  run_sgdma(&chain_descs[0]);

  int ok = 1;
  for (int i = 0; i < 4; i++) {
    if (dst_a[i] != src_a[i]) ok = 0;
    if (dst_c[i] != src_c[i]) ok = 0;
  }
  check("chain with zero-len middle desc", ok);

  uint32_t cnt = DEV_READ(SGDMA_COMPLETED_CNT, 0);
  check_val("chain zero-len COMPLETED_CNT=3", cnt, 3);
}

// ---------------------------------------------------------------------------
// Test 9: Large transfer (256 words) + throughput
// ---------------------------------------------------------------------------
static void test_throughput(void) {
  for (int i = 0; i < 256; i++) {
    src_buf[i] = 0xEE000000 + i;
    dst_buf[i] = 0;
  }
  desc1.src_addr       = (uint32_t)src_buf;
  desc1.dst_addr       = (uint32_t)dst_buf;
  desc1.word_len       = 256;
  desc1.ctrl           = 0;
  desc1.next_desc_addr = 0;

  pcount_reset();
  pcount_enable(1);

  run_sgdma(&desc1);

  pcount_enable(0);

  uint32_t cycles;
  PCOUNT_READ(mcycle, cycles);

  int ok = 1;
  for (int i = 0; i < 256; i++) {
    if (dst_buf[i] != src_buf[i]) ok = 0;
  }
  check("256-word transfer data correct", ok);

  test_num++;
  puts("  INFO #");
  putdec(test_num);
  puts(": throughput 256 words in ");
  putdec(cycles);
  puts(" cycles = ");
  putdec(cycles / 256);
  putchar('.');
  putdec((cycles % 256) * 10 / 256);
  puts(" cyc/word\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
  puts("=== Scatter-Gather DMA Engine Test ===\n\n");

  test_single_8word();
  test_single_1word();
  test_zero_len();
  test_chain_3desc();
  test_register_readback();
  test_go_while_busy();
  test_back_to_back();
  test_chain_with_zero_len();
  test_throughput();

  puts("\n--- Summary ---\n");
  putdec(test_num);
  puts(" tests, ");
  putdec(total_errors);
  puts(" failures\n");

  if (total_errors == 0) {
    puts("PASS: all tests passed\n");
  } else {
    puts("FAIL\n");
  }

  return 0;
}
