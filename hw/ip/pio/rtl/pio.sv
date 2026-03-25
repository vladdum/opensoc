// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Programmable I/O (PIO) Block
 *
 * 4 state machines sharing 32-instruction memory. Replaces GPIO at 0x50000.
 * Provides GPIO-compatible DIR/OUT/IN registers and a DMA master port.
 *
 * Register map (see docs/pio/pio.md for full details):
 *   0x000  CTRL            0x004  FSTAT           0x030  IRQ
 *   0x034  IRQ_FORCE       0x03C  DBG_PADOUT      0x040  DBG_PADOE
 *   0x044  DBG_CFGINFO     0x048-0x0C4  INSTR_MEM[0..31]
 *   0x0C8+N*0x20  SMn registers (CLKDIV, EXECCTRL, SHIFTCTRL, ADDR, INSTR, PINCTRL)
 *   0x148  GPIO_DIR        0x14C  GPIO_OUT        0x150  GPIO_IN
 *   0x154  DMA_CTRL        0x158  DMA_ADDR
 */
module pio (
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
  output logic        irq_o,

  // GPIO pins
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe
);

  // ===========================================================================
  // Parameters
  // ===========================================================================
  localparam int unsigned NumSm     = 4;
  localparam int unsigned ImemSize  = 32;
  localparam int unsigned FifoDepth = 4;

  // ===========================================================================
  // Register offsets
  // ===========================================================================
  localparam logic [9:0] REG_CTRL        = 10'h000;
  localparam logic [9:0] REG_FSTAT       = 10'h004;
  // 0x008 FDEBUG, 0x00C FLEVEL — reserved
  localparam logic [9:0] REG_TXF0        = 10'h010;
  // TXF1=0x014, TXF2=0x018, TXF3=0x01C
  localparam logic [9:0] REG_RXF0        = 10'h020;
  // RXF1=0x024, RXF2=0x028, RXF3=0x02C
  localparam logic [9:0] REG_IRQ         = 10'h030;
  localparam logic [9:0] REG_IRQ_FORCE   = 10'h034;
  localparam logic [9:0] REG_DBG_PADOUT  = 10'h03C;
  localparam logic [9:0] REG_DBG_PADOE   = 10'h040;
  localparam logic [9:0] REG_DBG_CFGINFO = 10'h044;
  localparam logic [9:0] REG_INSTR_MEM0  = 10'h048;
  // INSTR_MEM31 = 0x048 + 31*4 = 0x0C4
  localparam logic [9:0] REG_SM0_BASE    = 10'h0C8;
  // SM stride = 0x20. SM0=0x0C8, SM1=0x0E8, SM2=0x108, SM3=0x128
  localparam logic [9:0] REG_GPIO_DIR    = 10'h148;
  localparam logic [9:0] REG_GPIO_OUT    = 10'h14C;
  localparam logic [9:0] REG_GPIO_IN     = 10'h150;
  localparam logic [9:0] REG_DMA_CTRL    = 10'h154;
  localparam logic [9:0] REG_DMA_ADDR    = 10'h158;

  // Per-SM register sub-offsets within the 0x20 stride
  localparam logic [4:0] SM_CLKDIV    = 5'h00;
  localparam logic [4:0] SM_EXECCTRL  = 5'h04;
  localparam logic [4:0] SM_SHIFTCTRL = 5'h08;
  localparam logic [4:0] SM_ADDR      = 5'h0C;
  localparam logic [4:0] SM_INSTR     = 5'h10;
  localparam logic [4:0] SM_PINCTRL   = 5'h14;

  // ===========================================================================
  // DMA FSM type
  // ===========================================================================
  typedef enum logic [2:0] {
    DMA_IDLE,
    DMA_TX_RD_REQ,
    DMA_TX_RD_WAIT,
    DMA_RX_FIFO_WAIT,
    DMA_RX_WR_REQ,
    DMA_RX_WR_WAIT
  } dma_state_e;

  // ===========================================================================
  // All internal signal declarations
  // ===========================================================================

  // Instruction memory (32 x 16-bit, write-only, NO reset)
  logic [15:0] instr_mem [ImemSize];

  // Input synchronizer (2-FF)
  logic [31:0] gpio_sync_q1, gpio_sync_q2;

  // Global control register
  logic [3:0] sm_en_q;        // CTRL[3:0] SM enable
  logic [3:0] sm_restart;     // CTRL[7:4] W1S pulses
  logic [3:0] clkdiv_restart; // CTRL[11:8] W1S pulses

  // Per-SM configuration registers
  logic [31:0] sm_clkdiv_q    [NumSm];
  logic [31:0] sm_execctrl_q  [NumSm];
  logic [31:0] sm_shiftctrl_q [NumSm];
  logic [31:0] sm_pinctrl_q   [NumSm];

  // Per-SM forced instruction
  logic [15:0] sm_force_instr [NumSm];
  logic [3:0]  sm_force_exec;

  // IRQ flags
  logic [7:0] irq_flags_q;

  // Per-SM IRQ outputs (combined)
  logic [7:0] sm_irq_set [NumSm];
  logic [7:0] sm_irq_clr [NumSm];

  // TX FIFOs (CPU writes, SM reads)
  logic [31:0] tx_fifo_mem [NumSm][FifoDepth];
  logic [2:0]  tx_wr_ptr_q [NumSm]; // extra bit for full/empty
  logic [2:0]  tx_rd_ptr_q [NumSm];

  // RX FIFOs (SM writes, CPU reads)
  logic [31:0] rx_fifo_mem [NumSm][FifoDepth];
  logic [2:0]  rx_wr_ptr_q [NumSm];
  logic [2:0]  rx_rd_ptr_q [NumSm];

  // FIFO status signals
  logic [3:0] tx_full, tx_empty, rx_full, rx_empty;

  // SM FIFO interface
  logic [3:0]  sm_tx_pull;
  logic [31:0] sm_tx_data  [NumSm];
  logic [3:0]  sm_tx_empty;
  logic [3:0]  sm_rx_push;
  logic [31:0] sm_rx_data  [NumSm];
  logic [3:0]  sm_rx_full;

  // SM outputs
  logic [4:0]  sm_pc       [NumSm];
  logic [31:0] sm_pins_o   [NumSm];
  logic [31:0] sm_pins_oe  [NumSm];
  logic [3:0]  sm_stalled;

  // GPIO compatibility registers
  logic [31:0] gpio_dir_q;
  logic [31:0] gpio_out_q;

  // DMA registers
  logic [31:0] dma_ctrl_q;
  logic [31:0] dma_addr_q;
  logic        dma_busy_q, dma_done_q;
  logic [15:0] dma_remaining_q;
  logic [31:0] dma_cur_addr_q;
  logic [31:0] dma_data_q;  // latched data for TX→FIFO or FIFO→mem
  dma_state_e  dma_state_q, dma_state_d;

  // DMA_CTRL derived fields
  logic        dma_go;
  logic        dma_dir;     // 0=TX(mem→FIFO), 1=RX(FIFO→mem)
  logic [1:0]  dma_sm_sel;
  logic [15:0] dma_len;
  logic        dma_done_ie;

  // DMA FIFO interaction signals
  logic dma_tx_push;
  logic dma_rx_pop;

  // Pin output mux (combinational)
  logic [31:0] mux_out, mux_oe;

  // CPU-side FIFO write/read request signals (computed in register block, consumed in FIFO block)
  logic        cpu_tx_push;
  logic [1:0]  cpu_tx_sm;
  logic [31:0] cpu_tx_wdata;
  logic        cpu_rx_pop;
  logic [1:0]  cpu_rx_sm;

  // DMA FSM → register block: latch dma_ctrl_q fields on GO
  logic        dma_latch_ctrl;

  // Genvar for generate blocks
  genvar gi;

  // ===========================================================================
  // Continuous assigns
  // ===========================================================================

  // DMA_CTRL field extraction
  assign dma_dir     = dma_ctrl_q[3];
  assign dma_sm_sel  = dma_ctrl_q[5:4];
  assign dma_len     = dma_ctrl_q[21:6];
  assign dma_done_ie = dma_ctrl_q[31];

  // DMA byte enable (always full word)
  assign dma_be_o = 4'b1111;

  // DMA GO detection
  assign dma_go = ctrl_req_i && ctrl_we_i && (ctrl_addr_i[9:0] == REG_DMA_CTRL)
                  && ctrl_wdata_i[0] && !dma_busy_q;

  // DMA TX FIFO write (push DMA read data into TX FIFO)
  assign dma_tx_push = (dma_state_q == DMA_TX_RD_WAIT) && dma_rvalid_i && !dma_dir;

  // DMA RX FIFO read (pop from RX FIFO for DMA write)
  assign dma_rx_pop = (dma_state_q == DMA_RX_FIFO_WAIT) && !rx_empty[dma_sm_sel] && dma_dir;

  // IRQ output
  assign irq_o = |irq_flags_q | (dma_done_q & dma_done_ie);

  // ===========================================================================
  // FIFO status — generate
  // ===========================================================================
  generate
    for (gi = 0; gi < NumSm; gi++) begin : gen_fifo_status
      assign tx_full[gi]  = (tx_wr_ptr_q[gi][1:0] == tx_rd_ptr_q[gi][1:0]) &&
                             (tx_wr_ptr_q[gi][2]   != tx_rd_ptr_q[gi][2]);
      assign tx_empty[gi] = (tx_wr_ptr_q[gi] == tx_rd_ptr_q[gi]);
      assign rx_full[gi]  = (rx_wr_ptr_q[gi][1:0] == rx_rd_ptr_q[gi][1:0]) &&
                             (rx_wr_ptr_q[gi][2]   != rx_rd_ptr_q[gi][2]);
      assign rx_empty[gi] = (rx_wr_ptr_q[gi] == rx_rd_ptr_q[gi]);

      assign sm_tx_empty[gi] = tx_empty[gi];
      assign sm_tx_data[gi]  = tx_fifo_mem[gi][tx_rd_ptr_q[gi][1:0]];
      assign sm_rx_full[gi]  = rx_full[gi];
    end
  endgenerate

  // ===========================================================================
  // Instruction memory write path — use always @(posedge) to avoid BLKLOOPINIT
  // ===========================================================================
  always @(posedge clk_i) begin
    if (ctrl_req_i && ctrl_we_i) begin
      // Instruction memory: 0x048 to 0x0C4 (offsets 0x048 + i*4)
      if (ctrl_addr_i[9:0] >= REG_INSTR_MEM0 &&
          ctrl_addr_i[9:0] < (REG_INSTR_MEM0 + 10'(ImemSize * 4))) begin
        automatic logic [9:0] imem_off = ctrl_addr_i[9:0] - REG_INSTR_MEM0;
        automatic logic [4:0] imem_idx = imem_off[6:2]; // word index 0-31
        instr_mem[imem_idx] <= ctrl_wdata_i[15:0];
      end
    end
  end

  // ===========================================================================
  // Input synchronizer (2-FF) — sequential
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gpio_sync_q1 <= 32'd0;
      gpio_sync_q2 <= 32'd0;
    end else begin
      gpio_sync_q1 <= gpio_i;
      gpio_sync_q2 <= gpio_sync_q1;
    end
  end

  // ===========================================================================
  // FIFO read/write — sequential
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < NumSm; i++) begin
        tx_wr_ptr_q[i] <= 3'd0;
        tx_rd_ptr_q[i] <= 3'd0;
        rx_wr_ptr_q[i] <= 3'd0;
        rx_rd_ptr_q[i] <= 3'd0;
      end
    end else begin
      // SM-side: TX read (pull) and RX write (push)
      for (int i = 0; i < NumSm; i++) begin
        if (sm_tx_pull[i] && !tx_empty[i]) begin
          tx_rd_ptr_q[i] <= tx_rd_ptr_q[i] + 3'd1;
        end
        if (sm_rx_push[i] && !rx_full[i]) begin
          rx_fifo_mem[i][rx_wr_ptr_q[i][1:0]] <= sm_rx_data[i];
          rx_wr_ptr_q[i] <= rx_wr_ptr_q[i] + 3'd1;
        end
      end

      // CPU-side TX FIFO write
      if (cpu_tx_push && !tx_full[cpu_tx_sm]) begin
        tx_fifo_mem[cpu_tx_sm][tx_wr_ptr_q[cpu_tx_sm][1:0]] <= cpu_tx_wdata;
        tx_wr_ptr_q[cpu_tx_sm] <= tx_wr_ptr_q[cpu_tx_sm] + 3'd1;
      end

      // CPU-side RX FIFO read
      if (cpu_rx_pop && !rx_empty[cpu_rx_sm]) begin
        rx_rd_ptr_q[cpu_rx_sm] <= rx_rd_ptr_q[cpu_rx_sm] + 3'd1;
      end

      // DMA TX push: write DMA read data into TX FIFO
      if (dma_tx_push && !tx_full[dma_sm_sel]) begin
        tx_fifo_mem[dma_sm_sel][tx_wr_ptr_q[dma_sm_sel][1:0]] <= dma_rdata_i;
        tx_wr_ptr_q[dma_sm_sel] <= tx_wr_ptr_q[dma_sm_sel] + 3'd1;
      end

      // DMA RX pop: read from RX FIFO for DMA write
      if (dma_rx_pop && !rx_empty[dma_sm_sel]) begin
        rx_rd_ptr_q[dma_sm_sel] <= rx_rd_ptr_q[dma_sm_sel] + 3'd1;
      end
    end
  end

  // ===========================================================================
  // DMA next-state logic — combinational
  // ===========================================================================
  always_comb begin
    dma_state_d = dma_state_q;
    dma_req_o   = 1'b0;
    dma_addr_o  = 32'd0;
    dma_we_o    = 1'b0;
    dma_wdata_o = 32'd0;

    case (dma_state_q)
      DMA_IDLE: begin
        if (dma_go) begin
          if (!ctrl_wdata_i[3]) // TX: mem→FIFO
            dma_state_d = DMA_TX_RD_REQ;
          else                  // RX: FIFO→mem
            dma_state_d = DMA_RX_FIFO_WAIT;
        end
      end

      // TX path: read from memory, push to FIFO
      DMA_TX_RD_REQ: begin
        if (!tx_full[dma_sm_sel]) begin
          dma_req_o  = 1'b1;
          dma_addr_o = dma_cur_addr_q;
          if (dma_gnt_i) dma_state_d = DMA_TX_RD_WAIT;
        end
        // Stall if FIFO full
      end

      DMA_TX_RD_WAIT: begin
        if (dma_rvalid_i) begin
          if (dma_remaining_q == 16'd1)
            dma_state_d = DMA_IDLE;
          else
            dma_state_d = DMA_TX_RD_REQ;
        end
      end

      // RX path: pop from FIFO, write to memory
      DMA_RX_FIFO_WAIT: begin
        if (!rx_empty[dma_sm_sel]) begin
          dma_state_d = DMA_RX_WR_REQ;
        end
        // Stall if FIFO empty
      end

      DMA_RX_WR_REQ: begin
        dma_req_o   = 1'b1;
        dma_addr_o  = dma_cur_addr_q;
        dma_we_o    = 1'b1;
        dma_wdata_o = dma_data_q;
        if (dma_gnt_i) dma_state_d = DMA_RX_WR_WAIT;
      end

      DMA_RX_WR_WAIT: begin
        if (dma_rvalid_i) begin
          if (dma_remaining_q == 16'd1)
            dma_state_d = DMA_IDLE;
          else
            dma_state_d = DMA_RX_FIFO_WAIT;
        end
      end

      default: dma_state_d = DMA_IDLE;
    endcase
  end

  // ===========================================================================
  // DMA sequential logic
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dma_state_q     <= DMA_IDLE;
      dma_busy_q      <= 1'b0;
      dma_done_q      <= 1'b0;
      dma_remaining_q <= 16'd0;
      dma_cur_addr_q  <= 32'd0;
      dma_data_q      <= 32'd0;
    end else begin
      dma_state_q    <= dma_state_d;
      dma_latch_ctrl <= 1'b0;

      // Clear DONE on GO write (W1C for DONE bit too)
      if (ctrl_req_i && ctrl_we_i && ctrl_addr_i[9:0] == REG_DMA_CTRL) begin
        if (ctrl_wdata_i[2]) dma_done_q <= 1'b0; // W1C DONE
      end

      case (dma_state_q)
        DMA_IDLE: begin
          if (dma_go) begin
            dma_busy_q      <= 1'b1;
            dma_done_q      <= 1'b0;
            dma_cur_addr_q  <= dma_addr_q;
            dma_remaining_q <= ctrl_wdata_i[21:6]; // LEN from write data
            dma_latch_ctrl  <= 1'b1;

            if (ctrl_wdata_i[21:6] == 16'd0) begin
              // Zero-length: immediate done
              dma_busy_q <= 1'b0;
              dma_done_q <= 1'b1;
              dma_state_q <= DMA_IDLE;
            end
          end
        end

        DMA_TX_RD_WAIT: begin
          if (dma_rvalid_i) begin
            // Push read data into TX FIFO (done via separate FIFO write logic)
            dma_data_q      <= dma_rdata_i;
            dma_cur_addr_q  <= dma_cur_addr_q + 32'd4;
            dma_remaining_q <= dma_remaining_q - 16'd1;
            if (dma_remaining_q == 16'd1) begin
              dma_busy_q <= 1'b0;
              dma_done_q <= 1'b1;
            end
          end
        end

        DMA_RX_FIFO_WAIT: begin
          if (!rx_empty[dma_sm_sel]) begin
            // Latch RX FIFO data for write
            dma_data_q <= rx_fifo_mem[dma_sm_sel][rx_rd_ptr_q[dma_sm_sel][1:0]];
          end
        end

        DMA_RX_WR_WAIT: begin
          if (dma_rvalid_i) begin
            dma_cur_addr_q  <= dma_cur_addr_q + 32'd4;
            dma_remaining_q <= dma_remaining_q - 16'd1;
            if (dma_remaining_q == 16'd1) begin
              dma_busy_q <= 1'b0;
              dma_done_q <= 1'b1;
            end
          end
        end

        default: ;
      endcase
    end
  end

  // ===========================================================================
  // Register read/write — sequential
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_rvalid_o <= 1'b0;
      ctrl_rdata_o  <= 32'd0;
      sm_en_q       <= 4'd0;
      sm_restart    <= 4'd0;
      irq_flags_q   <= 8'd0;
      gpio_dir_q    <= 32'd0;
      gpio_out_q    <= 32'd0;
      dma_ctrl_q    <= 32'd0;
      dma_addr_q    <= 32'd0;
      sm_force_exec <= 4'd0;
      for (int i = 0; i < NumSm; i++) begin
        sm_clkdiv_q[i]    <= 32'h0001_0000; // INT=1 (divide-by-1)
        sm_execctrl_q[i]  <= {1'b0, 2'b0, 5'd0, 6'd0, 5'd31, 5'd0, 8'd0}; // wrap_top=31
        sm_shiftctrl_q[i] <= 32'd0;
        sm_pinctrl_q[i]   <= 32'd0;
        sm_force_instr[i] <= 16'd0;
      end
    end else begin
      // Clear single-cycle pulses
      sm_restart     <= 4'd0;
      clkdiv_restart <= 4'd0;
      sm_force_exec  <= 4'd0;
      cpu_tx_push    <= 1'b0;
      cpu_rx_pop     <= 1'b0;

      // Latch DMA ctrl fields on GO (request from DMA FSM block)
      if (dma_latch_ctrl) begin
        dma_ctrl_q[3]    <= ctrl_wdata_i[3];    // DIR
        dma_ctrl_q[5:4]  <= ctrl_wdata_i[5:4];  // SM_SEL
        dma_ctrl_q[21:6] <= ctrl_wdata_i[21:6]; // LEN
        dma_ctrl_q[31]   <= ctrl_wdata_i[31];   // DONE_IE
      end

      // IRQ flag update: set from SMs, clear from SMs, W1C from CPU
      for (int i = 0; i < NumSm; i++) begin
        irq_flags_q <= (irq_flags_q | sm_irq_set[i]) & ~sm_irq_clr[i];
      end

      // Read path
      ctrl_rvalid_o <= ctrl_req_i;
      ctrl_rdata_o  <= 32'd0;

      if (ctrl_req_i && !ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_CTRL:        ctrl_rdata_o <= {20'd0, 4'd0, 4'd0, sm_en_q};
          REG_FSTAT:       ctrl_rdata_o <= {4'd0, tx_empty, 4'd0, tx_full,
                                            4'd0, rx_empty, 4'd0, rx_full};
          10'h008:         ctrl_rdata_o <= 32'd0; // FDEBUG reserved
          10'h00C:         ctrl_rdata_o <= 32'd0; // FLEVEL reserved
          REG_IRQ:         ctrl_rdata_o <= {24'd0, irq_flags_q};
          REG_DBG_PADOUT:  ctrl_rdata_o <= gpio_o;
          REG_DBG_PADOE:   ctrl_rdata_o <= gpio_oe;
          REG_DBG_CFGINFO: ctrl_rdata_o <= {10'd0, 6'(ImemSize), 4'd0, 4'(NumSm), 2'd0, 6'(FifoDepth)};
          REG_GPIO_DIR:    ctrl_rdata_o <= gpio_dir_q;
          REG_GPIO_OUT:    ctrl_rdata_o <= gpio_out_q;
          REG_GPIO_IN:     ctrl_rdata_o <= gpio_sync_q2;
          REG_DMA_CTRL:    ctrl_rdata_o <= {dma_done_ie, 9'd0, dma_len, dma_sm_sel, dma_dir,
                                            dma_done_q, dma_busy_q, 1'b0};
          REG_DMA_ADDR:    ctrl_rdata_o <= dma_addr_q;
          default: begin
            // Per-SM register read
            if (ctrl_addr_i[9:0] >= REG_SM0_BASE &&
                ctrl_addr_i[9:0] < (REG_SM0_BASE + 10'(NumSm * 'h20))) begin
              automatic logic [9:0] sm_off_r = ctrl_addr_i[9:0] - REG_SM0_BASE;
              automatic logic [1:0] sm = sm_off_r[6:5];
              case (sm_off_r[4:0])
                SM_CLKDIV:    ctrl_rdata_o <= sm_clkdiv_q[sm];
                SM_EXECCTRL:  ctrl_rdata_o <= {sm_stalled[sm], sm_execctrl_q[sm][30:0]};
                SM_SHIFTCTRL: ctrl_rdata_o <= sm_shiftctrl_q[sm];
                SM_ADDR:      ctrl_rdata_o <= {27'd0, sm_pc[sm]};
                SM_INSTR:     ctrl_rdata_o <= {16'd0, instr_mem[sm_pc[sm]]};
                SM_PINCTRL:   ctrl_rdata_o <= sm_pinctrl_q[sm];
                default:      ctrl_rdata_o <= 32'd0;
              endcase
            end
            // RX FIFO read
            else if (ctrl_addr_i[9:0] >= REG_RXF0 &&
                     ctrl_addr_i[9:0] < (REG_RXF0 + 10'h10)) begin
              automatic logic [1:0] sm = ctrl_addr_i[3:2];
              ctrl_rdata_o <= rx_fifo_mem[sm][rx_rd_ptr_q[sm][1:0]];
            end
          end
        endcase
      end

      // Write path
      if (ctrl_req_i && ctrl_we_i) begin
        case (ctrl_addr_i[9:0])
          REG_CTRL: begin
            sm_en_q    <= ctrl_wdata_i[3:0];
            sm_restart <= ctrl_wdata_i[7:4];
            clkdiv_restart <= ctrl_wdata_i[11:8];
          end
          REG_IRQ: begin
            // W1C
            irq_flags_q <= irq_flags_q & ~ctrl_wdata_i[7:0];
          end
          REG_IRQ_FORCE: begin
            irq_flags_q <= irq_flags_q | ctrl_wdata_i[7:0];
          end
          REG_GPIO_DIR: begin
            if (ctrl_be_i[0]) gpio_dir_q[ 7: 0] <= ctrl_wdata_i[ 7: 0];
            if (ctrl_be_i[1]) gpio_dir_q[15: 8] <= ctrl_wdata_i[15: 8];
            if (ctrl_be_i[2]) gpio_dir_q[23:16] <= ctrl_wdata_i[23:16];
            if (ctrl_be_i[3]) gpio_dir_q[31:24] <= ctrl_wdata_i[31:24];
          end
          REG_GPIO_OUT: begin
            if (ctrl_be_i[0]) gpio_out_q[ 7: 0] <= ctrl_wdata_i[ 7: 0];
            if (ctrl_be_i[1]) gpio_out_q[15: 8] <= ctrl_wdata_i[15: 8];
            if (ctrl_be_i[2]) gpio_out_q[23:16] <= ctrl_wdata_i[23:16];
            if (ctrl_be_i[3]) gpio_out_q[31:24] <= ctrl_wdata_i[31:24];
          end
          REG_DMA_ADDR: dma_addr_q <= ctrl_wdata_i;
          default: begin
            // Per-SM register write
            if (ctrl_addr_i[9:0] >= REG_SM0_BASE &&
                ctrl_addr_i[9:0] < (REG_SM0_BASE + 10'(NumSm * 'h20))) begin
              automatic logic [9:0] sm_off_w = ctrl_addr_i[9:0] - REG_SM0_BASE;
              automatic logic [1:0] sm = sm_off_w[6:5];
              case (sm_off_w[4:0])
                SM_CLKDIV:    sm_clkdiv_q[sm]    <= ctrl_wdata_i;
                SM_EXECCTRL:  sm_execctrl_q[sm]   <= ctrl_wdata_i;
                SM_SHIFTCTRL: sm_shiftctrl_q[sm]  <= ctrl_wdata_i;
                SM_INSTR: begin
                  sm_force_instr[sm] <= ctrl_wdata_i[15:0];
                  sm_force_exec[sm]  <= 1'b1;
                end
                SM_PINCTRL:   sm_pinctrl_q[sm]    <= ctrl_wdata_i;
                default: ;
              endcase
            end
            // TX FIFO write (pointer update in FIFO block)
            else if (ctrl_addr_i[9:0] >= REG_TXF0 &&
                     ctrl_addr_i[9:0] < (REG_TXF0 + 10'h10)) begin
              cpu_tx_push  <= 1'b1;
              cpu_tx_sm    <= ctrl_addr_i[3:2];
              cpu_tx_wdata <= ctrl_wdata_i;
            end
          end
        endcase
      end

      // CPU-side RX FIFO read: signal FIFO block to advance pointer
      if (ctrl_req_i && !ctrl_we_i &&
          ctrl_addr_i[9:0] >= REG_RXF0 &&
          ctrl_addr_i[9:0] < (REG_RXF0 + 10'h10)) begin
        cpu_rx_pop <= 1'b1;
        cpu_rx_sm  <= ctrl_addr_i[3:2];
      end
    end
  end

  // ===========================================================================
  // SM instances
  // ===========================================================================
  generate
    for (gi = 0; gi < NumSm; gi++) begin : gen_sm
      pio_sm u_sm (
        .clk_i,
        .rst_ni,
        .sm_en_i        (sm_en_q[gi]),
        .sm_idx_i       (2'(gi)),

        .pc_o           (sm_pc[gi]),
        .instr_i        (instr_mem[sm_pc[gi]]),

        .clkdiv_int_i        (sm_clkdiv_q[gi][31:16]),
        .execctrl_jmp_pin_i  (sm_execctrl_q[gi][28:24]),
        .execctrl_wrap_top_i (sm_execctrl_q[gi][16:12]),
        .execctrl_wrap_bot_i (sm_execctrl_q[gi][11:7]),
        .shiftctrl_autopull_i    (sm_shiftctrl_q[gi][17]),
        .shiftctrl_autopush_i    (sm_shiftctrl_q[gi][16]),
        .shiftctrl_pull_thresh_i (sm_shiftctrl_q[gi][29:25]),
        .shiftctrl_push_thresh_i (sm_shiftctrl_q[gi][24:20]),
        .shiftctrl_out_shiftdir_i(sm_shiftctrl_q[gi][19]),
        .shiftctrl_in_shiftdir_i (sm_shiftctrl_q[gi][18]),
        .pinctrl_out_base_i      (sm_pinctrl_q[gi][4:0]),
        .pinctrl_out_count_i     (sm_pinctrl_q[gi][25:20]),
        .pinctrl_set_base_i      (sm_pinctrl_q[gi][9:5]),
        .pinctrl_set_count_i     (sm_pinctrl_q[gi][28:26]),
        .pinctrl_in_base_i       (sm_pinctrl_q[gi][19:15]),
        .pinctrl_sideset_base_i  (sm_pinctrl_q[gi][14:10]),
        .pinctrl_sideset_count_i (sm_pinctrl_q[gi][31:29]),
        .execctrl_side_en_i      (sm_execctrl_q[gi][30]),
        .execctrl_side_pindir_i  (sm_execctrl_q[gi][29]),

        .tx_pull_o  (sm_tx_pull[gi]),
        .tx_data_i  (sm_tx_data[gi]),
        .tx_empty_i (sm_tx_empty[gi]),
        .rx_push_o  (sm_rx_push[gi]),
        .rx_data_o  (sm_rx_data[gi]),
        .rx_full_i  (sm_rx_full[gi]),

        .pins_i     (gpio_sync_q2),
        .pins_o     (sm_pins_o[gi]),
        .pins_oe_o  (sm_pins_oe[gi]),

        .irq_set_o    (sm_irq_set[gi]),
        .irq_clr_o    (sm_irq_clr[gi]),
        .irq_flags_i  (irq_flags_q),

        .stalled_o    (sm_stalled[gi]),
        .restart_i    (sm_restart[gi]),
        .force_instr_i(sm_force_instr[gi]),
        .force_exec_i (sm_force_exec[gi])
      );
    end
  endgenerate

  // ===========================================================================
  // Pin output mux (SM3 > SM2 > SM1 > SM0 > GPIO compat) — combinational
  // ===========================================================================
  always_comb begin
    mux_out = gpio_out_q;
    mux_oe  = gpio_dir_q;

    // SM0 has lowest priority, SM3 highest — apply in order so SM3 wins
    for (int s = 0; s < NumSm; s++) begin
      if (sm_en_q[s]) begin
        for (int p = 0; p < 32; p++) begin
          if (sm_pins_oe[s][p]) begin
            mux_out[p] = sm_pins_o[s][p];
            mux_oe[p]  = 1'b1;
          end
        end
      end
    end
  end

  // Register the mux output (breaks combinational depth)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gpio_o  <= 32'd0;
      gpio_oe <= 32'd0;
    end else begin
      gpio_o  <= mux_out;
      gpio_oe <= mux_oe;
    end
  end

endmodule
