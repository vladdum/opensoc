// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 2D Convolution Engine Test
 *
 * All inputs: one INT8 pixel per 32-bit word (hardware reads bits [7:0]).
 * All outputs: INT32, one word per pixel.
 *
 * Test 1 — Valid mode, identity kernel on 8×8 image: output = input (center tap)
 * Test 2 — Valid mode, edge-detection kernel on 8×8 image vs C reference
 * Test 3 — Valid mode, [1,2,1; 2,4,2; 1,2,1] smooth kernel on 8×8
 * Test 4 — Valid mode, 3×3 on 16×16
 * Test 5 — Valid mode, 3×3 on 32×32
 * Test 6 — Same mode, identity kernel on 8×8: output = input (zero-padded borders)
 * Test 7 — Same mode, smooth kernel on 8×8
 * Test 8 — Register readback and SOFT_RESET
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
// Reference convolution (valid mode)
// output[r][c] = sum_{i,j in 0..2} kernel[i*3+j] * img[(r+i)*W + (c+j)]
// Output dims: (H-2) x (W-2)
// ---------------------------------------------------------------------------
static void conv2d_ref_valid(const int32_t *img, int H, int W,
                              const int8_t *kernel,
                              int32_t *out) {
  int out_h = H - 2, out_w = W - 2;
  for (int r = 0; r < out_h; r++) {
    for (int c = 0; c < out_w; c++) {
      int32_t acc = 0;
      for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
          acc += (int32_t)(int8_t)(img[(r+i)*W + (c+j)] & 0xFF)
                 * (int32_t)kernel[i*3+j];
      out[r*out_w + c] = acc;
    }
  }
}

// ---------------------------------------------------------------------------
// Reference convolution (same / zero-pad mode)
// output[r][c] = sum_{i,j in 0..2} kernel[i*3+j] * padded[(r+i-1)*W + (c+j-1)]
// with padded[i][j] = 0 if i<0 or i>=H or j<0 or j>=W
// Output dims: H x W
// ---------------------------------------------------------------------------
static void conv2d_ref_same(const int32_t *img, int H, int W,
                             const int8_t *kernel,
                             int32_t *out) {
  for (int r = 0; r < H; r++) {
    for (int c = 0; c < W; c++) {
      int32_t acc = 0;
      for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
          int ri = r - 1 + i;
          int ci = c - 1 + j;
          int8_t px = (ri >= 0 && ri < H && ci >= 0 && ci < W)
                      ? (int8_t)(img[ri*W + ci] & 0xFF) : 0;
          acc += (int32_t)px * (int32_t)kernel[i*3+j];
        }
      }
      out[r*W + c] = acc;
    }
  }
}

// ---------------------------------------------------------------------------
// Run the accelerator and poll for done
// ---------------------------------------------------------------------------
static void conv2d_run(uint32_t src, uint32_t dst,
                       uint32_t W, uint32_t H,
                       uint32_t pad_mode, const int8_t *kernel) {
  DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);

  for (uint32_t i = 0; i < 9; i++)
    DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)kernel[i]);

  DEV_WRITE(CONV2D_IMG_WIDTH,    W);
  DEV_WRITE(CONV2D_IMG_HEIGHT,   H);
  DEV_WRITE(CONV2D_KERNEL_SIZE,  3);
  DEV_WRITE(CONV2D_PADDING_MODE, pad_mode);
  DEV_WRITE(CONV2D_SRC_ADDR,     src);
  DEV_WRITE(CONV2D_DST_ADDR,     dst);

  DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO);

  while (!(DEV_READ(CONV2D_STATUS, 0) & CONV2D_STATUS_DONE))
    ;
}

// ---------------------------------------------------------------------------
// Verify and report
// ---------------------------------------------------------------------------
static int check(const int32_t *got, const int32_t *exp, int n,
                 const char *name) {
  int errs = 0;
  for (int i = 0; i < n; i++) {
    if (got[i] != exp[i]) {
      if (errs < 4) {
        puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
        put_i32(got[i]); puts(" exp="); put_i32(exp[i]); putchar('\n');
      }
      errs++;
    }
  }
  if (errs == 0) { puts("PASS: "); puts(name); putchar('\n'); }
  else { puts("FAIL: "); puts(name); puts(" — "); putdec((uint32_t)errs); puts(" errors\n"); }
  return errs;
}

// ---------------------------------------------------------------------------
// Test buffers (all 32-bit words per pixel)
// ---------------------------------------------------------------------------
#define MAX_N  (32*32)

static int32_t img8[8*8]    __attribute__((aligned(4)));
static int32_t img16[16*16] __attribute__((aligned(4)));
static int32_t img32[32*32] __attribute__((aligned(4)));
static int32_t out_buf[MAX_N] __attribute__((aligned(4)));
static int32_t ref_buf[MAX_N] __attribute__((aligned(4)));

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
  int errors = 0;

  puts("=== Conv2D Engine Test ===\n");

  // ---- Kernels ----
  static const int8_t identity[9] = {0,0,0, 0,1,0, 0,0,0};
  static const int8_t edge[9]     = {-1,-1,-1, -1,8,-1, -1,-1,-1};
  static const int8_t smooth[9]   = {1,2,1, 2,4,2, 1,2,1};

  // =========================================================================
  // Test 8: Register readback and SOFT_RESET (run first so IP is known clean)
  // =========================================================================
  puts("--- Test 8: Register readback ---\n");
  {
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);
    DEV_WRITE(CONV2D_IMG_WIDTH,  16);
    DEV_WRITE(CONV2D_IMG_HEIGHT, 16);
    DEV_WRITE(CONV2D_KERNEL_SIZE, 3);
    DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_VALID);
    DEV_WRITE(CONV2D_SRC_ADDR, 0x20001000u);
    DEV_WRITE(CONV2D_DST_ADDR, 0x20002000u);
    for (int i = 0; i < 9; i++)
      DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)smooth[i]);

    int rb_err = 0;
    if (DEV_READ(CONV2D_IMG_WIDTH,  0) != 16) { puts("FAIL: IMG_WIDTH\n");  rb_err++; }
    if (DEV_READ(CONV2D_IMG_HEIGHT, 0) != 16) { puts("FAIL: IMG_HEIGHT\n"); rb_err++; }
    if (DEV_READ(CONV2D_KERNEL_SIZE,0) !=  3) { puts("FAIL: KERNEL_SIZE\n"); rb_err++; }
    if (DEV_READ(CONV2D_PADDING_MODE,0) != CONV2D_PAD_VALID) {
      puts("FAIL: PADDING_MODE\n"); rb_err++;
    }
    if (DEV_READ(CONV2D_SRC_ADDR,0) != 0x20001000u) { puts("FAIL: SRC_ADDR\n"); rb_err++; }
    if (DEV_READ(CONV2D_DST_ADDR,0) != 0x20002000u) { puts("FAIL: DST_ADDR\n"); rb_err++; }
    for (int i = 0; i < 9; i++) {
      if ((int32_t)DEV_READ(CONV2D_KERNEL_W(i), 0) != (int32_t)smooth[i]) {
        puts("FAIL: KERNEL_W["); putdec((uint32_t)i); puts("]\n"); rb_err++;
      }
    }

    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);
    uint32_t st = DEV_READ(CONV2D_STATUS, 0);
    if (st & (CONV2D_STATUS_BUSY | CONV2D_STATUS_DONE)) {
      puts("FAIL: STATUS not clear after SOFT_RESET\n"); rb_err++;
    }
    if (rb_err == 0) puts("PASS: all register readbacks OK\n");
    errors += rb_err;
  }

  // =========================================================================
  // Test 1: Valid mode, identity kernel, 8×8 → output = input (center crop)
  // =========================================================================
  puts("--- Test 1: Valid, identity, 8x8 ---\n");
  {
    for (int i = 0; i < 64; i++) img8[i] = (int32_t)(int8_t)((i * 3 + 7) & 0x7F);
    conv2d_run((uint32_t)img8, (uint32_t)out_buf, 8, 8, CONV2D_PAD_VALID, identity);
    // identity kernel: output[r][c] = img[(r+1)*8 + (c+1)]
    for (int r = 0; r < 6; r++)
      for (int c = 0; c < 6; c++)
        ref_buf[r*6+c] = (int32_t)(int8_t)(img8[(r+1)*8+(c+1)] & 0xFF);
    errors += check(out_buf, ref_buf, 36, "Valid identity 8x8");
  }

  // =========================================================================
  // Test 2: Valid mode, edge-detection kernel, 8×8 vs C reference
  // =========================================================================
  puts("--- Test 2: Valid, edge kernel, 8x8 ---\n");
  {
    for (int i = 0; i < 64; i++) img8[i] = (int32_t)(int8_t)(i & 0x7F);
    conv2d_run((uint32_t)img8, (uint32_t)out_buf, 8, 8, CONV2D_PAD_VALID, edge);
    conv2d_ref_valid(img8, 8, 8, edge, ref_buf);
    errors += check(out_buf, ref_buf, 36, "Valid edge 8x8");
  }

  // =========================================================================
  // Test 3: Valid mode, smooth kernel, 8×8 vs C reference
  // =========================================================================
  puts("--- Test 3: Valid, smooth [1,2,1;2,4,2;1,2,1], 8x8 ---\n");
  {
    for (int i = 0; i < 64; i++) img8[i] = (int32_t)(int8_t)((i * 5 + 3) & 0x3F);
    conv2d_run((uint32_t)img8, (uint32_t)out_buf, 8, 8, CONV2D_PAD_VALID, smooth);
    conv2d_ref_valid(img8, 8, 8, smooth, ref_buf);
    errors += check(out_buf, ref_buf, 36, "Valid smooth 8x8");
  }

  // =========================================================================
  // Test 4: Valid mode, smooth kernel, 16×16
  // =========================================================================
  puts("--- Test 4: Valid, smooth, 16x16 ---\n");
  {
    for (int i = 0; i < 256; i++) img16[i] = (int32_t)(int8_t)((i * 3 + 1) & 0x3F);
    conv2d_run((uint32_t)img16, (uint32_t)out_buf, 16, 16, CONV2D_PAD_VALID, smooth);
    conv2d_ref_valid(img16, 16, 16, smooth, ref_buf);
    errors += check(out_buf, ref_buf, 14*14, "Valid smooth 16x16");
  }

  // =========================================================================
  // Test 5: Valid mode, smooth kernel, 32×32 + throughput measurement
  // =========================================================================
  puts("--- Test 5: Valid, smooth, 32x32 + throughput ---\n");
  {
    for (int i = 0; i < 1024; i++) img32[i] = (int32_t)(int8_t)((i * 7 + 2) & 0x3F);
    // Warm run for correctness (no timing)
    conv2d_run((uint32_t)img32, (uint32_t)out_buf, 32, 32, CONV2D_PAD_VALID, smooth);
    conv2d_ref_valid(img32, 32, 32, smooth, ref_buf);
    errors += check(out_buf, ref_buf, 30*30, "Valid smooth 32x32");

    // Timed run
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_SOFT_RESET);
    for (uint32_t i = 0; i < 9; i++)
      DEV_WRITE(CONV2D_KERNEL_W(i), (uint32_t)(int32_t)smooth[i]);
    DEV_WRITE(CONV2D_IMG_WIDTH,    32);
    DEV_WRITE(CONV2D_IMG_HEIGHT,   32);
    DEV_WRITE(CONV2D_KERNEL_SIZE,   3);
    DEV_WRITE(CONV2D_PADDING_MODE, CONV2D_PAD_VALID);
    DEV_WRITE(CONV2D_SRC_ADDR, (uint32_t)img32);
    DEV_WRITE(CONV2D_DST_ADDR, (uint32_t)out_buf);

    pcount_reset();
    pcount_enable(1);
    DEV_WRITE(CONV2D_CTRL, CONV2D_CTRL_GO);
    while (!(DEV_READ(CONV2D_STATUS, 0) & CONV2D_STATUS_DONE))
      ;
    pcount_enable(0);
    uint32_t cyc;
    PCOUNT_READ(mcycle, cyc);

    const uint32_t npix = 30u * 30u;  // 900 output pixels
    puts("  Total cycles:    "); putdec(cyc); putchar('\n');
    puts("  Output pixels:   "); putdec(npix); putchar('\n');
    puts("  Cycles/pixel:    ");
    putdec(cyc / npix); putchar('.');
    putdec((cyc % npix) * 10u / npix);
    putchar('\n');
  }

  // =========================================================================
  // Test 6: Same mode, identity kernel, 8×8 → output = input
  // =========================================================================
  puts("--- Test 6: Same, identity, 8x8 ---\n");
  {
    for (int i = 0; i < 64; i++) img8[i] = (int32_t)(int8_t)((i * 3 + 7) & 0x7F);
    conv2d_run((uint32_t)img8, (uint32_t)out_buf, 8, 8, CONV2D_PAD_SAME, identity);
    for (int i = 0; i < 64; i++)
      ref_buf[i] = (int32_t)(int8_t)(img8[i] & 0xFF);
    errors += check(out_buf, ref_buf, 64, "Same identity 8x8");
  }

  // =========================================================================
  // Test 7: Same mode, smooth kernel, 8×8 vs C reference
  // =========================================================================
  puts("--- Test 7: Same, smooth, 8x8 ---\n");
  {
    for (int i = 0; i < 64; i++) img8[i] = (int32_t)(int8_t)((i * 5 + 3) & 0x3F);
    conv2d_run((uint32_t)img8, (uint32_t)out_buf, 8, 8, CONV2D_PAD_SAME, smooth);
    conv2d_ref_same(img8, 8, 8, smooth, ref_buf);
    errors += check(out_buf, ref_buf, 64, "Same smooth 8x8");
  }

  // =========================================================================
  // Result
  // =========================================================================
  putchar('\n');
  if (errors == 0) puts("ALL TESTS PASSED\n");
  else { puts("TESTS FAILED: "); putdec((uint32_t)errors); puts(" error(s)\n"); }
  return 0;
}
