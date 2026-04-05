// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Line Buffer for 2D Convolution
 *
 * Stores 3 image rows in flip-flop arrays of depth MAX_WIDTH (INT8 each).
 * conv2d.sv indexes pixels_o directly to form the 3×3 sliding window.
 * Synchronous clear via clr_i (SOFT_RESET).
 */
module line_buffer #(
  parameter int unsigned MAX_WIDTH = 64
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,
  input  logic                           clr_i,

  // Write port: one pixel per cycle
  input  logic                           wr_en_i,
  input  logic [1:0]                     wr_row_i,
  input  logic [$clog2(MAX_WIDTH)-1:0]   wr_col_i,
  input  logic signed [7:0]              wr_data_i,

  // Read port: full pixel array (combinational output of all FFs)
  output logic signed [7:0]              pixels_o [3][MAX_WIDTH]
);

  logic signed [7:0] lb [3][MAX_WIDTH];
  assign pixels_o = lb;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int r = 0; r < 3; r++)
        for (int c = 0; c < MAX_WIDTH; c++)
          lb[r][c] <= 8'sh0;
    end else if (clr_i) begin
      for (int r = 0; r < 3; r++)
        for (int c = 0; c < MAX_WIDTH; c++)
          lb[r][c] <= 8'sh0;
    end else if (wr_en_i) begin
      lb[wr_row_i][wr_col_i] <= wr_data_i;
    end
  end

endmodule
