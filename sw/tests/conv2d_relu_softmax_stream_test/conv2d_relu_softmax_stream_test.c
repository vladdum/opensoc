// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Conv2D → ReLU → Softmax Streaming Pipeline Test (Config 2)
 *
 * Exercises the hardwired AXI-Stream connections:
 *   Conv2D m_axis → ReLU s_axis → ReLU m_axis → Softmax s_axis
 *
 * Conv2D runs in stream mode (CTRL[2]=1): skips DMA write, emits each output
 * pixel on m_axis (INT32 per beat). ReLU runs in full-stream mode
 * (CTRL[2]=STREAM_IN | CTRL[3]=STREAM_OUT): reads from s_axis, emits on
 * m_axis. Softmax runs in stream mode (CTRL[1]=1): reads Phase 1 data from
 * s_axis (one INT8 per beat via bits[7:0]) and writes output to DRAM.
 *
 * Data format note:
 *   Conv2D output (INT32) → ReLU → ReLU output (INT32, bits[7:0] valid as INT8
 *   when inputs and kernel produce values in [-127,127]).  Softmax reads
 *   bits[7:0] of each 32-bit stream beat as one INT8 element.
 *   Tests use inputs/kernels that keep all conv2d outputs in [0,127].
 *
 * Software sequence (Config 2):
 *   1. Configure Conv2D in stream mode (CTRL[2]=1), set SRC_ADDR, IMG_WIDTH,
 *      IMG_HEIGHT, PADDING_MODE, kernel weights.
 *   2. Configure ReLU in full-stream mode (CTRL[2]|CTRL[3]), set LEN = number
 *      of conv2d output pixels.
 *   3. Configure Softmax in stream mode (CTRL[1]=1), set DST_ADDR, VEC_LEN.
 *   4. Assert Softmax GO, then ReLU GO, then Conv2D GO.
 *   5. Poll Softmax STATUS[DONE].
 *
 * Test 1 — identity kernel on 8×8 positive ramp, valid mode (6×6 output):
 *   Stream output matches softmax(relu(conv2d(input))) computed in C.
 *
 * Test 2 — smooth kernel on 8×8, valid mode, all-positive input:
 *   Softmax output sums to ~255 (normalization property).
 *
 * Test 3 — throughput vs three-pass DMA:
 *   Cycles for streaming pipeline vs Conv2D DMA + ReLU DMA + Softmax DMA.
 */

#include "simple_system_common.h"
#include "opensoc_regs.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static void putdec(uint32_t v) {
  char buf[11]; int pos = 0;
  if (v == 0) { putchar('0'); return; }
  while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
  while (pos > 0) putchar(buf[--pos]);
}

static void put_i32(int32_t v) {
  if (v < 0) { putchar('-'); putdec((uint32_t)(-v)); }
  else putdec((uint32_t)v);
}

// ---------------------------------------------------------------------------
// exp LUT (must match hardware exp_lut.sv, scale=46)
// ---------------------------------------------------------------------------
static const uint8_t exp_lut[256] = {
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
// C reference: valid-mode 2D convolution then ReLU then softmax
// ---------------------------------------------------------------------------

// conv2d valid-mode: output[r][c] = sum_ij kernel[i*3+j] * img[(r+i)*W+(c+j)]
// output dims: (H-2) x (W-2)
static void conv2d_ref_valid(const int32_t *img, int H, int W,
                              const int8_t *kernel, int32_t *out) {
  int oh = H - 2, ow = W - 2;
  for (int r = 0; r < oh; r++)
    for (int c = 0; c < ow; c++) {
      int32_t acc = 0;
      for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
          acc += (int32_t)(int8_t)(img[(r+i)*W + (c+j)] & 0xFF)
                 * (int32_t)kernel[i*3+j];
      out[r*ow + c] = acc;
    }
}

// relu: max(0, x)
static void relu_ref(const int32_t *in, int32_t *out, int n) {
  for (int i = 0; i < n; i++) out[i] = in[i] < 0 ? 0 : in[i];
}

// softmax reference (hardware model): uses exp_lut, restoring divider
static void softmax_ref(const int8_t *in, uint8_t *out, int n) {
  int8_t max_val = in[0];
  for (int i = 1; i < n; i++)
    if (in[i] > max_val) max_val = in[i];

  uint32_t sum = 0;
  uint8_t exp_vals[256];
  for (int i = 0; i < n; i++) {
    int diff = (int)max_val - (int)in[i];
    exp_vals[i] = exp_lut[diff & 0xFF];
    sum += exp_vals[i];
  }

  // Restoring division: recip = 65536 / sum (17 cycles)
  uint32_t rem = 0, quot = 0;
  for (int b = 16; b >= 0; b--) {
    uint32_t new_rem = (rem << 1) | ((b == 16) ? 1u : 0u);
    if (new_rem >= sum) { rem = new_rem - sum; quot |= (1u << b); }
    else                 rem = new_rem;
  }

  for (int i = 0; i < n; i++)
    out[i] = (uint8_t)((exp_vals[i] * quot) >> 8);
}

// ---------------------------------------------------------------------------
// Stream pipeline: Conv2D → ReLU → Softmax
// ---------------------------------------------------------------------------
static void stream_run(uint32_t conv2d_src, uint32_t smax_dst,
                       int img_w, int img_h,
                       const int8_t *kernel,
                       uint32_t vec_len) {
  // Configure Conv2D: identity kernel, valid mode, stream out
  for (int i = 0; i < 9; i++)
    DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)kernel[i]);
  DEV_WRITE(CONV2D_IMG_WIDTH,    (uint32_t)img_w);
  DEV_WRITE(CONV2D_IMG_HEIGHT,   (uint32_t)img_h);
  DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_VALID);
  DEV_WRITE(CONV2D_SRC_ADDR,     conv2d_src);

  // Configure ReLU: full-stream (stream in + stream out), LEN = output pixels
  DEV_WRITE(RELU_LEN, vec_len);

  // Configure Softmax: stream in, DST_ADDR, VEC_LEN
  DEV_WRITE(SMAX_DST_ADDR, smax_dst);
  DEV_WRITE(SMAX_VEC_LEN,  vec_len);

  // GO order: Softmax first (waits for stream), then ReLU, then Conv2D
  DEV_WRITE(SMAX_CTRL,   SMAX_CTRL_GO | SMAX_CTRL_STREAM_IN);
  DEV_WRITE(RELU_CTRL,   RELU_CTRL_GO | RELU_CTRL_STREAM_IN | RELU_CTRL_STREAM_OUT);
  DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO | CONV2D_CTRL_STREAM_MODE);

  // Wait for Softmax done (timeout)
  for (uint32_t t = 0;
       !(DEV_READ(SMAX_STATUS, 0) & SMAX_STATUS_DONE) && t < 2000000u;
       t++)
    ;
}

// ---------------------------------------------------------------------------
// DMA-only versions for throughput comparison
// ---------------------------------------------------------------------------
static void conv2d_dma_run(uint32_t src, uint32_t dst,
                           int img_w, int img_h,
                           const int8_t *kernel) {
  for (int i = 0; i < 9; i++)
    DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)kernel[i]);
  DEV_WRITE(CONV2D_IMG_WIDTH,    (uint32_t)img_w);
  DEV_WRITE(CONV2D_IMG_HEIGHT,   (uint32_t)img_h);
  DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_VALID);
  DEV_WRITE(CONV2D_SRC_ADDR,     src);
  DEV_WRITE(CONV2D_DST_ADDR,     dst);
  DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO);
  while (!(DEV_READ(CONV2D_STATUS, 0) & CONV2D_STATUS_DONE))
    ;
}

static void relu_dma_run(uint32_t src, uint32_t dst, uint32_t len) {
  DEV_WRITE(RELU_SRC_ADDR, src);
  DEV_WRITE(RELU_DST_ADDR, dst);
  DEV_WRITE(RELU_LEN,      len);
  DEV_WRITE(RELU_CTRL, RELU_CTRL_GO);
  while (!(DEV_READ(RELU_STATUS, 0) & RELU_STATUS_DONE))
    ;
}

static void smax_dma_run(uint32_t src, uint32_t dst, uint32_t len) {
  DEV_WRITE(SMAX_SRC_ADDR, src);
  DEV_WRITE(SMAX_DST_ADDR, dst);
  DEV_WRITE(SMAX_VEC_LEN,  len);
  DEV_WRITE(SMAX_CTRL, SMAX_CTRL_GO);
  while (!(DEV_READ(SMAX_STATUS, 0) & SMAX_STATUS_DONE))
    ;
}

// ---------------------------------------------------------------------------
// Test buffers
// ---------------------------------------------------------------------------
#define IMG_W   8
#define IMG_H   8
#define OUT_H   (IMG_H - 2)   // 6 valid-mode
#define OUT_W   (IMG_W - 2)   // 6 valid-mode
#define N_OUT   (OUT_H * OUT_W)  // 36 output pixels

// Softmax VEC_LEN must be multiple of 4; 36 is divisible by 4.
#define VEC_LEN N_OUT

static int32_t  img_buf[IMG_H * IMG_W] __attribute__((aligned(4)));
static int32_t  conv2d_out[N_OUT]      __attribute__((aligned(4)));
static int32_t  relu_out[N_OUT]        __attribute__((aligned(4)));
// Softmax packs 4 UINT8 per word → needs N_OUT/4 words
static uint32_t smax_out[(N_OUT + 3) / 4] __attribute__((aligned(4)));

// Reference arrays
static int32_t  ref_conv[N_OUT]        __attribute__((aligned(4)));
static int32_t  ref_relu[N_OUT]        __attribute__((aligned(4)));
static uint8_t  ref_smax[N_OUT]        __attribute__((aligned(4)));

int main(int argc, char **argv) {
  int errors = 0;

  puts("=== Conv2D → ReLU → Softmax Stream Pipeline Test ===\n");

  // -------------------------------------------------------------------------
  // Test 1: identity kernel on 8×8 positive ramp, valid mode
  //   Pipeline output must match softmax(relu(conv2d(input))) reference.
  // -------------------------------------------------------------------------
  puts("--- Test 1: identity kernel, 8x8 ramp, valid mode ---\n");
  {
    // Identity 3×3 kernel: only center tap = 1
    static const int8_t k_id[9] = { 0,0,0, 0,1,0, 0,0,0 };

    // Fill 8×8 image with positive ramp [1..64] (INT8 range, all positive)
    for (int i = 0; i < IMG_H * IMG_W; i++) img_buf[i] = (int32_t)(i + 1);

    // C reference: conv2d (identity → output = center pixel) → relu → softmax
    conv2d_ref_valid(img_buf, IMG_H, IMG_W, k_id, ref_conv);
    relu_ref(ref_conv, ref_relu, N_OUT);
    // Convert INT32 relu output to INT8 for softmax ref (values in [1,64])
    int8_t ref_relu_i8[N_OUT];
    for (int i = 0; i < N_OUT; i++) ref_relu_i8[i] = (int8_t)(ref_relu[i] & 0xFF);
    softmax_ref(ref_relu_i8, ref_smax, N_OUT);

    // Clear output buffer
    for (int i = 0; i < (int)((N_OUT+3)/4); i++) smax_out[i] = 0xDEADBEEFu;

    // Reset Conv2D
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);

    stream_run((uint32_t)img_buf, (uint32_t)smax_out,
               IMG_W, IMG_H, k_id, VEC_LEN);

    if (!(DEV_READ(SMAX_STATUS, 0) & SMAX_STATUS_DONE)) {
      puts("TIMEOUT: pipeline did not complete\n");
      errors++;
    } else {
      // Unpack UINT8 output and compare to reference
      int t1_err = 0;
      for (int i = 0; i < N_OUT; i++) {
        uint8_t hw = (uint8_t)((smax_out[i/4] >> (8*(i%4))) & 0xFF);
        if (hw != ref_smax[i]) {
          t1_err++;
          if (t1_err <= 4) {
            puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
            putdec(hw); puts(" exp="); putdec(ref_smax[i]); putchar('\n');
          }
        }
      }
      if (t1_err == 0) {
        puts("PASS: "); putdec(N_OUT); puts(" softmax outputs match reference\n");
      } else {
        puts("FAIL: "); putdec((uint32_t)t1_err); puts(" mismatches\n");
        errors += t1_err;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Test 2: smooth kernel, all-positive input
  //   Pipeline output matches softmax(relu(conv2d(input))) C reference.
  //   Also prints the byte sum to show the fixed-point normalization result.
  // -------------------------------------------------------------------------
  puts("--- Test 2: smooth kernel, all-positive input ---\n");
  {
    // Smoothing kernel: [1,2,1; 2,4,2; 1,2,1] — sum=16, all INT8-safe
    static const int8_t k_sm[9] = { 1,2,1, 2,4,2, 1,2,1 };

    // Fill 8×8 image with values 1..8 per column (repeating rows)
    for (int r = 0; r < IMG_H; r++)
      for (int c = 0; c < IMG_W; c++)
        img_buf[r*IMG_W + c] = (int32_t)(c + 1);

    // C reference
    conv2d_ref_valid(img_buf, IMG_H, IMG_W, k_sm, ref_conv);
    relu_ref(ref_conv, ref_relu, N_OUT);
    int8_t ref_relu_i8_t2[N_OUT];
    for (int i = 0; i < N_OUT; i++) ref_relu_i8_t2[i] = (int8_t)(ref_relu[i] & 0xFF);
    softmax_ref(ref_relu_i8_t2, ref_smax, N_OUT);

    for (int i = 0; i < (int)((N_OUT+3)/4); i++) smax_out[i] = 0xDEADBEEFu;
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);
    stream_run((uint32_t)img_buf, (uint32_t)smax_out,
               IMG_W, IMG_H, k_sm, VEC_LEN);

    if (!(DEV_READ(SMAX_STATUS, 0) & SMAX_STATUS_DONE)) {
      puts("TIMEOUT: pipeline did not complete\n");
      errors++;
    } else {
      uint32_t byte_sum = 0;
      int t2_err = 0;
      for (int i = 0; i < N_OUT; i++) {
        uint8_t hw = (uint8_t)((smax_out[i/4] >> (8*(i%4))) & 0xFF);
        byte_sum += hw;
        if (hw != ref_smax[i]) {
          t2_err++;
          if (t2_err <= 4) {
            puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
            putdec(hw); puts(" exp="); putdec(ref_smax[i]); putchar('\n');
          }
        }
      }
      puts("  Softmax byte sum: "); putdec(byte_sum); putchar('\n');
      if (t2_err == 0) {
        puts("PASS: "); putdec(N_OUT); puts(" outputs match reference\n");
      } else {
        puts("FAIL: "); putdec((uint32_t)t2_err); puts(" mismatches\n");
        errors += t2_err;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Test 3: Throughput — stream pipeline vs three-pass DMA
  //   Identity kernel on 8×8 ramp. Measure cycles for:
  //     (a) Conv2D stream → ReLU stream → Softmax stream  (pipeline)
  //     (b) Conv2D DMA + ReLU DMA + Softmax DMA  (three separate operations)
  // -------------------------------------------------------------------------
  puts("--- Test 3: throughput, identity kernel, 8x8 ---\n");
  {
    static const int8_t k_id[9] = { 0,0,0, 0,1,0, 0,0,0 };
    for (int i = 0; i < IMG_H * IMG_W; i++) img_buf[i] = (int32_t)(i + 1);

    for (int i = 0; i < (int)((N_OUT+3)/4); i++) smax_out[i] = 0;
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);

    // --- (a) Stream pipeline ---
    pcount_reset();
    pcount_enable(1);
    stream_run((uint32_t)img_buf, (uint32_t)smax_out,
               IMG_W, IMG_H, k_id, VEC_LEN);
    pcount_enable(0);
    uint32_t cyc_stream;
    PCOUNT_READ(mcycle, cyc_stream);

    // --- (b) Three-pass DMA ---
    for (int i = 0; i < N_OUT; i++) conv2d_out[i] = (int32_t)0xDEADBEEF;
    for (int i = 0; i < N_OUT; i++) relu_out[i]   = (int32_t)0xDEADBEEF;
    for (int i = 0; i < (int)((N_OUT+3)/4); i++) smax_out[i] = 0;

    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);

    pcount_reset();
    pcount_enable(1);
    conv2d_dma_run((uint32_t)img_buf, (uint32_t)conv2d_out,
                   IMG_W, IMG_H, k_id);
    relu_dma_run((uint32_t)conv2d_out, (uint32_t)relu_out, N_OUT);
    // Softmax expects INT8 packed 4/word; relu_out is INT32. For DMA-only
    // path we pass relu_out reinterpreted as bytes — valid for identity kernel
    // since values fit in INT8 (bits[7:0] = value).
    smax_dma_run((uint32_t)relu_out, (uint32_t)smax_out, VEC_LEN);
    pcount_enable(0);
    uint32_t cyc_dma;
    PCOUNT_READ(mcycle, cyc_dma);

    puts("  Stream pipeline: "); putdec(cyc_stream); puts(" cycles\n");
    puts("  Three-pass DMA:  "); putdec(cyc_dma);    puts(" cycles\n");
    if (cyc_stream < cyc_dma) {
      uint32_t saved = cyc_dma - cyc_stream;
      puts("  Saved: "); putdec(saved); puts(" cycles (");
      putdec(saved * 100u / cyc_dma); puts("% faster)\n");
    } else {
      puts("  NOTE: stream not faster than three-pass DMA\n");
    }
    puts("  Cycles/element (stream):    ");
    putdec(cyc_stream / VEC_LEN); putchar('.');
    putdec((cyc_stream % VEC_LEN) * 10u / VEC_LEN); putchar('\n');
    puts("  Cycles/element (three-pass):");
    putdec(cyc_dma / VEC_LEN); putchar('.');
    putdec((cyc_dma % VEC_LEN) * 10u / VEC_LEN); putchar('\n');
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
