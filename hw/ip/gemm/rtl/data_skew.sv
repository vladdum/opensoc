// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Data Skew Module
 *
 * Presents a single data/valid input to ARRAY_M rows with staggered delays:
 * row 0 sees the input with 0 cycles delay, row 1 with 1 cycle, ...,
 * row ARRAY_M-1 with ARRAY_M-1 cycles.  This ensures that if the input
 * stream feeds A[m][ARRAY_M-1], A[m][ARRAY_M-2], ..., A[m][0] over
 * ARRAY_M consecutive cycles, all rows receive their correct A[m][k] element
 * simultaneously at the last cycle (when en_all fires).
 *
 * Fixed for ARRAY_M = 8 to avoid for-loop non-blocking assignment issues
 * in Verilator.
 */
module data_skew #(
  parameter int unsigned ARRAY_M = 8,
  parameter int unsigned DATA_W  = 8
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic signed [DATA_W-1:0]      data_i,
  input  logic                          valid_i,
  output logic signed [ARRAY_M-1:0][DATA_W-1:0] data_o,
  output logic        [ARRAY_M-1:0]              valid_o
);

  // Seven pipeline stages (row k taps stage k-1 for k>=1; row 0 is direct)
  logic signed [DATA_W-1:0] p0_d, p1_d, p2_d, p3_d, p4_d, p5_d, p6_d;
  logic                     p0_v, p1_v, p2_v, p3_v, p4_v, p5_v, p6_v;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p0_d <= '0; p1_d <= '0; p2_d <= '0; p3_d <= '0;
      p4_d <= '0; p5_d <= '0; p6_d <= '0;
      p0_v <= '0; p1_v <= '0; p2_v <= '0; p3_v <= '0;
      p4_v <= '0; p5_v <= '0; p6_v <= '0;
    end else begin
      p0_d <= data_i;  p0_v <= valid_i;
      p1_d <= p0_d;    p1_v <= p0_v;
      p2_d <= p1_d;    p2_v <= p1_v;
      p3_d <= p2_d;    p3_v <= p2_v;
      p4_d <= p3_d;    p4_v <= p3_v;
      p5_d <= p4_d;    p5_v <= p4_v;
      p6_d <= p5_d;    p6_v <= p5_v;
    end
  end

  // Row 0: direct (no delay)
  assign data_o[0]  = data_i;
  assign valid_o[0] = valid_i;
  // Row 1: 1-cycle delay
  assign data_o[1]  = p0_d;
  assign valid_o[1] = p0_v;
  // Row 2: 2-cycle delay
  assign data_o[2]  = p1_d;
  assign valid_o[2] = p1_v;
  // Row 3: 3-cycle delay
  assign data_o[3]  = p2_d;
  assign valid_o[3] = p2_v;
  // Row 4: 4-cycle delay
  assign data_o[4]  = p3_d;
  assign valid_o[4] = p3_v;
  // Row 5: 5-cycle delay
  assign data_o[5]  = p4_d;
  assign valid_o[5] = p4_v;
  // Row 6: 6-cycle delay
  assign data_o[6]  = p5_d;
  assign valid_o[6] = p5_v;
  // Row 7: 7-cycle delay
  assign data_o[7]  = p6_d;
  assign valid_o[7] = p6_v;

endmodule
