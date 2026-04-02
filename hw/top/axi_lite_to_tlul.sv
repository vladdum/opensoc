// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// AXI4-Lite (slave) to TileLink-UL (master) bridge.
//
// Single outstanding transaction. Writes require both AW and W valid before
// issuing a TL-UL PutFullData/PutPartialData. Reads issue a Get. The D-channel
// response is routed back to the AXI B (write) or R (read) channel.

module axi_lite_to_tlul #(
  parameter int unsigned AddrWidth = 32,
  parameter int unsigned DataWidth = 32,
  parameter int unsigned SourceWidth = 1
) (
  input  logic clk_i,
  input  logic rst_ni,

  // -----------------------------------------------------------------------
  // AXI4-Lite slave interface
  // -----------------------------------------------------------------------
  // AW
  input  logic [AddrWidth-1:0]   axi_aw_addr_i,
  input  logic [2:0]             axi_aw_prot_i,
  input  logic                   axi_aw_valid_i,
  output logic                   axi_aw_ready_o,
  // W
  input  logic [DataWidth-1:0]   axi_w_data_i,
  input  logic [DataWidth/8-1:0] axi_w_strb_i,
  input  logic                   axi_w_valid_i,
  output logic                   axi_w_ready_o,
  // B
  output logic [1:0]             axi_b_resp_o,
  output logic                   axi_b_valid_o,
  input  logic                   axi_b_ready_i,
  // AR
  input  logic [AddrWidth-1:0]   axi_ar_addr_i,
  input  logic [2:0]             axi_ar_prot_i,
  input  logic                   axi_ar_valid_i,
  output logic                   axi_ar_ready_o,
  // R
  output logic [DataWidth-1:0]   axi_r_data_o,
  output logic [1:0]             axi_r_resp_o,
  output logic                   axi_r_valid_o,
  input  logic                   axi_r_ready_i,

  // -----------------------------------------------------------------------
  // TL-UL master interface
  // -----------------------------------------------------------------------
  // A channel
  output logic [2:0]                      tl_a_opcode_o,
  output logic [2:0]                      tl_a_param_o,
  output logic [$clog2(DataWidth/8)-1:0]  tl_a_size_o,
  output logic [SourceWidth-1:0]          tl_a_source_o,
  output logic [AddrWidth-1:0]            tl_a_address_o,
  output logic [DataWidth/8-1:0]          tl_a_mask_o,
  output logic [DataWidth-1:0]            tl_a_data_o,
  output logic                            tl_a_valid_o,
  input  logic                            tl_a_ready_i,
  // D channel
  input  logic [2:0]                      tl_d_opcode_i,
  input  logic [2:0]                      tl_d_param_i,
  input  logic [$clog2(DataWidth/8)-1:0]  tl_d_size_i,
  input  logic [SourceWidth-1:0]          tl_d_source_i,
  input  logic [DataWidth-1:0]            tl_d_data_i,
  input  logic                            tl_d_error_i,
  input  logic                            tl_d_valid_i,
  output logic                            tl_d_ready_o
);

  // TL-UL A-channel opcodes
  localparam logic [2:0] TlGet             = 3'd4;
  localparam logic [2:0] TlPutFullData     = 3'd0;
  localparam logic [2:0] TlPutPartialData  = 3'd1;

  // AXI response codes
  localparam logic [1:0] AxiRespOkay  = 2'b00;
  localparam logic [1:0] AxiRespSlvErr = 2'b10;

  // Full-word strobe (all bytes active)
  localparam logic [DataWidth/8-1:0] FullStrobe = {(DataWidth/8){1'b1}};

  // Natural size for full data width: log2(DataWidth/8)
  localparam int unsigned NaturalSizeInt = $clog2(DataWidth/8);
  localparam logic [$clog2(DataWidth/8)-1:0] NaturalSize =
      NaturalSizeInt[$clog2(DataWidth/8)-1:0];

  // FSM states
  typedef enum logic [2:0] {
    IDLE,
    TL_REQ,     // drive A-channel valid, wait for ready
    TL_RESP,    // wait for D-channel valid
    AXI_RESP    // drive AXI B or R response, wait for ready
  } state_e;

  state_e                  state_q, state_d;
  logic                    is_write_q, is_write_d;
  logic [AddrWidth-1:0]    addr_q, addr_d;
  logic [DataWidth-1:0]    wdata_q, wdata_d;
  logic [DataWidth/8-1:0]  wstrb_q, wstrb_d;
  logic [DataWidth-1:0]    rdata_q, rdata_d;
  logic                    resp_err_q, resp_err_d;

  // Write request accepted when both AW and W are valid
  logic wr_req;
  assign wr_req = axi_aw_valid_i & axi_w_valid_i;

  // -----------------------------------------------------------------------
  // FSM
  // -----------------------------------------------------------------------
  always_comb begin
    state_d    = state_q;
    is_write_d = is_write_q;
    addr_d     = addr_q;
    wdata_d    = wdata_q;
    wstrb_d    = wstrb_q;
    rdata_d    = rdata_q;
    resp_err_d = resp_err_q;

    // AXI defaults — no handshake
    axi_aw_ready_o = 1'b0;
    axi_w_ready_o  = 1'b0;
    axi_ar_ready_o = 1'b0;
    axi_b_valid_o  = 1'b0;
    axi_r_valid_o  = 1'b0;

    // TL-UL defaults
    tl_a_valid_o = 1'b0;
    tl_d_ready_o = 1'b0;

    unique case (state_q)
      // -----------------------------------------------------------------
      IDLE: begin
        // Writes have priority over reads
        if (wr_req) begin
          axi_aw_ready_o = 1'b1;
          axi_w_ready_o  = 1'b1;
          is_write_d     = 1'b1;
          addr_d         = axi_aw_addr_i;
          wdata_d        = axi_w_data_i;
          wstrb_d        = axi_w_strb_i;
          state_d        = TL_REQ;
        end else if (axi_ar_valid_i) begin
          axi_ar_ready_o = 1'b1;
          is_write_d     = 1'b0;
          addr_d         = axi_ar_addr_i;
          state_d        = TL_REQ;
        end
      end

      // -----------------------------------------------------------------
      TL_REQ: begin
        tl_a_valid_o = 1'b1;
        if (tl_a_ready_i) begin
          state_d = TL_RESP;
        end
      end

      // -----------------------------------------------------------------
      TL_RESP: begin
        tl_d_ready_o = 1'b1;
        if (tl_d_valid_i) begin
          rdata_d    = tl_d_data_i;
          resp_err_d = tl_d_error_i;
          state_d    = AXI_RESP;
        end
      end

      // -----------------------------------------------------------------
      AXI_RESP: begin
        if (is_write_q) begin
          axi_b_valid_o = 1'b1;
          if (axi_b_ready_i) state_d = IDLE;
        end else begin
          axi_r_valid_o = 1'b1;
          if (axi_r_ready_i) state_d = IDLE;
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // -----------------------------------------------------------------------
  // Sequential
  // -----------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= IDLE;
      is_write_q <= 1'b0;
      addr_q     <= '0;
      wdata_q    <= '0;
      wstrb_q    <= '0;
      rdata_q    <= '0;
      resp_err_q <= 1'b0;
    end else begin
      state_q    <= state_d;
      is_write_q <= is_write_d;
      addr_q     <= addr_d;
      wdata_q    <= wdata_d;
      wstrb_q    <= wstrb_d;
      rdata_q    <= rdata_d;
      resp_err_q <= resp_err_d;
    end
  end

  // -----------------------------------------------------------------------
  // TL-UL A-channel outputs
  // -----------------------------------------------------------------------
  assign tl_a_opcode_o  = is_write_q ? ((wstrb_q == FullStrobe) ? TlPutFullData
                                                                 : TlPutPartialData)
                                      : TlGet;
  assign tl_a_param_o   = 3'd0;
  assign tl_a_size_o    = NaturalSize;
  assign tl_a_source_o  = '0;
  assign tl_a_address_o = addr_q;
  assign tl_a_mask_o    = is_write_q ? wstrb_q : FullStrobe;
  assign tl_a_data_o    = wdata_q;

  // -----------------------------------------------------------------------
  // AXI4-Lite response outputs
  // -----------------------------------------------------------------------
  assign axi_b_resp_o = resp_err_q ? AxiRespSlvErr : AxiRespOkay;
  assign axi_r_data_o = rdata_q;
  assign axi_r_resp_o = resp_err_q ? AxiRespSlvErr : AxiRespOkay;

  // Unused input signals
  logic _unused;
  assign _unused = &{axi_aw_prot_i, axi_ar_prot_i, tl_d_opcode_i, tl_d_param_i,
                      tl_d_size_i, tl_d_source_i};

endmodule
