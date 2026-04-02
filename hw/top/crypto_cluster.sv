// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Crypto cluster: wraps OpenTitan AES with the OpenSoC mem interface.
// Converts req/addr/we/be/wdata/rvalid/rdata → TL-UL (tl_h2d_t/tl_d2h_t)
// for the AES module. Consistent with other OpenSoC peripherals (UART, PIO,
// I2C, etc.).
//
// The mem interface grants immediately when TL-UL is ready. rvalid is
// asserted when the TL-UL D channel responds (may take >1 cycle for AES).
//
// Unused AES ports (EDN, keymgr sideload, lifecycle, alerts) are tied to
// safe defaults for standalone / simulation use.

module crypto_cluster
  import aes_pkg::*;
  import aes_reg_pkg::*;
#(
  // AES configuration — disable masking for simpler integration
  parameter bit          AES192Enable         = 1,
  parameter bit          AESGCMEnable         = 0,
  parameter bit          SecMasking           = 0,
  parameter sbox_impl_e  SecSBoxImpl          = SBoxImplLut,
  parameter bit          SecAllowForcingMasks = 0,
  parameter bit          SecSkipPRNGReseeding = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Memory-mapped slave interface (from axi_to_mem)
  input  logic        req_i,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,

  // Idle indicator (active when AES is idle)
  output logic        idle_o
);

  // -----------------------------------------------------------------------
  // MEM → TL-UL conversion
  // -----------------------------------------------------------------------
  // TL-UL opcodes
  localparam logic [2:0] TlGet            = 3'd4;
  localparam logic [2:0] TlPutFullData    = 3'd0;
  localparam logic [2:0] TlPutPartialData = 3'd1;

  tlul_pkg::tl_h2d_t tl_h2d;
  tlul_pkg::tl_d2h_t tl_d2h;

  // Drive A channel: valid when req_i and TL-UL accepted the previous one
  // (no outstanding request). Since peripherals in opensoc_top grant
  // immediately (mem_gnt = mem_req), we issue the TL-UL request on the
  // same cycle as req_i.

  logic outstanding_q;  // tracks if a TL-UL request is in flight

  always_comb begin
    tl_h2d = tlul_pkg::TL_H2D_DEFAULT;

    tl_h2d.a_valid   = req_i & ~outstanding_q;
    tl_h2d.a_opcode  = we_i ? ((be_i == 4'hF) ? tlul_pkg::PutFullData
                                               : tlul_pkg::PutPartialData)
                             : tlul_pkg::Get;
    tl_h2d.a_param   = 3'd0;
    tl_h2d.a_size    = top_pkg::TL_SZW'(2);  // 4 bytes
    tl_h2d.a_source  = '0;
    tl_h2d.a_address = addr_i;
    tl_h2d.a_mask    = be_i;
    tl_h2d.a_data    = wdata_i;

    // Compute TL-UL integrity (required by tlul_cmd_intg_chk / tlul_adapter_reg)
    tl_h2d.a_user.cmd_intg  = tlul_pkg::get_cmd_intg(tl_h2d);
    tl_h2d.a_user.data_intg = tlul_pkg::get_data_intg(wdata_i);

    // Always ready to accept D channel responses
    tl_h2d.d_ready   = 1'b1;
  end

  // Track outstanding request
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_q <= 1'b0;
    end else begin
      if (tl_h2d.a_valid && tl_d2h.a_ready) begin
        // Request accepted
        outstanding_q <= 1'b1;
      end
      if (tl_d2h.d_valid && tl_h2d.d_ready) begin
        // Response received
        outstanding_q <= 1'b0;
      end
    end
  end

  // Response: rvalid when D channel fires, rdata from D channel
  assign rvalid_o = tl_d2h.d_valid & tl_h2d.d_ready;
  assign rdata_o  = tl_d2h.d_data;

  // -----------------------------------------------------------------------
  // OpenTitan AES — tie off infrastructure ports
  // -----------------------------------------------------------------------

  // Lifecycle: escalation disabled (Off = normal operation)
  localparam lc_ctrl_pkg::lc_tx_t LcEscOff = lc_ctrl_pkg::Off;

  // EDN: tie off (PRNG reseeding skipped via SecSkipPRNGReseeding=1)
  edn_pkg::edn_req_t  edn_req;
  edn_pkg::edn_rsp_t  edn_rsp;
  assign edn_rsp = '{edn_ack:  edn_req.edn_req,
                      edn_fips: 1'b0,
                      edn_bus:  '0};

  // Keymgr: no sideload key
  keymgr_pkg::hw_key_req_t keymgr_key;
  assign keymgr_key = '{valid: 1'b0, key: '0};

  // Alerts: tie off receivers
  localparam int NumAlerts = aes_reg_pkg::NumAlerts;
  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx;
  prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx;
  for (genvar i = 0; i < NumAlerts; i++) begin : gen_alert_tieoff
    assign alert_rx[i] = prim_alert_pkg::ALERT_RX_DEFAULT;
  end

  // Idle output
  prim_mubi_pkg::mubi4_t aes_idle;
  assign idle_o = (aes_idle == prim_mubi_pkg::MuBi4True);

  aes #(
    .AES192Enable         (AES192Enable),
    .AESGCMEnable         (AESGCMEnable),
    .SecMasking           (SecMasking),
    .SecSBoxImpl          (SecSBoxImpl),
    .SecStartTriggerDelay (0),
    .SecAllowForcingMasks (SecAllowForcingMasks),
    .SecSkipPRNGReseeding (SecSkipPRNGReseeding),
    .AlertAsyncOn         ({NumAlerts{1'b1}})
  ) u_aes (
    .clk_i,
    .rst_ni,
    .rst_shadowed_ni (rst_ni),

    .idle_o          (aes_idle),

    .lc_escalate_en_i(LcEscOff),

    .clk_edn_i       (clk_i),
    .rst_edn_ni      (rst_ni),
    .edn_o           (edn_req),
    .edn_i           (edn_rsp),

    .keymgr_key_i    (keymgr_key),

    .tl_i            (tl_h2d),
    .tl_o            (tl_d2h),

    .alert_rx_i      (alert_rx),
    .alert_tx_o      (alert_tx)
  );

  // Unused
  logic _unused;
  assign _unused = &{alert_tx, edn_req, tl_d2h.d_error,
                      tl_d2h.d_opcode, tl_d2h.d_param,
                      tl_d2h.d_size, tl_d2h.d_source,
                      tl_d2h.d_sink, tl_d2h.d_user};

endmodule
