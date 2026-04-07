// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 1D Convolution Engine Test
 *
 * Exercises the conv1d accelerator.
 *
 * Memory layout: each INT8 input sample occupies one full 32-bit word
 * (the hardware reads 32-bit words and uses only bits [7:0]).
 * Output elements are INT32 words.
 *
 * Test 1 — Valid-only mode (3-tap [1, 2, 1] filter):
 *   Input:  16 samples, ramp 0..15; output: 14 INT32 elements vs C reference
 * Test 2 — Causal same-pad mode (3-tap [1, 2, 1]):
 *   Input:  8 samples, alternating +1/-1; output: 8 INT32 vs C reference
 * Test 3 — Valid-only, 5-tap [1, 2, 4, 2, 1] filter:
 *   Input:  16-sample ramp; output: 12 elements vs C reference
 * Test 4 — Valid-only, 7-tap [1, 2, 3, 4, 3, 2, 1] filter:
 *   Input:  16-sample ramp; output: 10 elements vs C reference
 * Test 5 — Single-element kernel [3] (scale):
 *   Input:  8-sample ramp; output = 3×input (valid, out_len = in_len)
 * Test 6 — Throughput (cycles / output element):
 *   5-tap valid filter on 64-sample ramp; reports cycles/element
 *
 * Also verifies register readback, BUSY/DONE transitions, and SOFT_RESET.
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void putdec(uint32_t v) {
  char buf[11];
  int pos = 0;
  if (v == 0) { putchar('0'); return; }
  while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) putchar(buf[--pos]);
}

static void put_i32(int32_t v) {
  if (v < 0) { putchar('-'); putdec((uint32_t)(-v)); }
  else putdec((uint32_t)v);
}

// ---------------------------------------------------------------------------
// Reference convolution (valid-only):
//   out[n] = x[n+K-1]*w[0] + x[n+K-2]*w[1] + ... + x[n]*w[K-1]
//   (w[0] applied to the newest sample in the window, matching hardware)
// ---------------------------------------------------------------------------
static void ref_conv_valid(const int32_t *x, int xlen,
                            const int8_t *w, int ksize,
                            int32_t *out) {
  int olen = xlen - ksize + 1;
  for (int n = 0; n < olen; n++) {
    int32_t acc = 0;
    for (int k = 0; k < ksize; k++)
      acc += (int32_t)(int8_t)(x[n + (ksize - 1 - k)] & 0xFF) * (int32_t)w[k];
    out[n] = acc;
  }
}

// ---------------------------------------------------------------------------
// Reference convolution (causal same-pad):
//   out[n] = x[n]*w[0] + x[n-1]*w[1] + ... + x[n-K+1]*w[K-1]
//   with x[negative] = 0  (K-1 virtual zeros pre-loaded on the left)
// This matches the hardware behaviour: fill_count starts at K-1.
// ---------------------------------------------------------------------------
static void ref_conv_same(const int32_t *x, int xlen,
                           const int8_t *w, int ksize,
                           int32_t *out) {
  for (int n = 0; n < xlen; n++) {
    int32_t acc = 0;
    for (int k = 0; k < ksize; k++) {
      int xi = n - k;
      int8_t xv = (xi >= 0) ? (int8_t)(x[xi] & 0xFF) : 0;
      acc += (int32_t)xv * (int32_t)w[k];
    }
    out[n] = acc;
  }
}

// ---------------------------------------------------------------------------
// Launch accelerator and poll for completion
// ---------------------------------------------------------------------------
static void conv1d_run(uint32_t src, uint32_t dst, uint32_t length,
                       uint32_t ksize, uint32_t pad_mode,
                       const int8_t *weights) {
  for (uint32_t i = 0; i < ksize; i++)
    DEV_WRITE(CONV1D_KERNEL_W(i), (uint32_t)(int32_t)weights[i]);

  DEV_WRITE(CONV1D_KERNEL_SIZE,  ksize);
  DEV_WRITE(CONV1D_PADDING_MODE, pad_mode);
  DEV_WRITE(CONV1D_SRC_ADDR,     src);
  DEV_WRITE(CONV1D_DST_ADDR,     dst);
  DEV_WRITE(CONV1D_LENGTH,       length);

  DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_GO);

  while (!(DEV_READ(CONV1D_STATUS, 0) & CONV1D_STATUS_DONE))
    ;
}

// ---------------------------------------------------------------------------
// Test data
// Input buffers: each INT8 sample stored in a 32-bit word (hardware uses [7:0])
// ---------------------------------------------------------------------------

#define IN_LEN    16
#define KSIZE     3
#define OUT_VALID (IN_LEN - KSIZE + 1)   // 14

static int32_t signal_a[IN_LEN]   __attribute__((aligned(4)));
static int32_t output_a[IN_LEN]   __attribute__((aligned(4)));
static int32_t ref_a[IN_LEN]      __attribute__((aligned(4)));

#define IN_LEN_B  8

static int32_t signal_b[IN_LEN_B] __attribute__((aligned(4)));
static int32_t output_b[IN_LEN_B] __attribute__((aligned(4)));
static int32_t ref_b[IN_LEN_B]    __attribute__((aligned(4)));

#define IN_LEN_C  64

static int32_t signal_c[IN_LEN_C] __attribute__((aligned(4)));
static int32_t output_c[IN_LEN_C] __attribute__((aligned(4)));
static int32_t ref_c[IN_LEN_C]    __attribute__((aligned(4)));

int main(int argc, char **argv) {
  int errors = 0;
  int8_t kernel[KSIZE] = { 1, 2, 1 };

  puts("=== Conv1D Engine Test ===\n");

  // -------------------------------------------------------------------------
  // Register readback check
  // -------------------------------------------------------------------------
  puts("--- Register readback ---\n");

  DEV_WRITE(CONV1D_KERNEL_SIZE,  KSIZE);
  DEV_WRITE(CONV1D_PADDING_MODE, CONV1D_PAD_VALID);
  DEV_WRITE(CONV1D_SRC_ADDR,     0x20001000u);
  DEV_WRITE(CONV1D_DST_ADDR,     0x20002000u);
  DEV_WRITE(CONV1D_LENGTH,       IN_LEN);

  if (DEV_READ(CONV1D_KERNEL_SIZE, 0) != KSIZE) {
    puts("FAIL: KERNEL_SIZE readback\n"); errors++;
  }
  if (DEV_READ(CONV1D_PADDING_MODE, 0) != CONV1D_PAD_VALID) {
    puts("FAIL: PADDING_MODE readback\n"); errors++;
  }
  if (DEV_READ(CONV1D_SRC_ADDR, 0) != 0x20001000u) {
    puts("FAIL: SRC_ADDR readback\n"); errors++;
  }
  if (DEV_READ(CONV1D_DST_ADDR, 0) != 0x20002000u) {
    puts("FAIL: DST_ADDR readback\n"); errors++;
  }
  if (DEV_READ(CONV1D_LENGTH, 0) != (uint32_t)IN_LEN) {
    puts("FAIL: LENGTH readback\n"); errors++;
  }

  for (int i = 0; i < KSIZE; i++)
    DEV_WRITE(CONV1D_KERNEL_W(i), (uint32_t)(int32_t)kernel[i]);
  for (int i = 0; i < KSIZE; i++) {
    uint32_t got = DEV_READ(CONV1D_KERNEL_W(i), 0);
    uint32_t exp = (uint32_t)(int32_t)kernel[i];
    if (got != exp) {
      puts("FAIL: KERNEL_W["); putdec((uint32_t)i); puts("] readback\n");
      errors++;
    }
  }

  if (errors == 0) puts("PASS: all register readbacks OK\n");

  // -------------------------------------------------------------------------
  // SOFT_RESET clears STATUS
  // -------------------------------------------------------------------------
  puts("--- SOFT_RESET ---\n");
  DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);
  uint32_t status = DEV_READ(CONV1D_STATUS, 0);
  if (status & (CONV1D_STATUS_BUSY | CONV1D_STATUS_DONE)) {
    puts("FAIL: SOFT_RESET did not clear STATUS\n"); errors++;
  } else {
    puts("PASS: STATUS clear after SOFT_RESET\n");
  }

  // -------------------------------------------------------------------------
  // Test 1: Valid-only, 3-tap [1,2,1], 16-sample ramp
  // -------------------------------------------------------------------------
  puts("--- Test 1: valid-only, 3-tap [1,2,1], 16-sample ramp ---\n");

  // Each input sample in its own 32-bit word; hardware uses bits [7:0]
  for (int i = 0; i < IN_LEN; i++) signal_a[i] = (int32_t)i;
  for (int i = 0; i < IN_LEN; i++) output_a[i] = (int32_t)0x12345678;

  ref_conv_valid(signal_a, IN_LEN, kernel, KSIZE, ref_a);

  conv1d_run((uint32_t)signal_a, (uint32_t)output_a, IN_LEN,
             KSIZE, CONV1D_PAD_VALID, kernel);

  status = DEV_READ(CONV1D_STATUS, 0);
  if (!(status & CONV1D_STATUS_DONE)) {
    puts("FAIL: DONE not set after completion\n"); errors++;
  }
  if (status & CONV1D_STATUS_BUSY) {
    puts("FAIL: BUSY still set after completion\n"); errors++;
  }

  int t1_err = 0;
  for (int n = 0; n < OUT_VALID; n++) {
    if (output_a[n] != ref_a[n]) {
      t1_err++;
      if (t1_err <= 4) {
        puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
        put_i32(output_a[n]); puts(" exp="); put_i32(ref_a[n]); putchar('\n');
      }
    }
  }
  if (t1_err == 0) {
    puts("PASS: "); putdec(OUT_VALID); puts(" outputs correct\n");
  } else {
    puts("FAIL: "); putdec((uint32_t)t1_err); puts(" mismatches\n");
    errors += t1_err;
  }

  // -------------------------------------------------------------------------
  // Test 2: Same/zero-pad, 3-tap [1,2,1], alternating +1/-1
  // -------------------------------------------------------------------------
  puts("--- Test 2: same/zero-pad, 3-tap [1,2,1], 8-sample alt +-1 ---\n");

  for (int i = 0; i < IN_LEN_B; i++) signal_b[i] = (i & 1) ? -1 : 1;
  for (int i = 0; i < IN_LEN_B; i++) output_b[i] = (int32_t)0x12345678;

  ref_conv_same(signal_b, IN_LEN_B, kernel, KSIZE, ref_b);

  DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

  conv1d_run((uint32_t)signal_b, (uint32_t)output_b, IN_LEN_B,
             KSIZE, CONV1D_PAD_SAME, kernel);

  int t2_err = 0;
  for (int n = 0; n < IN_LEN_B; n++) {
    if (output_b[n] != ref_b[n]) {
      t2_err++;
      if (t2_err <= 4) {
        puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
        put_i32(output_b[n]); puts(" exp="); put_i32(ref_b[n]); putchar('\n');
      }
    }
  }
  if (t2_err == 0) {
    puts("PASS: "); putdec(IN_LEN_B); puts(" outputs correct\n");
  } else {
    puts("FAIL: "); putdec((uint32_t)t2_err); puts(" mismatches\n");
    errors += t2_err;
  }

  // -------------------------------------------------------------------------
  // Test 3: Valid-only, 5-tap [1,2,4,2,1] filter, 16-sample ramp
  // -------------------------------------------------------------------------
  puts("--- Test 3: valid-only, 5-tap [1,2,4,2,1], 16-sample ramp ---\n");
  {
    static const int8_t k5[5] = { 1, 2, 4, 2, 1 };
    const int olen = IN_LEN - 5 + 1;   // 12
    for (int i = 0; i < IN_LEN; i++) signal_a[i] = (int32_t)i;
    for (int i = 0; i < IN_LEN; i++) output_a[i] = 0;
    ref_conv_valid(signal_a, IN_LEN, k5, 5, ref_a);
    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);
    conv1d_run((uint32_t)signal_a, (uint32_t)output_a, IN_LEN, 5, CONV1D_PAD_VALID, k5);
    int t3_err = 0;
    for (int n = 0; n < olen; n++) {
      if (output_a[n] != ref_a[n]) {
        t3_err++;
        if (t3_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(output_a[n]); puts(" exp="); put_i32(ref_a[n]); putchar('\n');
        }
      }
    }
    if (t3_err == 0) { puts("PASS: "); putdec((uint32_t)olen); puts(" outputs correct\n"); }
    else { puts("FAIL: "); putdec((uint32_t)t3_err); puts(" mismatches\n"); errors += t3_err; }
  }

  // -------------------------------------------------------------------------
  // Test 4: Valid-only, 7-tap [1,2,3,4,3,2,1] filter, 16-sample ramp
  // -------------------------------------------------------------------------
  puts("--- Test 4: valid-only, 7-tap [1,2,3,4,3,2,1], 16-sample ramp ---\n");
  {
    static const int8_t k7[7] = { 1, 2, 3, 4, 3, 2, 1 };
    const int olen = IN_LEN - 7 + 1;   // 10
    for (int i = 0; i < IN_LEN; i++) signal_a[i] = (int32_t)i;
    for (int i = 0; i < IN_LEN; i++) output_a[i] = 0;
    ref_conv_valid(signal_a, IN_LEN, k7, 7, ref_a);
    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);
    conv1d_run((uint32_t)signal_a, (uint32_t)output_a, IN_LEN, 7, CONV1D_PAD_VALID, k7);
    int t4_err = 0;
    for (int n = 0; n < olen; n++) {
      if (output_a[n] != ref_a[n]) {
        t4_err++;
        if (t4_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(output_a[n]); puts(" exp="); put_i32(ref_a[n]); putchar('\n');
        }
      }
    }
    if (t4_err == 0) { puts("PASS: "); putdec((uint32_t)olen); puts(" outputs correct\n"); }
    else { puts("FAIL: "); putdec((uint32_t)t4_err); puts(" mismatches\n"); errors += t4_err; }
  }

  // -------------------------------------------------------------------------
  // Test 5: Single-element kernel [3] (scale), 8-sample ramp, valid mode
  // out_len = 8, out[n] = 3 * x[n]
  // -------------------------------------------------------------------------
  puts("--- Test 5: single-element kernel [3], 8-sample ramp, valid ---\n");
  {
    static const int8_t k1[1] = { 3 };
    for (int i = 0; i < IN_LEN_B; i++) signal_b[i] = (int32_t)i;
    for (int i = 0; i < IN_LEN_B; i++) output_b[i] = 0;
    ref_conv_valid(signal_b, IN_LEN_B, k1, 1, ref_b);
    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);
    conv1d_run((uint32_t)signal_b, (uint32_t)output_b, IN_LEN_B, 1, CONV1D_PAD_VALID, k1);
    int t5_err = 0;
    for (int n = 0; n < IN_LEN_B; n++) {
      if (output_b[n] != ref_b[n]) {
        t5_err++;
        if (t5_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(output_b[n]); puts(" exp="); put_i32(ref_b[n]); putchar('\n');
        }
      }
    }
    if (t5_err == 0) puts("PASS: 8 outputs correct\n");
    else { puts("FAIL: "); putdec((uint32_t)t5_err); puts(" mismatches\n"); errors += t5_err; }
  }

  // -------------------------------------------------------------------------
  // Test 6: Throughput — 5-tap valid filter on 64-sample ramp
  // -------------------------------------------------------------------------
  puts("--- Test 6: throughput, 5-tap valid, 64 samples ---\n");
  {
    static const int8_t k5t[5] = { 1, 2, 4, 2, 1 };
    const int olen = IN_LEN_C - 5 + 1;  // 60
    for (int i = 0; i < IN_LEN_C; i++) signal_c[i] = (int32_t)(i & 0x7F);
    for (int i = 0; i < IN_LEN_C; i++) output_c[i] = 0;
    ref_conv_valid(signal_c, IN_LEN_C, k5t, 5, ref_c);
    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

    pcount_reset();
    pcount_enable(1);
    conv1d_run((uint32_t)signal_c, (uint32_t)output_c, IN_LEN_C, 5, CONV1D_PAD_VALID, k5t);
    pcount_enable(0);
    uint32_t cyc;
    PCOUNT_READ(mcycle, cyc);

    int t6_err = 0;
    for (int n = 0; n < olen; n++) {
      if (output_c[n] != ref_c[n]) {
        t6_err++;
        if (t6_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(output_c[n]); puts(" exp="); put_i32(ref_c[n]); putchar('\n');
        }
      }
    }
    if (t6_err == 0) puts("PASS: 60 outputs correct\n");
    else { puts("FAIL: "); putdec((uint32_t)t6_err); puts(" mismatches\n"); errors += t6_err; }

    puts("  Total cycles:     "); putdec(cyc); putchar('\n');
    puts("  Output elements:  "); putdec((uint32_t)olen); putchar('\n');
    puts("  Cycles/element:   ");
    putdec(cyc / (uint32_t)olen); putchar('.');
    putdec((cyc % (uint32_t)olen) * 10u / (uint32_t)olen);
    putchar('\n');
  }

  // -------------------------------------------------------------------------
  // Result
  // -------------------------------------------------------------------------
  putchar('\n');
  if (errors == 0) {
    puts("ALL TESTS PASSED\n");
  } else {
    puts("TESTS FAILED: "); putdec((uint32_t)errors); puts(" error(s)\n");
  }

  return 0;
}
