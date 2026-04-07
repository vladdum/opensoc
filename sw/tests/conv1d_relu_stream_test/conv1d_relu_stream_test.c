// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Conv1D → ReLU Streaming Pipeline Test (Config 1)
 *
 * Exercises the hardwired AXI-Stream connection from the Conv1D engine to the
 * ReLU accelerator. In stream mode Conv1D skips the DMA write phase and
 * outputs each result directly to ReLU's stream input; ReLU applies max(0,x)
 * and writes the result to DRAM.
 *
 * Software sequence (per the Phase 5 spec):
 *   1. Configure Conv1D in stream mode (CTRL[2]=1), set SRC_ADDR / LENGTH /
 *      kernel weights.  DST_ADDR is unused by Conv1D in stream mode.
 *   2. Configure ReLU in stream mode (CTRL[2]=1), set DST_ADDR / LEN.
 *      SRC_ADDR is unused by ReLU in stream mode.
 *   3. Assert ReLU GO, then Conv1D GO.
 *   4. Poll ReLU STATUS[DONE].
 *
 * Test 1 — 3-tap [1,2,1] filter, 16-sample ramp, valid-only:
 *   Stream output matches relu(conv1d_ref(input)) computed in C.
 *
 * Test 2 — Negative-only input, 3-tap [1,2,1], same-pad:
 *   All convolution outputs are negative; ReLU clamps to zero.
 *
 * Test 3 — Throughput vs two-pass DMA:
 *   5-tap filter on 64-sample ramp.  Cycles for streaming pipeline vs
 *   Conv1D DMA → ReLU DMA measured and printed.
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
// C reference: valid-only convolution then ReLU
// ---------------------------------------------------------------------------
static void ref_conv_valid_relu(const int32_t *x, int xlen,
                                const int8_t *w, int ksize,
                                int32_t *out) {
  int olen = xlen - ksize + 1;
  for (int n = 0; n < olen; n++) {
    int32_t acc = 0;
    for (int k = 0; k < ksize; k++)
      acc += (int32_t)(int8_t)(x[n + (ksize - 1 - k)] & 0xFF) * (int32_t)w[k];
    out[n] = (acc < 0) ? 0 : acc;
  }
}

// ---------------------------------------------------------------------------
// C reference: same-pad convolution then ReLU
// ---------------------------------------------------------------------------
static void ref_conv_same_relu(const int32_t *x, int xlen,
                               const int8_t *w, int ksize,
                               int32_t *out) {
  for (int n = 0; n < xlen; n++) {
    int32_t acc = 0;
    for (int k = 0; k < ksize; k++) {
      int xi = n - k;
      int8_t xv = (xi >= 0) ? (int8_t)(x[xi] & 0xFF) : 0;
      acc += (int32_t)xv * (int32_t)w[k];
    }
    out[n] = (acc < 0) ? 0 : acc;
  }
}

// ---------------------------------------------------------------------------
// Stream pipeline: Conv1D → ReLU
// ---------------------------------------------------------------------------
static void stream_run(uint32_t conv1d_src, uint32_t relu_dst,
                       uint32_t length, uint32_t ksize, uint32_t pad_mode,
                       const int8_t *weights) {
  // Configure Conv1D kernel
  for (uint32_t i = 0; i < ksize; i++)
    DEV_WRITE(CONV1D_KERNEL_W(i), (uint32_t)(int32_t)weights[i]);
  DEV_WRITE(CONV1D_KERNEL_SIZE,  ksize);
  DEV_WRITE(CONV1D_PADDING_MODE, pad_mode);
  DEV_WRITE(CONV1D_SRC_ADDR,     conv1d_src);

  // Output length depends on padding mode
  uint32_t out_len = (pad_mode == CONV1D_PAD_SAME) ? length
                                                   : (length - ksize + 1);
  DEV_WRITE(CONV1D_LENGTH, length);

  // Configure ReLU in stream mode
  DEV_WRITE(RELU_DST_ADDR, relu_dst);
  DEV_WRITE(RELU_LEN,      out_len);

  // GO: ReLU first (waits for stream), then Conv1D
  DEV_WRITE(RELU_CTRL,   RELU_CTRL_GO | RELU_CTRL_STREAM_MODE);
  DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_GO | CONV1D_CTRL_STREAM_MODE);

  // Wait for ReLU done (timeout after 1M cycles)
  for (uint32_t _t = 0;
       !(DEV_READ(RELU_STATUS, 0) & RELU_STATUS_DONE) && _t < 1000000u;
       _t++)
    ;
  if (!(DEV_READ(RELU_STATUS, 0) & RELU_STATUS_DONE)) {
    puts("TIMEOUT: stream pipeline did not complete\n");
    return 1;
  }
}

// ---------------------------------------------------------------------------
// DMA-only Conv1D (no stream), for throughput comparison
// ---------------------------------------------------------------------------
static void conv1d_dma_run(uint32_t src, uint32_t dst, uint32_t length,
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
// DMA-only ReLU, for throughput comparison
// ---------------------------------------------------------------------------
static void relu_dma_run(uint32_t src, uint32_t dst, uint32_t len) {
  DEV_WRITE(RELU_SRC_ADDR, src);
  DEV_WRITE(RELU_DST_ADDR, dst);
  DEV_WRITE(RELU_LEN,      len);
  DEV_WRITE(RELU_CTRL, RELU_CTRL_GO);
  while (!(DEV_READ(RELU_STATUS, 0) & RELU_STATUS_DONE))
    ;
}

// ---------------------------------------------------------------------------
// Test buffers
// ---------------------------------------------------------------------------
#define IN_LEN_A   16
#define KSIZE_A    3
#define OUT_LEN_A  (IN_LEN_A - KSIZE_A + 1)   // 14

static int32_t sig_a[IN_LEN_A]   __attribute__((aligned(4)));
static int32_t out_a[IN_LEN_A]   __attribute__((aligned(4)));
static int32_t ref_a[IN_LEN_A]   __attribute__((aligned(4)));

#define IN_LEN_B   8
#define OUT_LEN_B  IN_LEN_B   // same-pad

static int32_t sig_b[IN_LEN_B]   __attribute__((aligned(4)));
static int32_t out_b[IN_LEN_B]   __attribute__((aligned(4)));
static int32_t ref_b[IN_LEN_B]   __attribute__((aligned(4)));

#define IN_LEN_C   64
#define KSIZE_C    5
#define OUT_LEN_C  (IN_LEN_C - KSIZE_C + 1)   // 60

static int32_t sig_c[IN_LEN_C]   __attribute__((aligned(4)));
static int32_t out_c[IN_LEN_C]   __attribute__((aligned(4)));
static int32_t mid_c[IN_LEN_C]   __attribute__((aligned(4)));  // intermediate for two-pass
static int32_t ref_c[IN_LEN_C]   __attribute__((aligned(4)));

int main(int argc, char **argv) {
  int errors = 0;

  puts("=== Conv1D → ReLU Stream Pipeline Test ===\n");

  // -------------------------------------------------------------------------
  // Test 1: 3-tap [1,2,1], 16-sample ramp, valid-only
  //   Stream output must match relu(conv1d(input)) reference.
  // -------------------------------------------------------------------------
  puts("--- Test 1: 3-tap [1,2,1], 16-sample ramp, valid-only ---\n");
  {
    static const int8_t k3[KSIZE_A] = { 1, 2, 1 };

    for (int i = 0; i < IN_LEN_A; i++) sig_a[i] = (int32_t)i;
    for (int i = 0; i < IN_LEN_A; i++) out_a[i] = (int32_t)0xDEADBEEF;

    ref_conv_valid_relu(sig_a, IN_LEN_A, k3, KSIZE_A, ref_a);

    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

    stream_run((uint32_t)sig_a, (uint32_t)out_a,
               IN_LEN_A, KSIZE_A, CONV1D_PAD_VALID, k3);

    int t1_err = 0;
    for (int n = 0; n < OUT_LEN_A; n++) {
      if (out_a[n] != ref_a[n]) {
        t1_err++;
        if (t1_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(out_a[n]); puts(" exp="); put_i32(ref_a[n]); putchar('\n');
        }
      }
    }
    if (t1_err == 0) {
      puts("PASS: "); putdec(OUT_LEN_A); puts(" outputs match relu(conv1d(x))\n");
    } else {
      puts("FAIL: "); putdec((uint32_t)t1_err); puts(" mismatches\n");
      errors += t1_err;
    }
  }

  // -------------------------------------------------------------------------
  // Test 2: Negative-only input, 3-tap [1,2,1], same-pad
  //   All convolution outputs are negative; ReLU must clamp all to zero.
  // -------------------------------------------------------------------------
  puts("--- Test 2: negative-only input, 3-tap [1,2,1], same-pad ---\n");
  {
    static const int8_t k3[KSIZE_A] = { 1, 2, 1 };

    // Fill with -1..-8 (negative, so all conv outputs are negative)
    for (int i = 0; i < IN_LEN_B; i++) sig_b[i] = -(i + 1);
    for (int i = 0; i < IN_LEN_B; i++) out_b[i] = (int32_t)0xDEADBEEF;

    ref_conv_same_relu(sig_b, IN_LEN_B, k3, KSIZE_A, ref_b);

    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

    stream_run((uint32_t)sig_b, (uint32_t)out_b,
               IN_LEN_B, KSIZE_A, CONV1D_PAD_SAME, k3);

    // All outputs must be zero (all inputs negative, conv outputs negative)
    int t2_err = 0;
    for (int n = 0; n < OUT_LEN_B; n++) {
      if (out_b[n] != 0) {
        t2_err++;
        if (t2_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n);
          puts("]: got="); put_i32(out_b[n]); puts(" exp=0\n");
        }
      }
      // Also cross-check against C reference
      if (ref_b[n] != 0 && t2_err == 0) {
        puts("  NOTE: ref["); putdec((uint32_t)n);
        puts("] = "); put_i32(ref_b[n]); puts(" (unexpected positive)\n");
      }
    }
    if (t2_err == 0) {
      puts("PASS: all "); putdec(OUT_LEN_B); puts(" outputs are zero\n");
    } else {
      puts("FAIL: "); putdec((uint32_t)t2_err); puts(" non-zero outputs\n");
      errors += t2_err;
    }
  }

  // -------------------------------------------------------------------------
  // Test 3: Throughput — stream vs two-pass DMA
  //   5-tap [1,2,4,2,1] filter on 64-sample ramp.
  //   Measure cycles for:
  //     (a) Conv1D stream → ReLU stream  (pipeline)
  //     (b) Conv1D DMA write + ReLU DMA read  (two separate operations)
  // -------------------------------------------------------------------------
  puts("--- Test 3: throughput, 5-tap valid, 64 samples ---\n");
  {
    static const int8_t k5[KSIZE_C] = { 1, 2, 4, 2, 1 };

    for (int i = 0; i < IN_LEN_C; i++) sig_c[i] = (int32_t)(i & 0x7F);
    for (int i = 0; i < IN_LEN_C; i++) out_c[i] = (int32_t)0xDEADBEEF;

    ref_conv_valid_relu(sig_c, IN_LEN_C, k5, KSIZE_C, ref_c);

    // --- (a) Stream pipeline ---
    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

    pcount_reset();
    pcount_enable(1);
    stream_run((uint32_t)sig_c, (uint32_t)out_c,
               IN_LEN_C, KSIZE_C, CONV1D_PAD_VALID, k5);
    pcount_enable(0);
    uint32_t cyc_stream;
    PCOUNT_READ(mcycle, cyc_stream);

    // Verify correctness
    int t3_err = 0;
    for (int n = 0; n < OUT_LEN_C; n++) {
      if (out_c[n] != ref_c[n]) {
        t3_err++;
        if (t3_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)n); puts("]: got=");
          put_i32(out_c[n]); puts(" exp="); put_i32(ref_c[n]); putchar('\n');
        }
      }
    }
    if (t3_err == 0) {
      puts("PASS: "); putdec(OUT_LEN_C); puts(" stream outputs correct\n");
    } else {
      puts("FAIL: "); putdec((uint32_t)t3_err); puts(" mismatches\n");
      errors += t3_err;
    }

    // --- (b) Two-pass DMA ---
    for (int i = 0; i < IN_LEN_C; i++) mid_c[i] = (int32_t)0xDEADBEEF;
    for (int i = 0; i < IN_LEN_C; i++) out_c[i] = (int32_t)0xDEADBEEF;

    DEV_WRITE(CONV1D_CTRL, CONV1D_CTRL_SOFT_RESET);

    pcount_reset();
    pcount_enable(1);
    conv1d_dma_run((uint32_t)sig_c, (uint32_t)mid_c,
                   IN_LEN_C, KSIZE_C, CONV1D_PAD_VALID, k5);
    relu_dma_run((uint32_t)mid_c, (uint32_t)out_c, OUT_LEN_C);
    pcount_enable(0);
    uint32_t cyc_dma;
    PCOUNT_READ(mcycle, cyc_dma);

    // Verify two-pass correctness
    int t3b_err = 0;
    for (int n = 0; n < OUT_LEN_C; n++) {
      if (out_c[n] != ref_c[n]) t3b_err++;
    }
    if (t3b_err != 0) {
      puts("FAIL: two-pass DMA reference mismatch ("); putdec((uint32_t)t3b_err); puts(")\n");
      errors += t3b_err;
    }

    // Report throughput
    puts("  Stream pipeline: "); putdec(cyc_stream); puts(" cycles\n");
    puts("  Two-pass DMA:    "); putdec(cyc_dma);    puts(" cycles\n");
    if (cyc_stream < cyc_dma) {
      uint32_t saved = cyc_dma - cyc_stream;
      puts("  Saved: "); putdec(saved); puts(" cycles (");
      putdec(saved * 100u / cyc_dma); puts("% faster)\n");
    } else {
      puts("  NOTE: stream not faster than two-pass DMA\n");
    }
    puts("  Cycles/element (stream):   ");
    putdec(cyc_stream / OUT_LEN_C); putchar('.');
    putdec((cyc_stream % OUT_LEN_C) * 10u / OUT_LEN_C); putchar('\n');
    puts("  Cycles/element (two-pass): ");
    putdec(cyc_dma / OUT_LEN_C); putchar('.');
    putdec((cyc_dma % OUT_LEN_C) * 10u / OUT_LEN_C); putchar('\n');
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
