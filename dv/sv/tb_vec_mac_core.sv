// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * tb_vec_mac_core
 *
 * Compares one vec_mac_core configuration (DUT) against an operator-default
 * reference, driven by identical stimulus. Both DUT and reference run with
 * the same MUL_PIPE/ADD_PIPE, so their accumulator updates align cycle-for-
 * cycle naturally — no external skid buffer needed.
 *
 * Compile-time parameters (override via Verilator -G):
 *   ADD_KID  : add_kind_e index
 *   MUL_KID  : mul_kind_e index
 *   MUL_PIPE : MUL_PIPE_STAGES
 *   ADD_PIPE : ADD_PIPE_STAGES
 */
module tb_vec_mac_core
  import arith_pkg::*;
#(
  parameter int unsigned ADD_KID  = 0,
  parameter int unsigned MUL_KID  = 0,
  parameter int unsigned MUL_PIPE = 0,
  parameter int unsigned ADD_PIPE = 0
);

  localparam int unsigned NUM_LANES = 4;
  localparam int unsigned TOTAL_PIPE = MUL_PIPE + ADD_PIPE;

  /* verilator lint_off PROCASSINIT */
  logic clk = 0;
  /* verilator lint_on PROCASSINIT */
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        valid;
  logic        clear;
  logic [31:0] a_data;
  logic [31:0] b_data;
  logic [31:0] dut_result;
  logic [31:0] ref_result;

  vec_mac_core #(
    .NUM_LANES       (NUM_LANES),
    .ADD_KIND        (add_kind_e'(ADD_KID)),
    .MUL_KIND        (mul_kind_e'(MUL_KID)),
    .MUL_PIPE_STAGES (MUL_PIPE),
    .ADD_PIPE_STAGES (ADD_PIPE)
  ) u_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .clear_i(clear), .valid_i(valid),
    .a_data_i(a_data), .b_data_i(b_data),
    .result_o(dut_result)
  );

  vec_mac_core #(
    .NUM_LANES       (NUM_LANES),
    .ADD_KIND        (ADD_OPERATOR),
    .MUL_KIND        (MUL_OPERATOR),
    .MUL_PIPE_STAGES (MUL_PIPE),
    .ADD_PIPE_STAGES (ADD_PIPE)
  ) u_ref (
    .clk_i(clk), .rst_ni(rst_n),
    .clear_i(clear), .valid_i(valid),
    .a_data_i(a_data), .b_data_i(b_data),
    .result_o(ref_result)
  );

  int unsigned errors = 0;
  int unsigned vectors = 0;
  int unsigned seed;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 32'hC0FFEE;

    valid = 0; clear = 0;
    a_data = 0; b_data = 0;
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // Clear accumulators
    clear = 1;
    @(negedge clk);
    clear = 0;
    @(negedge clk);

    // Directed corner cases
    do_directed();

    // Random burst
    do_random_burst(10000);

    // Latency-edge: back-to-back valid_i
    do_back_to_back(100);

    // Drain
    repeat (TOTAL_PIPE + 4) @(negedge clk);

    if (errors > 0) begin
      $display("FAIL tb_vec_mac_core (ADD_KID=%0d MUL_KID=%0d MUL_PIPE=%0d ADD_PIPE=%0d): %0d errors / %0d vectors",
               ADD_KID, MUL_KID, MUL_PIPE, ADD_PIPE, errors, vectors);
      $fatal(1);
    end else begin
      $display("PASS tb_vec_mac_core (ADD_KID=%0d MUL_KID=%0d MUL_PIPE=%0d ADD_PIPE=%0d): %0d vectors",
               ADD_KID, MUL_KID, MUL_PIPE, ADD_PIPE, vectors);
      $finish;
    end
  end

  task automatic do_directed();
    logic [31:0] av, bv;
    av = '0; bv = '0;
    pulse_pair(av, bv);
    av = {8'sh7F, 8'sh7F, 8'sh7F, 8'sh7F};
    bv = {8'sh7F, 8'sh7F, 8'sh7F, 8'sh7F};
    pulse_pair(av, bv);
    av = {8'sh80, 8'sh80, 8'sh80, 8'sh80};
    bv = {8'sh80, 8'sh80, 8'sh80, 8'sh80};
    pulse_pair(av, bv);
    av = {8'sh7F, 8'sh80, 8'sh7F, 8'sh80};
    bv = {8'sh7F, 8'sh7F, 8'sh80, 8'sh80};
    pulse_pair(av, bv);
    repeat (1024) pulse_pair(32'h7F7F7F7F, 32'h7F7F7F7F);
    clear = 1; @(negedge clk); clear = 0; @(negedge clk);
    repeat (1024) pulse_pair(32'h80808080, 32'h7F7F7F7F);
  endtask

  task automatic do_random_burst(int unsigned n);
    for (int i = 0; i < n; i++) begin
      /* verilator lint_off WIDTHTRUNC */
      logic [31:0] av = {$urandom(seed), $urandom(seed)};
      logic [31:0] bv = {$urandom(seed), $urandom(seed)};
      /* verilator lint_on WIDTHTRUNC */
      pulse_pair(av, bv);
      if (($urandom(seed) & 32'h3FF) == 0) begin
        clear = 1; @(negedge clk); clear = 0;
      end
    end
  endtask

  task automatic do_back_to_back(int unsigned n);
    for (int i = 0; i < n; i++) begin
      /* verilator lint_off WIDTHTRUNC */
      logic [31:0] av = {$urandom(seed), $urandom(seed)};
      logic [31:0] bv = {$urandom(seed), $urandom(seed)};
      /* verilator lint_on WIDTHTRUNC */
      pulse_pair(av, bv);
    end
  endtask

  task automatic pulse_pair(logic [31:0] av, logic [31:0] bv);
    a_data = av; b_data = bv; valid = 1;
    @(negedge clk);
    valid = 0;
    @(negedge clk);
    repeat (TOTAL_PIPE) @(negedge clk);
    vectors++;
    if (dut_result !== ref_result) begin
      errors++;
      if (errors < 8)
        $display("  MISMATCH cycle=%0d a=%h b=%h dut=%h ref=%h",
                 $time, av, bv, dut_result, ref_result);
    end
  endtask

endmodule
