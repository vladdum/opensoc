// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Systolic Array Processing Element
 *
 * Holds one INT8 weight register.  On each enabled cycle, accumulates:
 *   acc += a_in × weight
 * and passes a_in east (registered) for the next PE in the row.
 */
module pe_cell #(
  parameter int unsigned DATA_W = 8,
  parameter int unsigned ACC_W  = 32
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          clr_i,    // synchronous clear of accumulator
  input  logic                          en_i,     // accumulate this cycle
  input  logic                          set_w_i,  // load weight register
  input  logic signed [DATA_W-1:0]      w_i,      // weight to load
  input  logic signed [DATA_W-1:0]      a_in_i,   // activation input (from west / data_skew)
  output logic signed [DATA_W-1:0]      a_out_o,  // activation passed east (registered)
  output logic signed [ACC_W-1:0]       acc_o     // accumulated result
);

  logic signed [DATA_W-1:0] w_q;
  logic signed [ACC_W-1:0]  acc_q;
  logic signed [DATA_W-1:0] a_out_q;

  assign a_out_o = a_out_q;
  assign acc_o   = acc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_q     <= '0;
      acc_q   <= '0;
      a_out_q <= '0;
    end else begin
      a_out_q <= a_in_i;
      if (set_w_i) begin
        w_q <= w_i;
      end
      if (clr_i) begin
        acc_q <= '0;
      end else if (en_i) begin
        acc_q <= acc_q + ACC_W'(a_in_i * w_q);
      end
    end
  end

endmodule
