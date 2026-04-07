// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * 8×8 Weight-Stationary Systolic Array
 *
 * ARRAY_M rows (K dimension) × ARRAY_N columns (N dimension).
 * pe_cell[k][n] holds weight B[k][n].
 *
 * Weight loading:
 *   When set_w_i is asserted, the weight identified by w_addr_i
 *   (k = w_addr_i[5:3], n = w_addr_i[2:0]) is loaded with w_data_i.
 *
 * Computation:
 *   On en_i, all ARRAY_M rows are enabled simultaneously for one cycle.
 *   Row k receives a_i[k] from data_skew; this value is also passed east
 *   through pe_cells (a_out → a_in for next column) but each column also
 *   receives a_i[k] directly for its accumulation.
 *
 *   Each pe_cell[k][n]: acc[k][n] += a_i[k] × B[k][n]
 *
 *   After ARRAY_M enable pulses (one per k-step), acc[k][n] = A[m][k]×B[k][n].
 *   result_drain then sums: C[m][n] = Σ_k acc[k][n].
 */
module systolic_array #(
  parameter int unsigned ARRAY_M = 8,
  parameter int unsigned ARRAY_N = 8,
  parameter int unsigned DATA_W  = 8,
  parameter int unsigned ACC_W   = 32
) (
  input  logic                                          clk_i,
  input  logic                                          rst_ni,
  input  logic                                          clr_i,
  input  logic                                          en_i,
  // Weight loading
  input  logic                                          set_w_i,
  input  logic [5:0]                                    w_addr_i, // k[5:3], n[2:0]
  input  logic signed [DATA_W-1:0]                      w_data_i,
  // Activation inputs (one per row, from data_skew)
  input  logic signed [ARRAY_M-1:0][DATA_W-1:0]         a_i,
  // Accumulator outputs
  output logic signed [ARRAY_M-1:0][ARRAY_N-1:0][ACC_W-1:0] acc_o
);

  // Unused a_out wires (east propagation present structurally but not used for computation)
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [ARRAY_M-1:0][ARRAY_N-1:0][DATA_W-1:0] a_east;
  /* verilator lint_on UNUSEDSIGNAL */

  for (genvar k = 0; k < ARRAY_M; k++) begin : gen_row
    for (genvar n = 0; n < ARRAY_N; n++) begin : gen_col
      // Each PE in column n of row k:
      //   - receives activation a_i[k] directly (weight-stationary: data broadcast per row)
      //   - also passes a_in east (structural requirement)
      //   - weight address = k*8 + n
      pe_cell #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .clr_i   (clr_i),
        .en_i    (en_i),
        .set_w_i (set_w_i && (w_addr_i == 6'(k * ARRAY_N + n))),
        .w_i     (w_data_i),
        .a_in_i  (a_i[k]),
        .a_out_o (a_east[k][n]),
        .acc_o   (acc_o[k][n])
      );
    end
  end

endmodule
