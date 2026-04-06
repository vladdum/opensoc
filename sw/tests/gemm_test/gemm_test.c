// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * GEMM Systolic Array Test
 *
 * Exercises the 8×8 weight-stationary systolic array accelerator.
 * C[M×N] = A[M×K] × B[K×N], all INT8 inputs, INT32 outputs.
 *
 * A is stored row-major as INT8 values in 32-bit words (hardware uses [7:0]).
 * B is preloaded into PE registers via WEIGHT_ADDR/WEIGHT_DATA CSRs.
 * C is written row-major as INT32 words.
 *
 * Test 1 — Register readback: write/read SRC_ADDR, DST_ADDR, MAT_M/K/N,
 *           IER; verify ARRAY_SIZE returns 0x0808.
 * Test 2 — SOFT_RESET clears BUSY/DONE.
 * Test 3 — 4×4 multiply: known A and B, verify C against SW reference.
 * Test 4 — 8×8 multiply: full array exercise with ramp inputs.
 * Test 5 — Identity: A × I = A for a 4×4 case.
 * Test 6 — Zero matrix: A × 0 = 0.
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
// Load weight matrix B (KxN, INT8) into PE registers.
// PE[k][n] stores B[k][n].  WEIGHT_ADDR = (k<<3)|n.
// ---------------------------------------------------------------------------
static void gemm_load_weights(const int8_t *b, int K, int N) {
  for (int k = 0; k < K; k++) {
    for (int n = 0; n < N; n++) {
      uint32_t addr = ((uint32_t)k << 3) | (uint32_t)n;
      DEV_WRITE(GEMM_WEIGHT_ADDR, addr);
      DEV_WRITE(GEMM_WEIGHT_DATA, (uint32_t)(int32_t)b[k * N + n]);
    }
  }
}

// ---------------------------------------------------------------------------
// Launch GEMM and poll for completion.
// A (MxK INT8 in 32-bit words) at src; C (MxN INT32) at dst.
// ---------------------------------------------------------------------------
static void gemm_run(uint32_t src, uint32_t dst,
                     uint32_t M, uint32_t K, uint32_t N) {
  DEV_WRITE(GEMM_SRC_ADDR, src);
  DEV_WRITE(GEMM_DST_ADDR, dst);
  DEV_WRITE(GEMM_MAT_M, M);
  DEV_WRITE(GEMM_MAT_K, K);
  DEV_WRITE(GEMM_MAT_N, N);
  DEV_WRITE(GEMM_CTRL, GEMM_CTRL_GO);
  while (!(DEV_READ(GEMM_STATUS, 0) & GEMM_STATUS_DONE))
    ;
}

// ---------------------------------------------------------------------------
// Reference GEMM: C[m][n] = sum_k A[m][k] * B[k][n]
// ---------------------------------------------------------------------------
static void ref_gemm(const int8_t *a, const int8_t *b, int32_t *c,
                     int M, int K, int N) {
  for (int m = 0; m < M; m++) {
    for (int n = 0; n < N; n++) {
      int32_t acc = 0;
      for (int k = 0; k < K; k++)
        acc += (int32_t)a[m * K + k] * (int32_t)b[k * N + n];
      c[m * N + n] = acc;
    }
  }
}

// ---------------------------------------------------------------------------
// Test data buffers (largest needed: 8×8)
// A stored as INT8 in 32-bit words (hardware reads bits [7:0]).
// ---------------------------------------------------------------------------
#define MAX_DIM 8
static int32_t a_buf[MAX_DIM * MAX_DIM] __attribute__((aligned(4)));
static int32_t c_buf[MAX_DIM * MAX_DIM] __attribute__((aligned(4)));
static int32_t ref_buf[MAX_DIM * MAX_DIM];

int main(int argc, char **argv) {
  int errors = 0;

  puts("=== GEMM Systolic Array Test ===\n");

  // -------------------------------------------------------------------------
  // Test 1: Register readback
  // -------------------------------------------------------------------------
  puts("--- Test 1: Register readback ---\n");

  DEV_WRITE(GEMM_SRC_ADDR, 0x20010000u);
  DEV_WRITE(GEMM_DST_ADDR, 0x20020000u);
  DEV_WRITE(GEMM_MAT_M, 4);
  DEV_WRITE(GEMM_MAT_K, 3);
  DEV_WRITE(GEMM_MAT_N, 2);
  DEV_WRITE(GEMM_IER, GEMM_IER_DONE);

  int t1_err = 0;
  if (DEV_READ(GEMM_SRC_ADDR, 0) != 0x20010000u) { puts("FAIL: SRC_ADDR\n");  t1_err++; }
  if (DEV_READ(GEMM_DST_ADDR, 0) != 0x20020000u) { puts("FAIL: DST_ADDR\n");  t1_err++; }
  if (DEV_READ(GEMM_MAT_M, 0)    != 4u)           { puts("FAIL: MAT_M\n");     t1_err++; }
  if (DEV_READ(GEMM_MAT_K, 0)    != 3u)           { puts("FAIL: MAT_K\n");     t1_err++; }
  if (DEV_READ(GEMM_MAT_N, 0)    != 2u)           { puts("FAIL: MAT_N\n");     t1_err++; }
  if (DEV_READ(GEMM_IER, 0)      != 1u)           { puts("FAIL: IER\n");       t1_err++; }
  if (DEV_READ(GEMM_ARRAY_SIZE, 0) != 0x0808u)    { puts("FAIL: ARRAY_SIZE\n"); t1_err++; }

  if (t1_err == 0) puts("PASS: all register readbacks OK\n");
  else { errors += t1_err; }

  // -------------------------------------------------------------------------
  // Test 2: SOFT_RESET clears STATUS
  // -------------------------------------------------------------------------
  puts("--- Test 2: SOFT_RESET ---\n");
  DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
  uint32_t status = DEV_READ(GEMM_STATUS, 0);
  if (status & (GEMM_STATUS_BUSY | GEMM_STATUS_DONE)) {
    puts("FAIL: STATUS not clear after SOFT_RESET\n");
    errors++;
  } else {
    puts("PASS: STATUS clear after SOFT_RESET\n");
  }

  // -------------------------------------------------------------------------
  // Test 3: 4×4 multiply
  // A (4×4):  row-major, values 1..16
  // B (4×4):  row-major, values 17..32
  // -------------------------------------------------------------------------
  puts("--- Test 3: 4x4 multiply ---\n");
  {
    int8_t  a4[4*4], b4[4*4];
    for (int i = 0; i < 16; i++) { a4[i] = (int8_t)(i + 1);  a_buf[i] = (int32_t)a4[i]; }
    for (int i = 0; i < 16; i++) { b4[i] = (int8_t)(i + 17); }
    for (int i = 0; i < 16; i++) c_buf[i] = 0x12345678;

    ref_gemm(a4, b4, ref_buf, 4, 4, 4);
    gemm_load_weights(b4, 4, 4);
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
    gemm_run((uint32_t)a_buf, (uint32_t)c_buf, 4, 4, 4);

    status = DEV_READ(GEMM_STATUS, 0);
    if (!(status & GEMM_STATUS_DONE)) { puts("FAIL: DONE not set\n"); errors++; }
    if (  status & GEMM_STATUS_BUSY)  { puts("FAIL: BUSY still set\n"); errors++; }

    int t3_err = 0;
    for (int i = 0; i < 16; i++) {
      if (c_buf[i] != ref_buf[i]) {
        t3_err++;
        if (t3_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
          put_i32(c_buf[i]); puts(" exp="); put_i32(ref_buf[i]); putchar('\n');
        }
      }
    }
    if (t3_err == 0) puts("PASS: 16 outputs correct\n");
    else { puts("FAIL: "); putdec((uint32_t)t3_err); puts(" mismatches\n"); errors += t3_err; }
  }

  // -------------------------------------------------------------------------
  // Test 4: 8×8 multiply (full array)
  // A: ramp 0..63; B: all 1s → C[m][n] = sum of A row m = 8*(8m) + 28 = 8m*8+28
  // -------------------------------------------------------------------------
  puts("--- Test 4: 8x8 multiply (all-ones B) ---\n");
  {
    int8_t a8[8*8], b8[8*8];
    for (int i = 0; i < 64; i++) { a8[i] = (int8_t)(i & 0x7F); a_buf[i] = (int32_t)a8[i]; }
    for (int i = 0; i < 64; i++) { b8[i] = 1; }
    for (int i = 0; i < 64; i++) c_buf[i] = 0;

    ref_gemm(a8, b8, ref_buf, 8, 8, 8);
    gemm_load_weights(b8, 8, 8);
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
    gemm_run((uint32_t)a_buf, (uint32_t)c_buf, 8, 8, 8);

    int t4_err = 0;
    for (int i = 0; i < 64; i++) {
      if (c_buf[i] != ref_buf[i]) {
        t4_err++;
        if (t4_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
          put_i32(c_buf[i]); puts(" exp="); put_i32(ref_buf[i]); putchar('\n');
        }
      }
    }
    if (t4_err == 0) puts("PASS: 64 outputs correct\n");
    else { puts("FAIL: "); putdec((uint32_t)t4_err); puts(" mismatches\n"); errors += t4_err; }
  }

  // -------------------------------------------------------------------------
  // Test 5: 4×4 × 4×4 identity — A × I = A
  // -------------------------------------------------------------------------
  puts("--- Test 5: 4x4 identity (A x I = A) ---\n");
  {
    int8_t a5[4*4], id[4*4];
    for (int i = 0; i < 16; i++) { a5[i] = (int8_t)((i * 3 - 20) & 0x7F); a_buf[i] = (int32_t)a5[i]; }
    for (int k = 0; k < 4; k++)
      for (int n = 0; n < 4; n++)
        id[k * 4 + n] = (k == n) ? 1 : 0;
    for (int i = 0; i < 16; i++) c_buf[i] = 0;

    ref_gemm(a5, id, ref_buf, 4, 4, 4);
    gemm_load_weights(id, 4, 4);
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
    gemm_run((uint32_t)a_buf, (uint32_t)c_buf, 4, 4, 4);

    int t5_err = 0;
    for (int i = 0; i < 16; i++) {
      if (c_buf[i] != ref_buf[i]) {
        t5_err++;
        if (t5_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
          put_i32(c_buf[i]); puts(" exp="); put_i32(ref_buf[i]); putchar('\n');
        }
      }
    }
    if (t5_err == 0) puts("PASS: A x I = A verified\n");
    else { puts("FAIL: "); putdec((uint32_t)t5_err); puts(" mismatches\n"); errors += t5_err; }
  }

  // -------------------------------------------------------------------------
  // Test 6: 4×4 × 4×4 zero matrix — A × 0 = 0
  // -------------------------------------------------------------------------
  puts("--- Test 6: 4x4 zero matrix (A x 0 = 0) ---\n");
  {
    int8_t a6[4*4], z[4*4];
    for (int i = 0; i < 16; i++) { a6[i] = (int8_t)(i + 1); a_buf[i] = (int32_t)a6[i]; }
    for (int i = 0; i < 16; i++) z[i] = 0;
    for (int i = 0; i < 16; i++) c_buf[i] = 0x12345678;

    gemm_load_weights(z, 4, 4);
    DEV_WRITE(GEMM_CTRL, GEMM_CTRL_SOFT_RESET);
    gemm_run((uint32_t)a_buf, (uint32_t)c_buf, 4, 4, 4);

    int t6_err = 0;
    for (int i = 0; i < 16; i++) {
      if (c_buf[i] != 0) {
        t6_err++;
        if (t6_err <= 4) {
          puts("  MISMATCH ["); putdec((uint32_t)i); puts("]: got=");
          put_i32(c_buf[i]); puts(" exp=0\n");
        }
      }
    }
    if (t6_err == 0) puts("PASS: A x 0 = 0 verified\n");
    else { puts("FAIL: "); putdec((uint32_t)t6_err); puts(" mismatches\n"); errors += t6_err; }
  }

  // -------------------------------------------------------------------------
  // Result
  // -------------------------------------------------------------------------
  putchar('\n');
  if (errors == 0)
    puts("ALL TESTS PASSED\n");
  else {
    puts("TESTS FAILED: "); putdec((uint32_t)errors); puts(" error(s)\n");
  }

  return 0;
}
