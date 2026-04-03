// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 2D Convolution Processing Element (3×3 kernel)
 *
 * 9 signed INT8×INT8 multipliers (no overflow: 9 × 127 × 127 = 145,161 << INT32_MAX).
 * Purely combinational; result_o is registered by the caller.
 */
module conv2d_pe (
  input  logic signed [7:0]   window_i [3][3],  // [row][col], row 0 = oldest
  input  logic signed [7:0]   weights_i [9],    // row-major: weights_i[i*3+j]
  output logic signed [31:0]  result_o
);

  logic signed [15:0] products [9];
  logic signed [31:0] sum;

  always_comb begin
    for (int i = 0; i < 3; i++)
      for (int j = 0; j < 3; j++)
        products[i*3+j] = 16'(window_i[i][j]) * 16'(weights_i[i*3+j]);

    sum = '0;
    for (int k = 0; k < 9; k++)
      sum = sum + 32'(products[k]);
    result_o = sum;
  end

endmodule
