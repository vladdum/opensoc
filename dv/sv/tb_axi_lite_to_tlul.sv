// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Simple testbench for axi_lite_to_tlul bridge.
// Tests: single write, single read, write with partial strobe, error response.
//
// All testbench driving happens on @(negedge clk) to avoid delta-cycle races
// with the DUT's combinational logic evaluated at @(posedge clk).

module tb_axi_lite_to_tlul;

  localparam int unsigned AddrWidth   = 32;
  localparam int unsigned DataWidth   = 32;
  localparam int unsigned SourceWidth = 1;
  localparam int unsigned StrbWidth   = DataWidth / 8;

  // TL-UL opcodes
  localparam logic [2:0] TlAccessAckData = 3'd1;
  localparam logic [2:0] TlAccessAck     = 3'd0;

  logic clk, rst_n;

  // AXI4-Lite signals
  logic [AddrWidth-1:0]  aw_addr;
  logic [2:0]            aw_prot;
  logic                  aw_valid, aw_ready;

  logic [DataWidth-1:0]  w_data;
  logic [StrbWidth-1:0]  w_strb;
  logic                  w_valid, w_ready;

  logic [1:0]            b_resp;
  logic                  b_valid, b_ready;

  logic [AddrWidth-1:0]  ar_addr;
  logic [2:0]            ar_prot;
  logic                  ar_valid, ar_ready;

  logic [DataWidth-1:0]  r_data;
  logic [1:0]            r_resp;
  logic                  r_valid, r_ready;

  // TL-UL signals
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0]                     tl_a_opcode;
  logic [2:0]                     tl_a_param;
  logic [$clog2(StrbWidth)-1:0]   tl_a_size;
  logic [SourceWidth-1:0]         tl_a_source;
  logic [AddrWidth-1:0]           tl_a_address;
  logic [StrbWidth-1:0]           tl_a_mask;
  logic [DataWidth-1:0]           tl_a_data;
  /* verilator lint_on UNUSEDSIGNAL */
  logic                           tl_a_valid, tl_a_ready;

  logic [2:0]                     tl_d_opcode;
  logic [2:0]                     tl_d_param;
  logic [$clog2(StrbWidth)-1:0]   tl_d_size;
  logic [SourceWidth-1:0]         tl_d_source;
  logic [DataWidth-1:0]           tl_d_data;
  logic                           tl_d_error;
  logic                           tl_d_valid, tl_d_ready;

  // -----------------------------------------------------------------------
  // DUT
  // -----------------------------------------------------------------------
  axi_lite_to_tlul #(
    .AddrWidth   (AddrWidth),
    .DataWidth   (DataWidth),
    .SourceWidth (SourceWidth)
  ) dut (
    .clk_i            (clk),
    .rst_ni           (rst_n),
    .axi_aw_addr_i    (aw_addr),
    .axi_aw_prot_i    (aw_prot),
    .axi_aw_valid_i   (aw_valid),
    .axi_aw_ready_o   (aw_ready),
    .axi_w_data_i     (w_data),
    .axi_w_strb_i     (w_strb),
    .axi_w_valid_i    (w_valid),
    .axi_w_ready_o    (w_ready),
    .axi_b_resp_o     (b_resp),
    .axi_b_valid_o    (b_valid),
    .axi_b_ready_i    (b_ready),
    .axi_ar_addr_i    (ar_addr),
    .axi_ar_prot_i    (ar_prot),
    .axi_ar_valid_i   (ar_valid),
    .axi_ar_ready_o   (ar_ready),
    .axi_r_data_o     (r_data),
    .axi_r_resp_o     (r_resp),
    .axi_r_valid_o    (r_valid),
    .axi_r_ready_i    (r_ready),
    .tl_a_opcode_o    (tl_a_opcode),
    .tl_a_param_o     (tl_a_param),
    .tl_a_size_o      (tl_a_size),
    .tl_a_source_o    (tl_a_source),
    .tl_a_address_o   (tl_a_address),
    .tl_a_mask_o      (tl_a_mask),
    .tl_a_data_o      (tl_a_data),
    .tl_a_valid_o     (tl_a_valid),
    .tl_a_ready_i     (tl_a_ready),
    .tl_d_opcode_i    (tl_d_opcode),
    .tl_d_param_i     (tl_d_param),
    .tl_d_size_i      (tl_d_size),
    .tl_d_source_i    (tl_d_source),
    .tl_d_data_i      (tl_d_data),
    .tl_d_error_i     (tl_d_error),
    .tl_d_valid_i     (tl_d_valid),
    .tl_d_ready_o     (tl_d_ready)
  );

  // -----------------------------------------------------------------------
  // Clock & reset
  // -----------------------------------------------------------------------
  initial begin
    clk = 0;
    forever #5 clk = !clk;
  end

  int pass_count;
  int fail_count;

  // -----------------------------------------------------------------------
  // Helper tasks — all driving on negedge to avoid races
  // -----------------------------------------------------------------------

  task automatic reset();
    rst_n      = 0;
    aw_addr    = '0; aw_prot = '0; aw_valid = 0;
    w_data     = '0; w_strb  = '0; w_valid  = 0;
    b_ready    = 0;
    ar_addr    = '0; ar_prot = '0; ar_valid = 0;
    r_ready    = 0;
    tl_a_ready = 0;
    tl_d_opcode = '0; tl_d_param = '0; tl_d_size = '0;
    tl_d_source = '0; tl_d_data  = '0; tl_d_error = 0;
    tl_d_valid  = 0;
    pass_count  = 0;
    fail_count  = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  task automatic check(
    string name, logic [31:0] actual, logic [31:0] expected
  );
    if (actual === expected) begin
      $display("[PASS] %s: 0x%08h", name, actual);
      pass_count++;
    end else begin
      $display(
        "[FAIL] %s: got 0x%08h, expected 0x%08h",
        name, actual, expected
      );
      fail_count++;
    end
  endtask

  // Issue an AXI write and respond on TL-UL D channel
  task automatic axi_write(
    input  logic [AddrWidth-1:0]  addr,
    input  logic [DataWidth-1:0]  data,
    input  logic [StrbWidth-1:0]  strb,
    input  logic                  tl_err,
    output logic [1:0]            resp
  );
    // Drive AW + W on negedge so they are stable at next posedge
    @(negedge clk);
    aw_addr  = addr;
    aw_valid = 1;
    w_data   = data;
    w_strb   = strb;
    w_valid  = 1;

    // Wait for AW/W handshake at posedge
    forever begin
      @(posedge clk);
      if (aw_ready && w_ready) break;
    end

    // Deassert on negedge (after posedge registered the transition)
    @(negedge clk);
    aw_valid = 0;
    w_valid  = 0;

    // Accept TL-UL A channel: assert ready on negedge
    tl_a_ready = 1;
    forever begin
      @(posedge clk);
      if (tl_a_valid && tl_a_ready) break;
    end
    @(negedge clk);
    tl_a_ready = 0;

    // Respond on TL-UL D channel
    @(negedge clk);
    tl_d_opcode = TlAccessAck;
    tl_d_data   = '0;
    tl_d_error  = tl_err;
    tl_d_valid  = 1;

    forever begin
      @(posedge clk);
      if (tl_d_valid && tl_d_ready) break;
    end
    @(negedge clk);
    tl_d_valid = 0;

    // Accept AXI B response
    b_ready = 1;
    forever begin
      @(posedge clk);
      if (b_valid && b_ready) break;
    end
    resp = b_resp;
    @(negedge clk);
    b_ready = 0;
  endtask

  // Issue an AXI read and respond on TL-UL D channel
  task automatic axi_read(
    input  logic [AddrWidth-1:0]  addr,
    input  logic [DataWidth-1:0]  tl_rdata,
    input  logic                  tl_err,
    output logic [DataWidth-1:0]  data,
    output logic [1:0]            resp
  );
    // Drive AR on negedge
    @(negedge clk);
    ar_addr  = addr;
    ar_valid = 1;

    // Wait for AR handshake
    forever begin
      @(posedge clk);
      if (ar_valid && ar_ready) break;
    end
    @(negedge clk);
    ar_valid = 0;

    // Accept TL-UL A channel
    tl_a_ready = 1;
    forever begin
      @(posedge clk);
      if (tl_a_valid && tl_a_ready) break;
    end
    @(negedge clk);
    tl_a_ready = 0;

    // Respond on TL-UL D channel
    @(negedge clk);
    tl_d_opcode = TlAccessAckData;
    tl_d_data   = tl_rdata;
    tl_d_error  = tl_err;
    tl_d_valid  = 1;

    forever begin
      @(posedge clk);
      if (tl_d_valid && tl_d_ready) break;
    end
    @(negedge clk);
    tl_d_valid = 0;

    // Accept AXI R response
    r_ready = 1;
    forever begin
      @(posedge clk);
      if (r_valid && r_ready) break;
    end
    data = r_data;
    resp = r_resp;
    @(negedge clk);
    r_ready = 0;
  endtask

  // -----------------------------------------------------------------------
  // Tests
  // -----------------------------------------------------------------------
  logic [1:0]           resp;
  logic [DataWidth-1:0] rdata;

  initial begin
    $display("========================================");
    $display("  AXI4-Lite to TL-UL Bridge Testbench");
    $display("========================================");

    reset();

    // Test 1: Full-word write
    $display("\n--- Test 1: Full-word write to 0x1000 ---");
    axi_write(32'h0000_1000, 32'hDEAD_BEEF, 4'hF, 1'b0, resp);
    check("write resp", {30'd0, resp}, 32'd0);

    // Test 2: Read back
    $display("\n--- Test 2: Read from 0x1000 ---");
    axi_read(32'h0000_1000, 32'hDEAD_BEEF, 1'b0, rdata, resp);
    check("read data", rdata, 32'hDEAD_BEEF);
    check("read resp", {30'd0, resp}, 32'd0);

    // Test 3: Partial-strobe write
    $display("\n--- Test 3: Partial write (byte 0) to 0x2000 ---");
    axi_write(32'h0000_2000, 32'h0000_00AB, 4'h1, 1'b0, resp);
    check("partial write resp", {30'd0, resp}, 32'd0);

    // Test 4: Write with TL-UL error
    $display("\n--- Test 4: Write with TL-UL error ---");
    axi_write(32'h0000_FFFF, 32'h1234_5678, 4'hF, 1'b1, resp);
    check("error write resp", {30'd0, resp}, 32'd2);

    // Test 5: Read with TL-UL error
    $display("\n--- Test 5: Read with TL-UL error ---");
    axi_read(32'h0000_FFFF, 32'h0, 1'b1, rdata, resp);
    check("error read resp", {30'd0, resp}, 32'd2);

    // Test 6: Back-to-back write then read
    $display("\n--- Test 6: Back-to-back write then read ---");
    axi_write(32'h0000_3000, 32'hCAFE_BABE, 4'hF, 1'b0, resp);
    check("b2b write resp", {30'd0, resp}, 32'd0);
    axi_read(32'h0000_3000, 32'hCAFE_BABE, 1'b0, rdata, resp);
    check("b2b read data", rdata, 32'hCAFE_BABE);

    // Summary
    $display("\n========================================");
    $display("  Results: %0d passed, %0d failed",
             pass_count, fail_count);
    $display("========================================");

    if (fail_count > 0) begin
      $fatal(1, "TEST FAILED");
    end else begin
      $display("ALL TESTS PASSED");
    end

    $finish;
  end

  // Timeout watchdog
  initial begin
    #100_000;
    $fatal(1, "TIMEOUT: testbench did not complete");
  end

endmodule
