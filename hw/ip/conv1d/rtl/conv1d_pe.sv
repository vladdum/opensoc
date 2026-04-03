// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 1D Convolution Processing Element
 *
 * MAX_KERNEL parallel signed INT8×INT8 multipliers, one per kernel tap.
 * The kernel_size_i input controls how many taps are active (1..MAX_KERNEL);
 * contributions from taps at index >= kernel_size_i are zeroed.
 *
 * Products are INT8×INT8 → INT16 (no overflow possible). The partial sums
 * accumulate into a single INT32 result. No saturation is applied: the maximum
 * possible sum of 16 INT16 products is ±(16 × 127 × 127) = ±257,024, well
 * within INT32 range.
 *
 * The module is purely combinational; the caller registers result_o.
 */
module conv1d_pe #(
  parameter int unsigned MAX_KERNEL = 16
) (
  input  logic signed [7:0]   regs_i     [MAX_KERNEL],  // shift reg contents
  input  logic signed [7:0]   weights_i  [MAX_KERNEL],  // kernel weights
  input  logic [4:0]          kernel_size_i,             // active taps (1..16)
  output logic signed [31:0]  result_o
);

  logic signed [15:0] products [MAX_KERNEL];
  logic signed [31:0] sum;

  always_comb begin
    // Compute all products regardless of kernel_size_i; mask inactive taps.
    for (int k = 0; k < MAX_KERNEL; k++) begin
      products[k] = regs_i[k] * weights_i[k];
    end

    sum = '0;
    for (int k = 0; k < MAX_KERNEL; k++) begin
      if (32'(unsigned'(k)) < 32'(kernel_size_i)) begin
        sum = sum + {{16{products[k][15]}}, products[k]};
      end
    end
    result_o = sum;
  end

endmodule
