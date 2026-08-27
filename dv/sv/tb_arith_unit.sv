// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * tb_arith_unit
 *
 * Smoke + random equivalence test for one (KIND, PIPE_STAGES) configuration of
 * either `adder` or `mul_signed`, against the operator-default reference.
 *
 * Compile-time selectors (override via Verilator -G):
 *   UNIT_KIND : 0 = adder, 1 = multiplier
 *   K_ID      : enum index (cast to add_kind_e or mul_kind_e)
 *   PIPE      : pipeline stages (0 or 1)
 *
 * Defaults (UNIT_KIND=0, K_ID=0, PIPE=0) test the operator-default adder
 * against itself — a sanity check.
 */

module tb_arith_unit
  import arith_pkg::*;
#(
  parameter int unsigned UNIT_KIND = 0,  // 0 = adder, 1 = mul_signed
  parameter int unsigned K_ID      = 0,  // cast to add_kind_e or mul_kind_e
  parameter int unsigned PIPE      = 0
);

  // Adder-side: 33-bit (matches vec_mac use)
  localparam int unsigned ADD_W = 33;

  // Mul-side: 8x8 → 16 (matches vec_mac use)
  localparam int unsigned MUL_A_W = 8;
  localparam int unsigned MUL_B_W = 8;
  localparam int unsigned MUL_P_W = MUL_A_W + MUL_B_W;

  /* verilator lint_off PROCASSINIT */
  logic clk = 0;
  /* verilator lint_on PROCASSINIT */
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ─── Adder DUT and reference ───────────────────────────────────────────
  logic signed [ADD_W-1:0] add_a, add_b, add_dut, add_ref;

  adder #(.W(ADD_W), .KIND(add_kind_e'(K_ID)), .PIPE_STAGES(PIPE)) u_add_dut (
    .clk_i(clk), .rst_ni(rst_n), .a_i(add_a), .b_i(add_b), .s_o(add_dut)
  );
  adder #(.W(ADD_W), .KIND(ADD_OPERATOR), .PIPE_STAGES(PIPE)) u_add_ref (
    .clk_i(clk), .rst_ni(rst_n), .a_i(add_a), .b_i(add_b), .s_o(add_ref)
  );

  // ─── Multiplier DUT and reference ──────────────────────────────────────
  logic signed [MUL_A_W-1:0] mul_a;
  logic signed [MUL_B_W-1:0] mul_b;
  logic signed [MUL_P_W-1:0] mul_dut, mul_ref;

  mul_signed #(.A_W(MUL_A_W), .B_W(MUL_B_W), .P_W(MUL_P_W),
               .KIND(mul_kind_e'(K_ID)), .PIPE_STAGES(PIPE)) u_mul_dut (
    .clk_i(clk), .rst_ni(rst_n), .a_i(mul_a), .b_i(mul_b), .p_o(mul_dut)
  );
  mul_signed #(.A_W(MUL_A_W), .B_W(MUL_B_W), .P_W(MUL_P_W),
               .KIND(MUL_OPERATOR), .PIPE_STAGES(PIPE)) u_mul_ref (
    .clk_i(clk), .rst_ni(rst_n), .a_i(mul_a), .b_i(mul_b), .p_o(mul_ref)
  );

  // ─── Stimulus + check ──────────────────────────────────────────────────
  int unsigned errors = 0;
  int unsigned vectors = 0;
  int unsigned seed;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 32'hC0FFEE;

    add_a = '0; add_b = '0;
    mul_a = '0; mul_b = '0;
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // Directed corner cases
    foreach_corner: begin
      /* verilator lint_off IMPLICITSTATIC */
      logic signed [ADD_W-1:0] addv [] = '{
        '0, ADD_W'(33'sh0_0000_0001), ADD_W'(-1),
        ADD_W'(33'sh0_7FFF_FFFF), ADD_W'(33'sh1_8000_0000),
        ADD_W'(33'sh0_AAAAAAAA), ADD_W'(33'sh1_55555555)
      };
      logic signed [MUL_A_W-1:0] mva [] = '{8'sh00, 8'sh01, -8'sh01,
                                            8'sh7F, -8'sh7F, -8'sh80,
                                            8'sh55, -8'sh55};
      /* verilator lint_on IMPLICITSTATIC */
      foreach (addv[i]) foreach (addv[j]) begin
        add_a = addv[i]; add_b = addv[j];
        @(negedge clk);
        check_add();
      end
      foreach (mva[i]) foreach (mva[j]) begin
        mul_a = mva[i]; mul_b = mva[j];
        @(negedge clk);
        check_mul();
      end
    end

    // Random
    for (int n = 0; n < 10000; n++) begin
      /* verilator lint_off WIDTHEXPAND */
      add_a = ADD_W'({$urandom(seed), $urandom(seed)});
      add_b = ADD_W'({$urandom(seed), $urandom(seed)});
      /* verilator lint_on WIDTHEXPAND */
      /* verilator lint_off WIDTHTRUNC */
      mul_a = MUL_A_W'($urandom(seed));
      mul_b = MUL_B_W'($urandom(seed));
      /* verilator lint_on WIDTHTRUNC */
      @(negedge clk);
      check_add();
      check_mul();
    end

    if (errors > 0) begin
      $display("FAIL tb_arith_unit (UNIT_KIND=%0d K_ID=%0d PIPE=%0d): %0d errors / %0d vectors",
               UNIT_KIND, K_ID, PIPE, errors, vectors);
      $fatal(1);
    end else begin
      $display("PASS tb_arith_unit (UNIT_KIND=%0d K_ID=%0d PIPE=%0d): %0d vectors",
               UNIT_KIND, K_ID, PIPE, vectors);
      $finish;
    end
  end

  task automatic check_add();
    vectors++;
    if (UNIT_KIND == 0 && add_dut !== add_ref) begin
      errors++;
      if (errors < 8)
        $display("  ADD MISMATCH a=%h b=%h dut=%h ref=%h",
                 add_a, add_b, add_dut, add_ref);
    end
  endtask

  task automatic check_mul();
    vectors++;
    if (UNIT_KIND == 1 && mul_dut !== mul_ref) begin
      errors++;
      if (errors < 8)
        $display("  MUL MISMATCH a=%h b=%h dut=%h ref=%h",
                 mul_a, mul_b, mul_dut, mul_ref);
    end
  endtask

endmodule
