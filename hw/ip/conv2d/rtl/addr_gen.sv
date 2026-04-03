// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * DMA Read Address Generator for 2D Convolution
 *
 * rd_addr_o = src_addr_i + (cur_row_i * img_width_i + cur_col_i) * 4
 * Each pixel occupies one 32-bit word (× 4 bytes).
 */
module addr_gen (
  input  logic [31:0] src_addr_i,
  input  logic [31:0] img_width_i,
  input  logic [31:0] cur_row_i,
  input  logic [31:0] cur_col_i,
  output logic [31:0] rd_addr_o
);

  // Arithmetic is safe for image dimensions up to 64×64 (max offset = 63*64+63 = 4095, << 2 = 16380 < 2^32)
  assign rd_addr_o = src_addr_i + ((cur_row_i * img_width_i + cur_col_i) << 2);

endmodule
