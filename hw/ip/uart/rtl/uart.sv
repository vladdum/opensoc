// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * UART peripheral with TX/RX, 8-deep FIFOs, and configurable baud rate.
 *
 * Registers (offset from base):
 *   0x00  THR/RBR  - Transmit Hold / Receive Buffer (W: push TX FIFO, R: pop RX FIFO)
 *   0x04  LSR      - Line Status: [0] TX FIFO not full, [1] RX FIFO not empty
 *   0x08  IER      - Interrupt Enable: [0] TX empty IRQ, [1] RX ready IRQ
 *   0x0C  DIV      - 16-bit baud divisor (clk_freq / baud_rate)
 */
module uart (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Bus interface (same pattern as timer.sv)
  input  logic        req_i,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,

  // Interrupt
  output logic        irq_o,

  // UART pins
  output logic        uart_tx_o,
  input  logic        uart_rx_i
);

  // ---------------------------------------------------------------------------
  // Register offsets
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_THR_RBR = 10'h000;
  localparam logic [9:0] REG_LSR     = 10'h004;
  localparam logic [9:0] REG_IER     = 10'h008;
  localparam logic [9:0] REG_DIV     = 10'h00C;

  // ---------------------------------------------------------------------------
  // FIFO parameters
  // ---------------------------------------------------------------------------
  localparam int FIFO_DEPTH = 8;
  localparam int PTR_W      = $clog2(FIFO_DEPTH);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [1:0]  ier_q;
  logic [15:0] div_q;

  // ---------------------------------------------------------------------------
  // TX FIFO
  // ---------------------------------------------------------------------------
  logic [7:0]  tx_fifo [FIFO_DEPTH];
  logic [PTR_W:0] tx_wr_ptr, tx_rd_ptr;
  wire  [PTR_W:0] tx_count = tx_wr_ptr - tx_rd_ptr;
  wire  tx_fifo_full   = (tx_count == FIFO_DEPTH[PTR_W:0]);
  wire  tx_fifo_empty  = (tx_count == '0);

  // ---------------------------------------------------------------------------
  // RX FIFO
  // ---------------------------------------------------------------------------
  logic [7:0]  rx_fifo [FIFO_DEPTH];
  logic [PTR_W:0] rx_wr_ptr, rx_rd_ptr;
  wire  [PTR_W:0] rx_count = rx_wr_ptr - rx_rd_ptr;
  wire  rx_fifo_full      = (rx_count == FIFO_DEPTH[PTR_W:0]);
  wire  rx_fifo_not_empty = (rx_count != '0);

  // ---------------------------------------------------------------------------
  // Free-running baud reference tick (for waveform debugging)
  // ---------------------------------------------------------------------------
  logic [15:0] baud_ref_cnt_q;
  logic        baud_ref_tick;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      baud_ref_cnt_q <= '0;
      baud_ref_tick  <= 1'b0;
    end else if (div_q == '0) begin
      baud_ref_cnt_q <= '0;
      baud_ref_tick  <= 1'b0;
    end else if (baud_ref_cnt_q == '0) begin
      baud_ref_cnt_q <= div_q - 16'd1;
      baud_ref_tick  <= 1'b1;
    end else begin
      baud_ref_cnt_q <= baud_ref_cnt_q - 16'd1;
      baud_ref_tick  <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // TX shift register
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    TX_IDLE,
    TX_START,
    TX_DATA,
    TX_STOP
  } tx_state_e;

  tx_state_e tx_state_q;
  logic [7:0]  tx_shift_q;
  logic [2:0]  tx_bit_cnt_q;
  logic [15:0] tx_baud_cnt_q;

  wire tx_baud_tick = (tx_baud_cnt_q == '0) && (div_q != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_state_q    <= TX_IDLE;
      tx_shift_q    <= 8'hFF;
      tx_bit_cnt_q  <= '0;
      tx_baud_cnt_q <= '0;
      tx_rd_ptr     <= '0;
      uart_tx_o     <= 1'b1;
    end else begin
      case (tx_state_q)
        TX_IDLE: begin
          uart_tx_o <= 1'b1;
          if (!tx_fifo_empty && div_q != '0) begin
            tx_shift_q    <= tx_fifo[tx_rd_ptr[PTR_W-1:0]];
            tx_rd_ptr     <= tx_rd_ptr + 1'b1;
            tx_state_q    <= TX_START;
            tx_baud_cnt_q <= div_q - 16'd1;
          end
        end
        TX_START: begin
          uart_tx_o <= 1'b0; // start bit
          if (tx_baud_tick) begin
            tx_baud_cnt_q <= div_q - 16'd1;
            tx_state_q    <= TX_DATA;
            tx_bit_cnt_q  <= '0;
          end else begin
            tx_baud_cnt_q <= tx_baud_cnt_q - 16'd1;
          end
        end
        TX_DATA: begin
          uart_tx_o <= tx_shift_q[0];
          if (tx_baud_tick) begin
            tx_shift_q    <= {1'b0, tx_shift_q[7:1]};
            tx_baud_cnt_q <= div_q - 16'd1;
            if (tx_bit_cnt_q == 3'd7) begin
              tx_state_q <= TX_STOP;
            end else begin
              tx_bit_cnt_q <= tx_bit_cnt_q + 3'd1;
            end
          end else begin
            tx_baud_cnt_q <= tx_baud_cnt_q - 16'd1;
          end
        end
        TX_STOP: begin
          uart_tx_o <= 1'b1; // stop bit
          if (tx_baud_tick) begin
            tx_state_q <= TX_IDLE;
          end else begin
            tx_baud_cnt_q <= tx_baud_cnt_q - 16'd1;
          end
        end
        default: tx_state_q <= TX_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // RX shift register (16x oversampling)
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    RX_IDLE,
    RX_START,
    RX_DATA,
    RX_STOP
  } rx_state_e;

  rx_state_e rx_state_q;
  logic [7:0]  rx_shift_q;
  logic [2:0]  rx_bit_cnt_q;
  logic [15:0] rx_baud_cnt_q;

  // 2-FF synchronizer for rx input
  logic rx_sync_q1, rx_sync_q2;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_sync_q1 <= 1'b1;
      rx_sync_q2 <= 1'b1;
    end else begin
      rx_sync_q1 <= uart_rx_i;
      rx_sync_q2 <= rx_sync_q1;
    end
  end

  wire rx_baud_tick = (rx_baud_cnt_q == '0) && (div_q != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q    <= RX_IDLE;
      rx_shift_q    <= '0;
      rx_bit_cnt_q  <= '0;
      rx_baud_cnt_q <= '0;
      rx_wr_ptr     <= '0;
    end else begin
      case (rx_state_q)
        RX_IDLE: begin
          if (!rx_sync_q2 && div_q != '0) begin
            // Falling edge detected (start bit) — sample at mid-bit (8x baud)
            rx_baud_cnt_q <= {1'b0, div_q[15:1]} - 16'd1; // half period
            rx_state_q    <= RX_START;
          end
        end
        RX_START: begin
          if (rx_baud_tick) begin
            if (!rx_sync_q2) begin
              // Confirmed start bit at mid-point
              rx_baud_cnt_q <= div_q - 16'd1;
              rx_state_q    <= RX_DATA;
              rx_bit_cnt_q  <= '0;
            end else begin
              // False start
              rx_state_q <= RX_IDLE;
            end
          end else begin
            rx_baud_cnt_q <= rx_baud_cnt_q - 16'd1;
          end
        end
        RX_DATA: begin
          if (rx_baud_tick) begin
            rx_shift_q    <= {rx_sync_q2, rx_shift_q[7:1]};
            rx_baud_cnt_q <= div_q - 16'd1;
            if (rx_bit_cnt_q == 3'd7) begin
              rx_state_q <= RX_STOP;
            end else begin
              rx_bit_cnt_q <= rx_bit_cnt_q + 3'd1;
            end
          end else begin
            rx_baud_cnt_q <= rx_baud_cnt_q - 16'd1;
          end
        end
        RX_STOP: begin
          if (rx_baud_tick) begin
            if (rx_sync_q2 && !rx_fifo_full) begin
              // Valid stop bit — push into FIFO
              rx_fifo[rx_wr_ptr[PTR_W-1:0]] <= rx_shift_q;
              rx_wr_ptr <= rx_wr_ptr + 1'b1;
            end
            rx_state_q <= RX_IDLE;
          end else begin
            rx_baud_cnt_q <= rx_baud_cnt_q - 16'd1;
          end
        end
        default: rx_state_q <= RX_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Bus read/write
  // ---------------------------------------------------------------------------
  logic [31:0] rdata_q;
  logic        rvalid_q;

  assign rvalid_o = rvalid_q;
  assign rdata_o  = rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q  <= 1'b0;
      rdata_q   <= '0;
      ier_q     <= '0;
      div_q     <= '0;
      tx_wr_ptr <= '0;
      rx_rd_ptr <= '0;
    end else begin
      rvalid_q <= 1'b0;
      if (req_i) begin
        rvalid_q <= 1'b1;
        if (we_i) begin
          // Write
          case (addr_i[9:0])
            REG_THR_RBR: begin
              if (!tx_fifo_full) begin
                tx_fifo[tx_wr_ptr[PTR_W-1:0]] <= wdata_i[7:0];
                tx_wr_ptr <= tx_wr_ptr + 1'b1;
              end
            end
            REG_IER: begin
              if (be_i[0]) ier_q <= wdata_i[1:0];
            end
            REG_DIV: begin
              if (be_i[0]) div_q[7:0]  <= wdata_i[7:0];
              if (be_i[1]) div_q[15:8] <= wdata_i[15:8];
            end
            default: ;
          endcase
        end else begin
          // Read
          case (addr_i[9:0])
            REG_THR_RBR: begin
              rdata_q <= {24'b0, rx_fifo_not_empty ? rx_fifo[rx_rd_ptr[PTR_W-1:0]] : 8'b0};
              if (rx_fifo_not_empty) begin
                rx_rd_ptr <= rx_rd_ptr + 1'b1;
              end
            end
            REG_LSR: begin
              rdata_q <= {30'b0, rx_fifo_not_empty, ~tx_fifo_full};
            end
            REG_IER: begin
              rdata_q <= {30'b0, ier_q};
            end
            REG_DIV: begin
              rdata_q <= {16'b0, div_q};
            end
            default: begin
              rdata_q <= '0;
            end
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Interrupt
  // ---------------------------------------------------------------------------
  assign irq_o = (tx_fifo_empty & ier_q[0]) | (rx_fifo_not_empty & ier_q[1]);

endmodule
