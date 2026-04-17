// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Vector MAC Accelerator Test
 *
 * Exercises the INT8 vector MAC accelerator with multiple test cases:
 * basic correctness, negative values, zero vectors, self-dot-product,
 * longer vectors, saturation, LEN=0, multi-kick accumulation,
 * register readback, DMA write-back, and throughput measurement.
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"
#include <stdint.h>

// ---------------------------------------------------------------------------
// Test buffers
// ---------------------------------------------------------------------------
static int8_t vec_a[256] __attribute__((aligned(4)));
static int8_t vec_b[256] __attribute__((aligned(4)));
static int32_t dst_result __attribute__((aligned(4)));

// Large buffers for throughput test
#define THROUGHPUT_ELEMS 1024
static int8_t big_a[THROUGHPUT_ELEMS] __attribute__((aligned(4)));
static int8_t big_b[THROUGHPUT_ELEMS] __attribute__((aligned(4)));
static int32_t big_dst __attribute__((aligned(4)));

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

static void putdec_signed(int32_t v) {
  if (v < 0) {
    putchar('-');
    putdec((uint32_t)(-(int64_t)v));
  } else {
    putdec((uint32_t)v);
  }
}


// Run a dot product and return the result
static int32_t run_vmac(const int8_t *a, const int8_t *b, int32_t *dst,
                        int len, int no_accum_clear) {
  DEV_WRITE(VMAC_SRC_A_ADDR, (uint32_t)(uintptr_t)a);
  DEV_WRITE(VMAC_SRC_B_ADDR, (uint32_t)(uintptr_t)b);
  DEV_WRITE(VMAC_DST_ADDR,   (uint32_t)(uintptr_t)dst);
  DEV_WRITE(VMAC_LEN,        len);

  uint32_t ctrl = VMAC_CTRL_GO;
  if (no_accum_clear) ctrl |= VMAC_CTRL_NO_ACCUM_CLEAR;
  DEV_WRITE(VMAC_CTRL, ctrl);

  // Poll until done
  uint32_t status;
  do {
    status = DEV_READ(VMAC_STATUS, 0);
  } while (!(status & VMAC_STATUS_DONE));

  return (int32_t)DEV_READ(VMAC_RESULT, 0);
}

static void check(const char *name, int32_t got, int32_t expected) {
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
    putdec_signed(got);
    puts(" exp=");
    putdec_signed(expected);
    putchar('\n');
  }
}

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

// Test 1: Basic correctness — A=[1,2,3,4], B=[5,6,7,8] → 70
static void test_basic(void) {
  vec_a[0]=1; vec_a[1]=2; vec_a[2]=3; vec_a[3]=4;
  vec_b[0]=5; vec_b[1]=6; vec_b[2]=7; vec_b[3]=8;
  dst_result = 0xDEADBEEF;
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 4, 0);
  check("basic dot(1..4, 5..8)=70", result, 70);
}

// Test 2: Negative values — A=[-1,-2,3,4], B=[5,6,-7,8] → -6
static void test_negative(void) {
  vec_a[0]=-1; vec_a[1]=-2; vec_a[2]=3; vec_a[3]=4;
  vec_b[0]=5;  vec_b[1]=6;  vec_b[2]=-7; vec_b[3]=8;
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 4, 0);
  // -1*5 + -2*6 + 3*-7 + 4*8 = -5 -12 -21 +32 = -6
  check("negative values=-6", result, -6);
}

// Test 3: Zero vector
static void test_zero(void) {
  vec_a[0]=0; vec_a[1]=0; vec_a[2]=0; vec_a[3]=0;
  vec_b[0]=1; vec_b[1]=2; vec_b[2]=3; vec_b[3]=4;
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 4, 0);
  check("zero vector=0", result, 0);
}

// Test 4: Self dot product (src_a == src_b) — A=[1,2,3,4] → 30
static void test_self_dot(void) {
  vec_a[0]=1; vec_a[1]=2; vec_a[2]=3; vec_a[3]=4;
  int32_t result = run_vmac(vec_a, vec_a, &dst_result, 4, 0);
  check("self dot(1..4)=30", result, 30);
}

// Test 5: Longer vector (32 elements)
static void test_longer(void) {
  int64_t expected_acc = 0;
  for (int i = 0; i < 32; i++) {
    vec_a[i] = (int8_t)(i + 1);        // 1..32
    vec_b[i] = (int8_t)(32 - i);       // 32..1
    expected_acc += (int64_t)(i + 1) * (int64_t)(32 - i);
  }
  int32_t expected = (int32_t)expected_acc;  // won't overflow for these values
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 32, 0);
  check("32-element dot", result, expected);
}

// Test 6: Positive saturation
static void test_pos_saturation(void) {
  // 127 * 127 = 16129 per lane, 4 lanes = 64516 per word
  // 256 elements = 64 words → 64 * 64516 = 4129024 — not enough
  // Need more: use all 256 elements of 127*127
  // 256/4 = 64 iterations, 64 * 64516 = 4,129,024 — still fits INT32
  // Use max: 127*127*256 = 4,129,024 — doesn't overflow INT32_MAX (2,147,483,647)
  // Instead: test with values that definitely overflow
  // 127*127=16129, need >2^31/16129 = 133,170 elements → impractical
  // Use 127*127 with NO_ACCUM_CLEAR over multiple kicks to accumulate enough
  for (int i = 0; i < 128; i++) {
    vec_a[i] = 127;
    vec_b[i] = 127;
  }
  // First kick: 128 elements → 128 * 16129 = 2,064,512
  run_vmac(vec_a, vec_b, &dst_result, 128, 0);
  // Keep kicking with NO_ACCUM_CLEAR until we overflow
  // 2,064,512 * 1024 rounds would overflow, but that's too many.
  // Instead: accumulate 1050 kicks of 128 elements each
  // 1050 * 2,064,512 would overflow on kick #1041 (2,064,512 * 1041 = 2,149,157,472 > INT32_MAX)
  // Simpler: just do a few rounds and check
  for (int k = 0; k < 1100; k++) {
    run_vmac(vec_a, vec_b, &dst_result, 128, 1);
  }
  int32_t result = (int32_t)DEV_READ(VMAC_RESULT, 0);
  check("positive saturation=INT32_MAX", result, 2147483647);
}

// Test 7: Negative saturation
static void test_neg_saturation(void) {
  for (int i = 0; i < 128; i++) {
    vec_a[i] = 127;
    vec_b[i] = -128;
  }
  // 127*(-128) = -16256 per lane, 4 lanes = -65024 per word
  // 128 elements = 32 words → -65024 * 32 = -2,080,768 per kick
  run_vmac(vec_a, vec_b, &dst_result, 128, 0);
  for (int k = 0; k < 1100; k++) {
    run_vmac(vec_a, vec_b, &dst_result, 128, 1);
  }
  int32_t result = (int32_t)DEV_READ(VMAC_RESULT, 0);
  check("negative saturation=INT32_MIN", result, (int32_t)(-2147483647 - 1));
}

// Test 8: LEN=0
static void test_len_zero(void) {
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 0, 0);
  check("LEN=0 result=0", result, 0);
}

// Test 9: Multi-kick NO_ACCUM_CLEAR
static void test_multi_kick(void) {
  // First dot product: [1,2,3,4] . [1,1,1,1] = 10
  vec_a[0]=1; vec_a[1]=2; vec_a[2]=3; vec_a[3]=4;
  vec_b[0]=1; vec_b[1]=1; vec_b[2]=1; vec_b[3]=1;
  run_vmac(vec_a, vec_b, &dst_result, 4, 0);

  // Second dot product without clearing: [5,6,7,8] . [1,1,1,1] = 26
  // Expected total: 10 + 26 = 36
  vec_a[0]=5; vec_a[1]=6; vec_a[2]=7; vec_a[3]=8;
  int32_t result = run_vmac(vec_a, vec_b, &dst_result, 4, 1);
  check("multi-kick 10+26=36", result, 36);
}

// Test 10: Register readback
static void test_register_readback(void) {
  DEV_WRITE(VMAC_SRC_A_ADDR, 0x12345678);
  DEV_WRITE(VMAC_SRC_B_ADDR, 0xAABBCCDD);
  DEV_WRITE(VMAC_DST_ADDR,   0x11223344);
  DEV_WRITE(VMAC_LEN,        0x00000100);

  int ok = 1;
  if (DEV_READ(VMAC_SRC_A_ADDR, 0) != 0x12345678) ok = 0;
  if (DEV_READ(VMAC_SRC_B_ADDR, 0) != 0xAABBCCDD) ok = 0;
  if (DEV_READ(VMAC_DST_ADDR, 0)   != 0x11223344) ok = 0;
  if (DEV_READ(VMAC_LEN, 0)        != 0x00000100) ok = 0;

  test_num++;
  if (ok) {
    puts("  PASS #");
    putdec(test_num);
    puts(": register readback\n");
  } else {
    total_errors++;
    puts("  FAIL #");
    putdec(test_num);
    puts(": register readback mismatch\n");
  }
}

// Test 11: DMA write-back — check DST_ADDR in memory
static void test_dma_writeback(void) {
  vec_a[0]=2; vec_a[1]=3; vec_a[2]=4; vec_a[3]=5;
  vec_b[0]=1; vec_b[1]=1; vec_b[2]=1; vec_b[3]=1;
  dst_result = 0xDEADBEEF;
  run_vmac(vec_a, vec_b, &dst_result, 4, 0);
  // 2+3+4+5 = 14
  check("DMA write-back mem=14", dst_result, 14);
}

// Test 12: Throughput measurement
static void test_throughput(void) {
  for (int i = 0; i < THROUGHPUT_ELEMS; i++) {
    big_a[i] = (int8_t)((i % 127) + 1);
    big_b[i] = (int8_t)((i % 63) + 1);
  }

  pcount_reset();
  pcount_enable(1);

  run_vmac(big_a, big_b, &big_dst, THROUGHPUT_ELEMS, 0);

  pcount_enable(0);

  uint32_t cycles;
  PCOUNT_READ(mcycle, cycles);

  test_num++;
  puts("  INFO #");
  putdec(test_num);
  puts(": throughput ");
  putdec(THROUGHPUT_ELEMS);
  puts(" elems in ");
  putdec(cycles);
  puts(" cycles = ");
  putdec(cycles / THROUGHPUT_ELEMS);
  putchar('.');
  putdec((cycles % THROUGHPUT_ELEMS) * 10 / THROUGHPUT_ELEMS);
  puts(" cyc/elem\n");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
  puts("=== Vector MAC Accelerator Test ===\n\n");

  test_basic();
  test_negative();
  test_zero();
  test_self_dot();
  test_longer();
  test_pos_saturation();
  test_neg_saturation();
  test_len_zero();
  test_multi_kick();
  test_register_readback();
  test_dma_writeback();
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

  return (int)total_errors;
}
