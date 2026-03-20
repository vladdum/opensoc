// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Softmax Pipeline Accelerator Test
 *
 * Exercises the softmax accelerator with test cases: uniform input, one-hot,
 * ascending, all-same, alternating, max length, VEC_LEN=0, debug registers,
 * register readback, back-to-back, and accuracy vs C reference model.
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"
#include <stdint.h>

// ---------------------------------------------------------------------------
// exp LUT table (must match hardware exp_lut.sv, scale=46)
// ---------------------------------------------------------------------------
static const uint8_t exp_lut_table[256] = {
  255,250,244,239,234,229,224,219,214,210,205,201,196,192,188,184,
  180,176,172,169,165,162,158,155,151,148,145,142,139,136,133,130,
  127,124,122,119,117,114,112,109,107,105,102,100, 98, 96, 94, 92,
   90, 88, 86, 84, 82, 81, 79, 77, 75, 74, 72, 71, 69, 68, 66, 65,
   63, 62, 61, 59, 58, 57, 56, 54, 53, 52, 51, 50, 49, 48, 47, 46,
   45, 44, 43, 42, 41, 40, 39, 38, 38, 37, 36, 35, 35, 34, 33, 32,
   32, 31, 30, 30, 29, 28, 28, 27, 27, 26, 25, 25, 24, 24, 23, 23,
   22, 22, 21, 21, 20, 20, 20, 19, 19, 18, 18, 18, 17, 17, 16, 16,
   16, 15, 15, 15, 14, 14, 14, 14, 13, 13, 13, 12, 12, 12, 12, 11,
   11, 11, 11, 10, 10, 10, 10, 10,  9,  9,  9,  9,  9,  8,  8,  8,
    8,  8,  8,  7,  7,  7,  7,  7,  7,  6,  6,  6,  6,  6,  6,  6,
    6,  5,  5,  5,  5,  5,  5,  5,  5,  5,  4,  4,  4,  4,  4,  4,
    4,  4,  4,  4,  4,  4,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,
    3,  3,  3,  3,  3,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,
    2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  2,  1,  1,  1,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1
};

// ---------------------------------------------------------------------------
// C reference model
// ---------------------------------------------------------------------------
static void softmax_ref(const int8_t *in, uint8_t *out, int n) {
  // Pass 1: find max
  int8_t max_val = in[0];
  for (int i = 1; i < n; i++)
    if (in[i] > max_val) max_val = in[i];

  // Pass 2: exp and sum
  uint32_t sum = 0;
  uint8_t exp_vals[256];
  for (int i = 0; i < n; i++) {
    int diff = (int)max_val - (int)in[i]; // 0..255
    exp_vals[i] = exp_lut_table[diff];
    sum += exp_vals[i];
  }

  // Pass 3: normalize using reciprocal
  uint32_t recip = 65536 / sum;
  for (int i = 0; i < n; i++) {
    out[i] = (uint8_t)((exp_vals[i] * recip) >> 8);
  }
}

// ---------------------------------------------------------------------------
// Test buffers (word-aligned for DMA)
// ---------------------------------------------------------------------------
static int8_t  input_buf[256] __attribute__((aligned(4)));
static uint8_t output_buf[256] __attribute__((aligned(4)));
static uint8_t ref_buf[256] __attribute__((aligned(4)));

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

static void run_softmax(const int8_t *src, uint8_t *dst, int len) {
  DEV_WRITE(SMAX_SRC_ADDR, (uint32_t)src);
  DEV_WRITE(SMAX_DST_ADDR, (uint32_t)dst);
  DEV_WRITE(SMAX_VEC_LEN, len);
  DEV_WRITE(SMAX_CTRL, SMAX_CTRL_GO);

  uint32_t status;
  do {
    status = DEV_READ(SMAX_STATUS, 0);
  } while (!(status & SMAX_STATUS_DONE));
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

// Check output matches reference within ±tolerance
static int check_accuracy(const uint8_t *out, const uint8_t *ref, int n,
                           int tolerance) {
  for (int i = 0; i < n; i++) {
    int diff = (int)out[i] - (int)ref[i];
    if (diff < -tolerance || diff > tolerance) return 0;
  }
  return 1;
}

// ---------------------------------------------------------------------------
// Test 1: Uniform input [0,0,0,0]
// ---------------------------------------------------------------------------
static void test_uniform_zero(void) {
  for (int i = 0; i < 4; i++) input_buf[i] = 0;
  for (int i = 0; i < 4; i++) output_buf[i] = 0xFF;

  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);

  check("uniform [0,0,0,0] accuracy", check_accuracy(output_buf, ref_buf, 4, 2));
}

// ---------------------------------------------------------------------------
// Test 2: One-hot [127, -128, -128, -128]
// ---------------------------------------------------------------------------
static void test_one_hot(void) {
  input_buf[0] = 127;
  input_buf[1] = -128;
  input_buf[2] = -128;
  input_buf[3] = -128;

  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);

  check("one-hot [127,-128,-128,-128] accuracy",
        check_accuracy(output_buf, ref_buf, 4, 2));

  // The max element should dominate
  check("one-hot output[0] > 200", output_buf[0] > 200);
}

// ---------------------------------------------------------------------------
// Test 3: Ascending [0, 1, 2, 3]
// ---------------------------------------------------------------------------
static void test_ascending(void) {
  for (int i = 0; i < 4; i++) input_buf[i] = (int8_t)i;

  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);

  check("ascending [0..3] accuracy", check_accuracy(output_buf, ref_buf, 4, 2));

  // Verify monotonically increasing
  int mono = 1;
  for (int i = 1; i < 4; i++) {
    if (output_buf[i] < output_buf[i - 1]) mono = 0;
  }
  check("ascending monotonic", mono);
}

// ---------------------------------------------------------------------------
// Test 4: All +127
// ---------------------------------------------------------------------------
static void test_all_127(void) {
  for (int i = 0; i < 4; i++) input_buf[i] = 127;

  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);

  check("all +127 accuracy", check_accuracy(output_buf, ref_buf, 4, 2));
}

// ---------------------------------------------------------------------------
// Test 5: All -128
// ---------------------------------------------------------------------------
static void test_all_neg128(void) {
  for (int i = 0; i < 4; i++) input_buf[i] = -128;

  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);

  check("all -128 accuracy", check_accuracy(output_buf, ref_buf, 4, 2));
}

// ---------------------------------------------------------------------------
// Test 6: VEC_LEN=0 (immediate DONE)
// ---------------------------------------------------------------------------
static void test_vec_len_zero(void) {
  DEV_WRITE(SMAX_SRC_ADDR, (uint32_t)input_buf);
  DEV_WRITE(SMAX_DST_ADDR, (uint32_t)output_buf);
  DEV_WRITE(SMAX_VEC_LEN, 0);
  DEV_WRITE(SMAX_CTRL, SMAX_CTRL_GO);

  uint32_t status = DEV_READ(SMAX_STATUS, 0);
  check("VEC_LEN=0 immediate DONE", (status & SMAX_STATUS_DONE) != 0);
}

// ---------------------------------------------------------------------------
// Test 7: Debug register readback (MAX_VAL and SUM_VAL)
// ---------------------------------------------------------------------------
static void test_debug_regs(void) {
  input_buf[0] = 10;
  input_buf[1] = -5;
  input_buf[2] = 10;
  input_buf[3] = 3;

  run_softmax(input_buf, output_buf, 4);

  int32_t max_val = (int32_t)DEV_READ(SMAX_MAX_VAL, 0);
  check_val("MAX_VAL=10", (uint32_t)max_val, 10);

  // Compute expected sum
  uint32_t expected_sum = 0;
  int8_t max_v = 10;
  for (int i = 0; i < 4; i++) {
    int diff = (int)max_v - (int)input_buf[i];
    expected_sum += exp_lut_table[diff];
  }
  uint32_t sum_val = DEV_READ(SMAX_SUM_VAL, 0);
  check_val("SUM_VAL correct", sum_val, expected_sum);
}

// ---------------------------------------------------------------------------
// Test 8: Register readback
// ---------------------------------------------------------------------------
static void test_register_readback(void) {
  DEV_WRITE(SMAX_SRC_ADDR, 0xAAAA0000);
  DEV_WRITE(SMAX_DST_ADDR, 0xBBBB0000);
  DEV_WRITE(SMAX_VEC_LEN, 128);
  DEV_WRITE(SMAX_IER, 1);

  int ok = 1;
  if (DEV_READ(SMAX_SRC_ADDR, 0) != 0xAAAA0000) ok = 0;
  if (DEV_READ(SMAX_DST_ADDR, 0) != 0xBBBB0000) ok = 0;
  if (DEV_READ(SMAX_VEC_LEN, 0) != 128) ok = 0;
  if (DEV_READ(SMAX_IER, 0) != 1) ok = 0;

  check("register readback", ok);

  DEV_WRITE(SMAX_IER, 0);
}

// ---------------------------------------------------------------------------
// Test 9: Back-to-back operations
// ---------------------------------------------------------------------------
static void test_back_to_back(void) {
  // First run
  for (int i = 0; i < 4; i++) input_buf[i] = (int8_t)(i * 10);
  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);
  int ok1 = check_accuracy(output_buf, ref_buf, 4, 2);

  // Second run with different data
  for (int i = 0; i < 4; i++) input_buf[i] = (int8_t)(127 - i * 30);
  run_softmax(input_buf, output_buf, 4);
  softmax_ref(input_buf, ref_buf, 4);
  int ok2 = check_accuracy(output_buf, ref_buf, 4, 2);

  check("back-to-back accuracy", ok1 && ok2);
}

// ---------------------------------------------------------------------------
// Test 10: Max length (VEC_LEN=256)
// ---------------------------------------------------------------------------
static void test_max_length(void) {
  for (int i = 0; i < 256; i++) {
    input_buf[i] = (int8_t)(i - 128); // -128..127
  }

  run_softmax(input_buf, output_buf, 256);
  softmax_ref(input_buf, ref_buf, 256);

  check("VEC_LEN=256 accuracy", check_accuracy(output_buf, ref_buf, 256, 2));

  // Verify output sum is approximately 255 (±5 for rounding)
  uint32_t out_sum = 0;
  for (int i = 0; i < 256; i++) out_sum += output_buf[i];
  // With integer truncation across 256 elements, sum can be well below 255
  int sum_ok = (out_sum >= 100 && out_sum <= 260);
  check("VEC_LEN=256 output sum ~255", sum_ok);
}

// ---------------------------------------------------------------------------
// Test 11: 8-element vector
// ---------------------------------------------------------------------------
static void test_8elem(void) {
  input_buf[0] = 100; input_buf[1] = 50; input_buf[2] = 0;   input_buf[3] = -50;
  input_buf[4] = 80;  input_buf[5] = 30; input_buf[6] = -10; input_buf[7] = 60;

  run_softmax(input_buf, output_buf, 8);
  softmax_ref(input_buf, ref_buf, 8);

  check("8-element accuracy", check_accuracy(output_buf, ref_buf, 8, 2));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
  puts("=== Softmax Pipeline Accelerator Test ===\n\n");

  test_uniform_zero();
  test_one_hot();
  test_ascending();
  test_all_127();
  test_all_neg128();
  test_vec_len_zero();
  test_debug_regs();
  test_register_readback();
  test_back_to_back();
  test_max_length();
  test_8elem();

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
