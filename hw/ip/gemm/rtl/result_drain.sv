// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Result Drain
 *
 * Combinationally computes the column sums from the systolic array:
 *   result[n] = Σ_{k=0}^{ARRAY_M-1} acc[k][n]
 *
 * Since unused rows have weight=0 and contribute acc=0, summing all ARRAY_M
 * rows gives the correct C[m][n] regardless of MAT_K ≤ ARRAY_M.
 *
 * The output is stable combinationally after any PE enable cycle; gemm.sv
 * reads result_o[n_q] during its write phase.
 */
module result_drain #(
  parameter int unsigned ARRAY_M = 8,
  parameter int unsigned ARRAY_N = 8,
  parameter int unsigned ACC_W   = 32
) (
  input  logic signed [ARRAY_M-1:0][ARRAY_N-1:0][ACC_W-1:0] acc_i,
  output logic signed [ARRAY_N-1:0][ACC_W-1:0]              result_o
);

  for (genvar n = 0; n < ARRAY_N; n++) begin : gen_col_sum
    // Chained adder: sum across all ARRAY_M rows for column n
    logic signed [ACC_W-1:0] s0, s1, s2, s3, s4, s5, s6;

    assign s0 = acc_i[0][n] + acc_i[1][n];
    assign s1 = s0           + acc_i[2][n];
    assign s2 = s1           + acc_i[3][n];
    assign s3 = s2           + acc_i[4][n];
    assign s4 = s3           + acc_i[5][n];
    assign s5 = s4           + acc_i[6][n];
    assign s6 = s5           + acc_i[7][n];

    assign result_o[n] = s6;
  end

endmodule
