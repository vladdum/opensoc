// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * GEMM Accelerator (Systolic Array)
 *
 * Weight-stationary 8×8 systolic array for general matrix multiply:
 *   C[MAT_M × MAT_N] = A[MAT_M × MAT_K] × B[MAT_K × MAT_N]
 *
 * B is preloaded via WEIGHT_ADDR / WEIGHT_DATA CSRs before asserting GO.
 * A is read from SRC_ADDR via DMA (one INT8 per 32-bit word, row-major).
 * C is written to DST_ADDR via DMA (INT32 per output element, row-major).
 *
 * Computation per output row m:
 *   1. Clear PE accumulators.
 *   2. Read A[m][0..MAT_K-1] via DMA into internal buffer.
 *   3. Feed the buffer to data_skew over ARRAY_M cycles (reversed order so
 *      row k sees A[m][k] at the en pulse on cycle ARRAY_M-1).
 *      pe_cell[k][n]: acc[k][n] += A[m][k] × B[k][n] (one MAC per PE).
 *   4. Write C[m][n] = Σ_k acc[k][n] via DMA for n=0..MAT_N-1.
 *
 * Register map:
 *   0x00  CTRL        W    [0]=GO, [1]=SOFT_RESET
 *   0x04  STATUS      R    [0]=BUSY, [1]=DONE
 *   0x08  SRC_ADDR   R/W
 *   0x0C  DST_ADDR   R/W
 *   0x14  IER        R/W   [0]=IRQ enable on completion
 *   0x18  MAT_M      R/W   A rows (1–8)
 *   0x1C  MAT_K      R/W   A cols = B rows (1–8)
 *   0x20  MAT_N      R/W   B cols (1–8)
 *   0x24  WEIGHT_ADDR R/W  PE select: bits [5:3]=row-k, [2:0]=col-n
 *   0x28  WEIGHT_DATA R/W  INT8 weight value for WEIGHT_ADDR PE
 *   0x2C  ARRAY_SIZE  R    [15:8]=ARRAY_M, [7:0]=ARRAY_N (both 8)
 */
module gemm (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Control register bus (OBI slave, from axi_to_mem)
  input  logic        ctrl_req_i,
  input  logic [31:0] ctrl_addr_i,
  input  logic        ctrl_we_i,
  input  logic [3:0]  ctrl_be_i,
  input  logic [31:0] ctrl_wdata_i,
  output logic        ctrl_rvalid_o,
  output logic [31:0] ctrl_rdata_o,

  // DMA bus (OBI master, to axi_from_mem)
  output logic        dma_req_o,
  output logic [31:0] dma_addr_o,
  output logic        dma_we_o,
  output logic [31:0] dma_wdata_o,
  output logic [3:0]  dma_be_o,
  input  logic        dma_gnt_i,
  input  logic        dma_rvalid_i,
  input  logic [31:0] dma_rdata_i,
  input  logic        dma_err_i,

  // Interrupt
  output logic        irq_o
);

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------
  localparam int unsigned ARRAY_M = 8;
  localparam int unsigned ARRAY_N = 8;
  localparam int unsigned DATA_W  = 8;
  localparam int unsigned ACC_W   = 32;

  localparam logic [9:0] REG_CTRL        = 10'h000;
  localparam logic [9:0] REG_STATUS      = 10'h004;
  localparam logic [9:0] REG_SRC_ADDR   = 10'h008;
  localparam logic [9:0] REG_DST_ADDR   = 10'h00C;
  localparam logic [9:0] REG_IER        = 10'h014;
  localparam logic [9:0] REG_MAT_M      = 10'h018;
  localparam logic [9:0] REG_MAT_K      = 10'h01C;
  localparam logic [9:0] REG_MAT_N      = 10'h020;
  localparam logic [9:0] REG_WEIGHT_ADDR = 10'h024;
  localparam logic [9:0] REG_WEIGHT_DATA = 10'h028;
  localparam logic [9:0] REG_ARRAY_SIZE  = 10'h02C;

  // -------------------------------------------------------------------------
  // Configuration registers
  // -------------------------------------------------------------------------
  logic [31:0] src_addr_q, dst_addr_q;
  logic        ier_done_q;
  logic [3:0]  mat_m_q, mat_k_q, mat_n_q;
  logic [5:0]  weight_addr_q;

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------
  logic busy_q, done_q;

  // -------------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    COMPUTE_CLR,
    RD_REQ,
    RD_WAIT,
    SKEW_FEED,
    WR_REQ,
    WR_WAIT
  } state_e;
  state_e state_q, state_d;

  // -------------------------------------------------------------------------
  // Working registers
  // -------------------------------------------------------------------------
  logic [3:0] m_q;   // current output row
  logic [3:0] k_q;   // load counter (RD phase) or skew counter
  logic [3:0] n_q;   // output column counter

  // -------------------------------------------------------------------------
  // Internal A row buffer (array write: always @)
  // -------------------------------------------------------------------------
  logic signed [DATA_W-1:0] a_row_buf [ARRAY_M];

  // -------------------------------------------------------------------------
  // Systolic array / skew signals
  // -------------------------------------------------------------------------
  logic signed [ARRAY_M-1:0][DATA_W-1:0] sa_a_in;
  logic signed [ARRAY_M-1:0][ARRAY_N-1:0][ACC_W-1:0] sa_acc;
  logic signed [ARRAY_N-1:0][ACC_W-1:0]  drain_result;
  logic        sa_clr, sa_en, sa_set_w;
  logic signed [DATA_W-1:0] sa_w_data;

  logic signed [DATA_W-1:0]               skew_in;
  logic                                   skew_valid_in;
  logic signed [ARRAY_M-1:0][DATA_W-1:0]  skew_out;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ARRAY_M-1:0] skew_valid_out;
  /* verilator lint_on UNUSEDSIGNAL */

  // -------------------------------------------------------------------------
  // Decoded control signals
  // -------------------------------------------------------------------------
  logic go, soft_reset;
  assign go         = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[0] & ~busy_q;
  assign soft_reset = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
                      & ctrl_wdata_i[1];

  assign irq_o    = done_q & ier_done_q;
  assign dma_be_o = 4'b1111;

  // Weight load: fires on WEIGHT_DATA write
  assign sa_set_w  = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_WEIGHT_DATA);
  assign sa_w_data = signed'(ctrl_wdata_i[DATA_W-1:0]);

  // -------------------------------------------------------------------------
  // Skew feed data: feed a_row_buf[ARRAY_M-1-k_q] when valid, else 0
  // The reversed order ensures row k sees A[m][k] at the en pulse (cycle 7).
  // -------------------------------------------------------------------------
  logic [2:0] skew_buf_idx;
  assign skew_buf_idx = 3'(ARRAY_M - 1) - k_q[2:0];

  always_comb begin
    skew_in       = 8'sh0;
    skew_valid_in = 1'b0;
    if (state_q == SKEW_FEED) begin
      skew_valid_in = 1'b1;
      skew_in = ({1'b0, skew_buf_idx} < mat_k_q) ? a_row_buf[skew_buf_idx] : 8'sh0;
    end
  end

  // Activation inputs to systolic array come from data_skew outputs
  assign sa_a_in = skew_out;
  assign sa_clr  = (state_q == COMPUTE_CLR);
  assign sa_en   = (state_q == SKEW_FEED) & (k_q == 4'(ARRAY_M - 1));

  // -------------------------------------------------------------------------
  // Submodule instances
  // -------------------------------------------------------------------------
  data_skew #(.ARRAY_M(ARRAY_M), .DATA_W(DATA_W)) u_data_skew (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .data_i  (skew_in),
    .valid_i (skew_valid_in),
    .data_o  (skew_out),
    .valid_o (skew_valid_out)
  );

  systolic_array #(.ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N), .DATA_W(DATA_W), .ACC_W(ACC_W))
  u_systolic_array (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .clr_i    (sa_clr),
    .en_i     (sa_en),
    .set_w_i  (sa_set_w),
    .w_addr_i (weight_addr_q),
    .w_data_i (sa_w_data),
    .a_i      (sa_a_in),
    .acc_o    (sa_acc)
  );

  result_drain #(.ARRAY_M(ARRAY_M), .ARRAY_N(ARRAY_N), .ACC_W(ACC_W)) u_result_drain (
    .acc_i    (sa_acc),
    .result_o (drain_result)
  );

  // -------------------------------------------------------------------------
  // Control register read path
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_rvalid_o <= 1'b0;
      ctrl_rdata_o  <= 32'd0;
    end else begin
      ctrl_rvalid_o <= ctrl_req_i;
      ctrl_rdata_o  <= 32'd0;
      if (ctrl_req_i && !ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_CTRL:        ctrl_rdata_o <= 32'd0;
          REG_STATUS:      ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_SRC_ADDR:    ctrl_rdata_o <= src_addr_q;
          REG_DST_ADDR:    ctrl_rdata_o <= dst_addr_q;
          REG_IER:         ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_MAT_M:       ctrl_rdata_o <= {28'd0, mat_m_q};
          REG_MAT_K:       ctrl_rdata_o <= {28'd0, mat_k_q};
          REG_MAT_N:       ctrl_rdata_o <= {28'd0, mat_n_q};
          REG_WEIGHT_ADDR: ctrl_rdata_o <= {26'd0, weight_addr_q};
          REG_ARRAY_SIZE:  ctrl_rdata_o <= {16'd0, 8'(ARRAY_M), 8'(ARRAY_N)};
          default:         ctrl_rdata_o <= 32'd0;
        endcase
      end
    end
  end

  // -------------------------------------------------------------------------
  // Control register write path
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_q    <= 32'd0;
      dst_addr_q    <= 32'd0;
      ier_done_q    <= 1'b0;
      mat_m_q       <= 4'd8;
      mat_k_q       <= 4'd8;
      mat_n_q       <= 4'd8;
      weight_addr_q <= 6'd0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_SRC_ADDR:    src_addr_q    <= ctrl_wdata_i;
        REG_DST_ADDR:    dst_addr_q    <= ctrl_wdata_i;
        REG_IER:         ier_done_q    <= ctrl_wdata_i[0];
        REG_MAT_M:       mat_m_q       <= ctrl_wdata_i[3:0];
        REG_MAT_K:       mat_k_q       <= ctrl_wdata_i[3:0];
        REG_MAT_N:       mat_n_q       <= ctrl_wdata_i[3:0];
        REG_WEIGHT_ADDR: weight_addr_q <= ctrl_wdata_i[5:0];
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // A row buffer writes
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < ARRAY_M; i++) a_row_buf[i] <= '0;
    end else if (state_q == RD_WAIT && dma_rvalid_i) begin
      a_row_buf[k_q[2:0]] <= signed'(dma_rdata_i[DATA_W-1:0]);
    end
  end

  // -------------------------------------------------------------------------
  // FSM — combinational next-state and DMA outputs
  // -------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (state_q)
      IDLE: begin
        if (go) state_d = COMPUTE_CLR;
      end

      COMPUTE_CLR: begin
        // sa_clr asserted combinationally; proceed to load A row
        state_d = RD_REQ;
      end

      RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = src_addr_q + (32'(m_q) * 32'(mat_k_q) + 32'(k_q)) * 32'd4;
        if (dma_gnt_i) state_d = RD_WAIT;
      end

      RD_WAIT: begin
        if (dma_rvalid_i) begin
          if (k_q == mat_k_q - 4'd1) begin
            state_d = SKEW_FEED;
          end else begin
            state_d = RD_REQ;
          end
        end
      end

      SKEW_FEED: begin
        // k_q counts 0..ARRAY_M-1; sa_en fires at k_q==ARRAY_M-1 (combinational)
        if (k_q == 4'(ARRAY_M - 1)) begin
          state_d = WR_REQ;
        end
      end

      WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = dst_addr_q + (32'(m_q) * 32'(mat_n_q) + 32'(n_q)) * 32'd4;
        dma_we_o    = 1'b1;
        dma_wdata_o = 32'(signed'(drain_result[n_q[2:0]]));
        if (dma_gnt_i) state_d = WR_WAIT;
      end

      WR_WAIT: begin
        if (dma_rvalid_i) begin
          if (n_q == mat_n_q - 4'd1) begin
            if (m_q == mat_m_q - 4'd1) begin
              state_d = IDLE;
            end else begin
              state_d = COMPUTE_CLR;
            end
          end else begin
            state_d = WR_REQ;
          end
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // FSM — sequential updates
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= IDLE;
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
      m_q     <= 4'd0;
      k_q     <= 4'd0;
      n_q     <= 4'd0;
    end else begin
      state_q <= state_d;

      if (soft_reset) begin
        busy_q  <= 1'b0;
        done_q  <= 1'b0;
        m_q     <= 4'd0;
        k_q     <= 4'd0;
        n_q     <= 4'd0;
      end else begin
        case (state_q)
          IDLE: begin
            if (go) begin
              busy_q <= 1'b1;
              done_q <= 1'b0;
              m_q    <= 4'd0;
              k_q    <= 4'd0;
              n_q    <= 4'd0;
            end
          end

          COMPUTE_CLR: begin
            k_q <= 4'd0;
            n_q <= 4'd0;
          end

          RD_WAIT: begin
            if (dma_rvalid_i) begin
              if (k_q == mat_k_q - 4'd1) begin
                k_q <= 4'd0;
              end else begin
                k_q <= k_q + 4'd1;
              end
            end
          end

          SKEW_FEED: begin
            if (k_q == 4'(ARRAY_M - 1)) begin
              k_q <= 4'd0;
            end else begin
              k_q <= k_q + 4'd1;
            end
          end

          WR_WAIT: begin
            if (dma_rvalid_i) begin
              if (n_q == mat_n_q - 4'd1) begin
                n_q <= 4'd0;
                if (m_q == mat_m_q - 4'd1) begin
                  busy_q <= 1'b0;
                  done_q <= 1'b1;
                end else begin
                  m_q <= m_q + 4'd1;
                end
              end else begin
                n_q <= n_q + 4'd1;
              end
            end
          end

          default: ;
        endcase
      end
    end
  end

endmodule
