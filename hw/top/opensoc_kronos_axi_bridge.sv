// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Stopgap bridge between Kronos's native AXI4 master ports (64-bit address,
// 64-bit data) and the OpenSoC crossbar (32-bit address, 32-bit data).
//
// Stage 1 — address narrow: kronos addr[63:32] is asserted to be all-zero in
// the OpenSoC address map (peripherals live at 0x2000_0000–0x400B_FFFF) and
// is dropped via field-level assignment.
// Stage 2 — WRAP → INCR: kronos icache/dcache refills use BURST_WRAP, but
// PULP `axi_dw_downsizer` does not support WRAP and would return SLVERR.
// `axi_burst_unwrap` splits WRAP bursts into equivalent INCR sequences at
// the same data width before the downsize.
// Stage 3 — data downsize: PULP `axi_dw_converter` splits each 64-bit AXI
// beat into two 32-bit beats.
//
// Removed once OpenSoC's AXI infrastructure migrates to 64-bit natively.

`include "axi/typedef.svh"

module opensoc_kronos_axi_bridge
  import opensoc_derived_config_pkg::*;
  import kronos_pkg::*;
(
  input  logic              clk_i,
  input  logic              rst_ni,

  // Kronos side: 64-bit addr / 64-bit data
  input  kronos_axi_req_t   kronos_req_i,
  output kronos_axi_resp_t  kronos_resp_o,

  // Crossbar side: 32-bit addr / 32-bit data (axi_in_*)
  output axi_in_req_t       xbar_req_o,
  input  axi_in_resp_t      xbar_resp_i
);

  // ─── Intermediate types: 32-bit addr (matches xbar) + 64-bit data (kronos)
  //     Reuse xbar's narrow aw/ar/b channel typedefs; only w/r differ in data.
  typedef logic [63:0] mid_data_t;
  typedef logic [ 7:0] mid_strb_t;

  `AXI_TYPEDEF_W_CHAN_T(mid_w_chan_t,  mid_data_t, mid_strb_t, axi_user_t)
  `AXI_TYPEDEF_R_CHAN_T(mid_r_chan_t,  mid_data_t, axi_id_in_t, axi_user_t)
  `AXI_TYPEDEF_REQ_T   (mid_req_t,  axi_in_aw_chan_t, mid_w_chan_t, axi_in_ar_chan_t)
  `AXI_TYPEDEF_RESP_T  (mid_resp_t, axi_in_b_chan_t,  mid_r_chan_t)

  mid_req_t  mid_req;
  mid_resp_t mid_resp;

  // ─── Stage 1 — request: address narrow (kronos 64-bit → mid 32-bit). ─────
  always_comb begin
    mid_req           = '0;

    mid_req.aw.id     = kronos_req_i.aw.id;
    mid_req.aw.addr   = kronos_req_i.aw.addr[31:0];
    mid_req.aw.len    = kronos_req_i.aw.len;
    mid_req.aw.size   = kronos_req_i.aw.size;
    mid_req.aw.burst  = kronos_req_i.aw.burst;
    mid_req.aw.lock   = kronos_req_i.aw.lock;
    // Force CACHE_MODIFIABLE: kronos drives cache=0, but axi_burst_unwrap
    // rejects multi-beat WRAP bursts unless cache[1] is set. Safe because no
    // OpenSoC slave behaves differently on cache attribute.
    mid_req.aw.cache  = axi_pkg::CACHE_MODIFIABLE;
    mid_req.aw.prot   = kronos_req_i.aw.prot;
    mid_req.aw.qos    = kronos_req_i.aw.qos;
    mid_req.aw.region = kronos_req_i.aw.region;
    mid_req.aw.atop   = kronos_req_i.aw.atop;
    mid_req.aw.user   = kronos_req_i.aw.user;
    mid_req.aw_valid  = kronos_req_i.aw_valid;

    mid_req.w.data    = kronos_req_i.w.data;
    mid_req.w.strb    = kronos_req_i.w.strb;
    mid_req.w.last    = kronos_req_i.w.last;
    mid_req.w.user    = kronos_req_i.w.user;
    mid_req.w_valid   = kronos_req_i.w_valid;

    mid_req.b_ready   = kronos_req_i.b_ready;

    mid_req.ar.id     = kronos_req_i.ar.id;
    mid_req.ar.addr   = kronos_req_i.ar.addr[31:0];
    mid_req.ar.len    = kronos_req_i.ar.len;
    mid_req.ar.size   = kronos_req_i.ar.size;
    mid_req.ar.burst  = kronos_req_i.ar.burst;
    mid_req.ar.lock   = kronos_req_i.ar.lock;
    mid_req.ar.cache  = axi_pkg::CACHE_MODIFIABLE;  // see note above
    mid_req.ar.prot   = kronos_req_i.ar.prot;
    mid_req.ar.qos    = kronos_req_i.ar.qos;
    mid_req.ar.region = kronos_req_i.ar.region;
    mid_req.ar.user   = kronos_req_i.ar.user;
    mid_req.ar_valid  = kronos_req_i.ar_valid;

    mid_req.r_ready   = kronos_req_i.r_ready;
  end

  // ─── Stage 1 — response: handshakes / b / r passthrough back to kronos.
  always_comb begin
    kronos_resp_o          = '0;

    kronos_resp_o.aw_ready = mid_resp.aw_ready;
    kronos_resp_o.ar_ready = mid_resp.ar_ready;
    kronos_resp_o.w_ready  = mid_resp.w_ready;

    kronos_resp_o.b.id     = mid_resp.b.id;
    kronos_resp_o.b.resp   = mid_resp.b.resp;
    kronos_resp_o.b.user   = mid_resp.b.user;
    kronos_resp_o.b_valid  = mid_resp.b_valid;

    kronos_resp_o.r.id     = mid_resp.r.id;
    kronos_resp_o.r.data   = mid_resp.r.data;
    kronos_resp_o.r.resp   = mid_resp.r.resp;
    kronos_resp_o.r.last   = mid_resp.r.last;
    kronos_resp_o.r.user   = mid_resp.r.user;
    kronos_resp_o.r_valid  = mid_resp.r_valid;
  end

  // ─── Stage 2 — WRAP → INCR (same data width). ───────────────────────────
  mid_req_t  unwrap_req;
  mid_resp_t unwrap_resp;

  axi_burst_unwrap #(
    .MaxReadTxns  ( 32'd4         ),
    .MaxWriteTxns ( 32'd4         ),
    .AddrWidth    ( AxiAddrWidth  ),
    .DataWidth    ( 32'd64        ),
    .IdWidth      ( AxiIdWidthIn  ),
    .UserWidth    ( AxiUserWidth  ),
    .axi_req_t    ( mid_req_t     ),
    .axi_resp_t   ( mid_resp_t    )
  ) i_burst_unwrap (
    .clk_i,
    .rst_ni,
    .slv_req_i  ( mid_req     ),
    .slv_resp_o ( mid_resp    ),
    .mst_req_o  ( unwrap_req  ),
    .mst_resp_i ( unwrap_resp )
  );

  // ─── Stage 3 — data downsize 64 → 32 (unwrap → xbar). ────────────────────
  axi_dw_converter #(
    .AxiMaxReads          ( 4                ),
    .AxiSlvPortDataWidth  ( 64               ),
    .AxiMstPortDataWidth  ( AxiDataWidth     ),
    .AxiAddrWidth         ( AxiAddrWidth     ),
    .AxiIdWidth           ( AxiIdWidthIn     ),
    .aw_chan_t            ( axi_in_aw_chan_t ),
    .mst_w_chan_t         ( axi_in_w_chan_t  ),
    .slv_w_chan_t         ( mid_w_chan_t     ),
    .b_chan_t             ( axi_in_b_chan_t  ),
    .ar_chan_t            ( axi_in_ar_chan_t ),
    .mst_r_chan_t         ( axi_in_r_chan_t  ),
    .slv_r_chan_t         ( mid_r_chan_t     ),
    .axi_mst_req_t        ( axi_in_req_t     ),
    .axi_mst_resp_t       ( axi_in_resp_t    ),
    .axi_slv_req_t        ( mid_req_t        ),
    .axi_slv_resp_t       ( mid_resp_t       )
  ) i_dw_downsize (
    .clk_i,
    .rst_ni,
    .slv_req_i  ( unwrap_req  ),
    .slv_resp_o ( unwrap_resp ),
    .mst_req_o  ( xbar_req_o  ),
    .mst_resp_i ( xbar_resp_i )
  );

endmodule
