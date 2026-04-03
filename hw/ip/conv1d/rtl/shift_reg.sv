// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Parameterized Shift Register
 *
 * DEPTH-stage shift register with WIDTH-bit signed elements. When load_i is
 * asserted, data_i is shifted into reg[0] and existing entries advance one
 * position (reg[k-1] → reg[k]). All DEPTH entries are presented simultaneously
 * on regs_o for the convolution PE.
 *
 * Synchronous clear (clr_i) zeroes all stages in one cycle (used by SOFT_RESET).
 */
module shift_reg #(
  parameter int unsigned DEPTH = 16,
  parameter int unsigned WIDTH = 8
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  logic                          clr_i,   // synchronous clear (SOFT_RESET)
  input  logic                          load_i,  // shift in new sample
  input  logic signed [WIDTH-1:0]       data_i,

  output logic signed [WIDTH-1:0]       regs_o [DEPTH]
);

  logic signed [WIDTH-1:0] reg_q [DEPTH];

  assign regs_o = reg_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < DEPTH; i++) reg_q[i] <= '0;
    end else if (clr_i) begin
      for (int i = 0; i < DEPTH; i++) reg_q[i] <= '0;
    end else if (load_i) begin
      reg_q[0] <= data_i;
      for (int i = 1; i < DEPTH; i++) reg_q[i] <= reg_q[i-1];
    end
  end

endmodule
