// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Vector MAC Compute Core
 *
 * Pure compute block: NUM_LANES parallel signed INT8 x INT8 multipliers
 * feeding a saturating INT32 accumulator. Each valid_i pulse unpacks
 * a_data_i and b_data_i into NUM_LANES signed bytes, multiplies pairwise,
 * sums the products, and accumulates with saturation.
 *
 * The accumulator can be cleared synchronously via clear_i.
 * result_o always reflects the current accumulator value.
 */
module vec_mac_core #(
  parameter int unsigned NUM_LANES = 4
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        clear_i,      // clear accumulator to zero
  input  logic        valid_i,      // new A/B data valid, trigger MAC
  input  logic [31:0] a_data_i,     // packed signed INT8 x NUM_LANES
  input  logic [31:0] b_data_i,     // packed signed INT8 x NUM_LANES
  output logic [31:0] result_o      // saturated INT32 accumulator
);

  // ---------------------------------------------------------------------------
  // Compile-time assertions
  // ---------------------------------------------------------------------------
  initial begin
    assert (NUM_LANES > 0 && (NUM_LANES & (NUM_LANES - 1)) == 0)
      else $fatal(1, "NUM_LANES must be a power of 2, got %0d", NUM_LANES);
    assert (NUM_LANES <= 4)
      else $fatal(1, "NUM_LANES (%0d) exceeds 32-bit bus capacity (max 4)", NUM_LANES);
  end

  // ---------------------------------------------------------------------------
  // Unpack, multiply, and sum — combinational
  // ---------------------------------------------------------------------------
  logic signed [15:0] products [NUM_LANES];
  logic signed [32:0] partial_sum;  // wide enough for NUM_LANES=4 products

  always_comb begin
    partial_sum = 33'sh0;
    for (int unsigned i = 0; i < NUM_LANES; i++) begin
      // Unpack: little-endian, lane[i] = word[8*i +: 8]
      automatic logic signed [7:0] a_val = signed'(a_data_i[8*i +: 8]);
      automatic logic signed [7:0] b_val = signed'(b_data_i[8*i +: 8]);
      products[i] = a_val * b_val;
      partial_sum = partial_sum + 33'(products[i]);
    end
  end

  // ---------------------------------------------------------------------------
  // Saturating INT32 accumulator
  // ---------------------------------------------------------------------------
  logic signed [32:0] accum_q;      // 33-bit for overflow detection
  logic signed [32:0] accum_next;

  // Saturation constants
  localparam logic signed [32:0] SAT_MAX = 33'sh0_7FFF_FFFF;  // +2147483647
  localparam logic signed [32:0] SAT_MIN = 33'sh1_8000_0000;  // -2147483648

  always_comb begin
    accum_next = accum_q + partial_sum;
    // Saturate to INT32 range
    if (accum_next > SAT_MAX) begin
      accum_next = SAT_MAX;
    end else if (accum_next < SAT_MIN) begin
      accum_next = SAT_MIN;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      accum_q <= 33'sh0;
    end else if (clear_i) begin
      accum_q <= 33'sh0;
    end else if (valid_i) begin
      accum_q <= accum_next;
    end
  end

  // Output: truncate 33-bit to 32-bit (always in range after saturation)
  assign result_o = accum_q[31:0];

endmodule
