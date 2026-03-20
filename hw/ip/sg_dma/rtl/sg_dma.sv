// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Scatter-Gather DMA Engine
 *
 * Fetches linked descriptor structs from DRAM and executes chained
 * memory-to-memory word copy operations. Each descriptor is 5 words (20 bytes):
 *
 *   Offset 0x00: src_addr        - Source start address
 *   Offset 0x04: dst_addr        - Destination start address
 *   Offset 0x08: word_len        - Number of 32-bit words to transfer
 *   Offset 0x0C: ctrl            - [0] IRQ_ON_DONE, [1] CHAIN
 *   Offset 0x10: next_desc_addr  - Address of next descriptor (if CHAIN=1)
 *
 * Control registers (offset from base):
 *   0x00  DESC_ADDR      - First descriptor address in DRAM (R/W)
 *   0x04  CTRL           - [0] GO (W, auto-clears)
 *   0x08  STATUS         - [0] BUSY, [1] DONE (R)
 *   0x0C  IER            - [0] Done interrupt enable (R/W)
 *   0x10  COMPLETED_CNT  - Number of completed descriptors (R, cleared on GO)
 *   0x14  ACTIVE_SRC     - Debug: current source address (R)
 *   0x18  ACTIVE_DST     - Debug: current destination address (R)
 *   0x1C  ACTIVE_LEN     - Debug: remaining word count (R)
 *
 * GO while BUSY is silently ignored.
 * All addresses must be word-aligned.
 */
module sg_dma (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Control register bus (from axi_to_mem)
  input  logic        ctrl_req_i,
  input  logic [31:0] ctrl_addr_i,
  input  logic        ctrl_we_i,
  input  logic [3:0]  ctrl_be_i,
  input  logic [31:0] ctrl_wdata_i,
  output logic        ctrl_rvalid_o,
  output logic [31:0] ctrl_rdata_o,

  // DMA bus (to axi_from_mem)
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

  // ---------------------------------------------------------------------------
  // Register offsets (10-bit, matching 1 kB address window)
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_DESC_ADDR     = 10'h000;
  localparam logic [9:0] REG_CTRL          = 10'h004;
  localparam logic [9:0] REG_STATUS        = 10'h008;
  localparam logic [9:0] REG_IER           = 10'h00C;
  localparam logic [9:0] REG_COMPLETED_CNT = 10'h010;
  localparam logic [9:0] REG_ACTIVE_SRC    = 10'h014;
  localparam logic [9:0] REG_ACTIVE_DST    = 10'h018;
  localparam logic [9:0] REG_ACTIVE_LEN    = 10'h01C;

  // Number of words in a descriptor struct
  localparam int unsigned DESC_WORDS = 5;

  // ---------------------------------------------------------------------------
  // Configuration registers
  // ---------------------------------------------------------------------------
  logic [31:0] desc_addr_q;
  logic        ier_done_q;

  // ---------------------------------------------------------------------------
  // Status flags
  // ---------------------------------------------------------------------------
  logic busy_q, done_q;

  // ---------------------------------------------------------------------------
  // DMA working state
  // ---------------------------------------------------------------------------
  // Descriptor fetch
  logic [31:0] cur_desc_addr_q;       // Address of current descriptor
  logic [2:0]  fetch_idx_q;           // Which descriptor field we're fetching (0-4)
  logic [31:0] desc_fields_q [DESC_WORDS]; // Latched descriptor fields

  // Copy engine
  logic [31:0] cur_src_q, cur_dst_q;
  logic [31:0] remaining_q;           // Remaining words to copy
  logic [31:0] copy_data_q;           // Latched read data for write-back

  // Descriptor ctrl bits (from desc_fields_q[3])
  logic        desc_irq_on_done_q;
  logic        desc_chain_q;
  logic [31:0] desc_next_addr_q;

  // Completion counter
  logic [31:0] completed_cnt_q;

  // ---------------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE,
    FETCH_REQ,
    FETCH_WAIT,
    COPY_RD_REQ,
    COPY_RD_WAIT,
    COPY_WR_REQ,
    COPY_WR_WAIT
  } state_e;

  state_e state_q, state_d;

  // GO pulse: valid only when not busy
  logic go;
  assign go = ctrl_req_i & ctrl_we_i & (ctrl_addr_i[9:0] == REG_CTRL)
              & ctrl_wdata_i[0] & ~busy_q;

  // Interrupt output: level-sensitive
  assign irq_o = done_q & ier_done_q;

  // DMA byte enables: always full-word
  assign dma_be_o = 4'b1111;

  // ---------------------------------------------------------------------------
  // Control register read path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_rvalid_o <= 1'b0;
      ctrl_rdata_o  <= 32'd0;
    end else begin
      ctrl_rvalid_o <= ctrl_req_i;
      ctrl_rdata_o  <= 32'd0;
      if (ctrl_req_i && !ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_DESC_ADDR:     ctrl_rdata_o <= desc_addr_q;
          REG_CTRL:          ctrl_rdata_o <= 32'd0;
          REG_STATUS:        ctrl_rdata_o <= {30'd0, done_q, busy_q};
          REG_IER:           ctrl_rdata_o <= {31'd0, ier_done_q};
          REG_COMPLETED_CNT: ctrl_rdata_o <= completed_cnt_q;
          REG_ACTIVE_SRC:    ctrl_rdata_o <= cur_src_q;
          REG_ACTIVE_DST:    ctrl_rdata_o <= cur_dst_q;
          REG_ACTIVE_LEN:    ctrl_rdata_o <= remaining_q;
          default:           ctrl_rdata_o <= 32'd0;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Control register write path
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      desc_addr_q <= 32'd0;
      ier_done_q  <= 1'b0;
    end else if (ctrl_req_i && ctrl_we_i) begin
      case (ctrl_addr_i[9:0])
        REG_DESC_ADDR: desc_addr_q <= ctrl_wdata_i;
        REG_IER:       ier_done_q  <= ctrl_wdata_i[0];
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — next-state and output logic
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d     = state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (state_q)
      IDLE: begin
        if (go) begin
          state_d = FETCH_REQ;
        end
      end

      FETCH_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_desc_addr_q + {27'd0, fetch_idx_q, 2'b00};
        if (dma_gnt_i) state_d = FETCH_WAIT;
      end

      FETCH_WAIT: begin
        if (dma_rvalid_i) begin
          if (fetch_idx_q == 3'(DESC_WORDS - 1)) begin
            // All descriptor fields fetched — start copy or handle zero-length
            // (Next state determined in sequential block based on word_len)
            state_d = COPY_RD_REQ;
          end else begin
            state_d = FETCH_REQ;
          end
        end
      end

      COPY_RD_REQ: begin
        dma_req_o  = 1'b1;
        dma_addr_o = cur_src_q;
        if (dma_gnt_i) state_d = COPY_RD_WAIT;
      end

      COPY_RD_WAIT: begin
        if (dma_rvalid_i) state_d = COPY_WR_REQ;
      end

      COPY_WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = cur_dst_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = copy_data_q;
        if (dma_gnt_i) state_d = COPY_WR_WAIT;
      end

      COPY_WR_WAIT: begin
        if (dma_rvalid_i) begin
          if (remaining_q == 32'd1) begin
            // Descriptor complete — check chain
            if (desc_chain_q) begin
              state_d = FETCH_REQ;
            end else begin
              state_d = IDLE;
            end
          end else begin
            state_d = COPY_RD_REQ;
          end
        end
      end

      default: state_d = IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // DMA FSM — sequential state and working registers
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= IDLE;
      busy_q             <= 1'b0;
      done_q             <= 1'b0;
      cur_desc_addr_q    <= 32'd0;
      fetch_idx_q        <= 3'd0;
      cur_src_q          <= 32'd0;
      cur_dst_q          <= 32'd0;
      remaining_q        <= 32'd0;
      copy_data_q        <= 32'd0;
      desc_irq_on_done_q <= 1'b0;
      desc_chain_q       <= 1'b0;
      desc_next_addr_q   <= 32'd0;
      completed_cnt_q    <= 32'd0;
      for (int i = 0; i < DESC_WORDS; i++) begin
        desc_fields_q[i] <= 32'd0;
      end
    end else begin
      state_q <= state_d;

      case (state_q)
        IDLE: begin
          if (go) begin
            done_q          <= 1'b0;
            busy_q          <= 1'b1;
            cur_desc_addr_q <= desc_addr_q;
            fetch_idx_q     <= 3'd0;
            completed_cnt_q <= 32'd0;
          end
        end

        FETCH_WAIT: begin
          if (dma_rvalid_i) begin
            desc_fields_q[fetch_idx_q] <= dma_rdata_i;
            if (fetch_idx_q == 3'(DESC_WORDS - 1)) begin
              // Unpack descriptor fields into working registers
              // fields[0]=src, fields[1]=dst, fields[2]=word_len,
              // fields[3]=ctrl, fields[4]=next_desc_addr
              // Note: fields[0..3] were stored in prior FETCH_WAIT beats;
              // fields[4] arrives this cycle in dma_rdata_i.
              cur_src_q          <= desc_fields_q[0];
              cur_dst_q          <= desc_fields_q[1];
              remaining_q        <= desc_fields_q[2];
              desc_irq_on_done_q <= desc_fields_q[3][0];
              desc_chain_q       <= desc_fields_q[3][1];
              desc_next_addr_q   <= dma_rdata_i; // field[4] arrives now
              fetch_idx_q        <= 3'd0;

              // Handle zero-length: skip copy, go straight to chain check
              if (desc_fields_q[2] == 32'd0) begin
                completed_cnt_q <= completed_cnt_q + 32'd1;
                if (desc_fields_q[3][1]) begin
                  // Chain: load next descriptor
                  cur_desc_addr_q <= dma_rdata_i;
                  // state_d already set to COPY_RD_REQ in comb, override:
                  state_q <= FETCH_REQ;
                end else begin
                  // Done
                  busy_q  <= 1'b0;
                  done_q  <= 1'b1;
                  state_q <= IDLE;
                end
              end
            end else begin
              fetch_idx_q <= fetch_idx_q + 3'd1;
            end
          end
        end

        COPY_RD_WAIT: begin
          if (dma_rvalid_i) begin
            copy_data_q <= dma_rdata_i;
          end
        end

        COPY_WR_WAIT: begin
          if (dma_rvalid_i) begin
            cur_src_q   <= cur_src_q + 32'd4;
            cur_dst_q   <= cur_dst_q + 32'd4;
            remaining_q <= remaining_q - 32'd1;

            if (remaining_q == 32'd1) begin
              // Descriptor copy complete
              completed_cnt_q <= completed_cnt_q + 32'd1;

              if (desc_chain_q) begin
                // Chain to next descriptor
                cur_desc_addr_q <= desc_next_addr_q;
                fetch_idx_q     <= 3'd0;
              end else begin
                // All done
                busy_q <= 1'b0;
                done_q <= 1'b1;
              end
            end
          end
        end

        default: ;
      endcase
    end
  end

endmodule
