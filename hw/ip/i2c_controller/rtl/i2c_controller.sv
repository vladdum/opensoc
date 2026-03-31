// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Minimal I2C master controller — single-byte read/write transactions.
 *
 * Registers (offset from base):
 *   0x00  CTRL     - [0] start, [1] stop, [2] read/write (1=read), [3] ack_enable
 *   0x04  STATUS   - [0] busy, [1] ack received, [2] arbitration lost
 *   0x08  TX_DATA  - Byte to transmit
 *   0x0C  RX_DATA  - Received byte
 *   0x10  PRESCALE - 16-bit clock prescaler for SCL frequency
 *   0x14  IER      - [0] transfer complete IRQ enable
 *
 * Open-drain modeled as separate output/output-enable/input signals.
 */
module i2c_controller (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Bus interface
  input  logic        req_i,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [ 3:0] be_i,
  input  logic [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,

  // Interrupt
  output logic        irq_o,

  // I2C pins (active-low open-drain modeled with o/oe/i)
  output logic        i2c_scl_o,
  output logic        i2c_scl_oe,
  input  logic        i2c_scl_i,
  output logic        i2c_sda_o,
  output logic        i2c_sda_oe,
  input  logic        i2c_sda_i
);

  // ---------------------------------------------------------------------------
  // Register offsets
  // ---------------------------------------------------------------------------
  localparam logic [9:0] REG_CTRL     = 10'h000;
  localparam logic [9:0] REG_STATUS   = 10'h004;
  localparam logic [9:0] REG_TX_DATA  = 10'h008;
  localparam logic [9:0] REG_RX_DATA  = 10'h00C;
  localparam logic [9:0] REG_PRESCALE = 10'h010;
  localparam logic [9:0] REG_IER      = 10'h014;

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [3:0]  ctrl_q;      // start, stop, rw, ack_en
  logic        ack_recv_q;
  logic        arb_lost_q;
  logic [7:0]  tx_data_q;
  logic [7:0]  rx_data_q;
  logic [15:0] prescale_q;
  logic        ier_q;

  // ---------------------------------------------------------------------------
  // I2C FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    I2C_IDLE,
    I2C_START_A,    // SCL high, pull SDA low
    I2C_START_B,    // Pull SCL low
    I2C_DATA_SCL_LO,
    I2C_DATA_SCL_HI,
    I2C_ACK_SCL_LO,
    I2C_ACK_SCL_HI,
    I2C_STOP_A,     // SCL low, SDA low
    I2C_STOP_B,     // SCL high
    I2C_STOP_C,     // SDA high (release)
    I2C_DONE,
    I2C_WAIT_NEXT   // SCL low, wait for CPU to queue next byte
  } i2c_state_e;

  i2c_state_e state_q;
  logic [15:0] clk_cnt_q;
  logic [2:0]  bit_cnt_q;
  logic [7:0]  shift_q;
  logic        busy;
  logic        xfer_done;
  logic        ctrl_pending_q;  // set when CPU writes CTRL, cleared when FSM consumes
  logic        ctrl_pending_clr; // FSM requests clear (combinational)
  logic [3:0]  xfer_ctrl_q;    // latched ctrl bits for current byte transfer

  // WAIT_NEXT reports not-busy so CPU can queue next byte
  assign busy = (state_q != I2C_IDLE) && (state_q != I2C_DONE) && (state_q != I2C_WAIT_NEXT);

  // Open-drain: drive low when oe=1, o=0; release (high-Z) when oe=0
  assign i2c_scl_o = 1'b0;
  assign i2c_sda_o = 1'b0;

  // SCL/SDA output enable control from FSM
  logic scl_oe_q, sda_oe_q;
  assign i2c_scl_oe = scl_oe_q;
  assign i2c_sda_oe = sda_oe_q;

  wire clk_tick = (clk_cnt_q == '0) && (prescale_q != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= I2C_IDLE;
      clk_cnt_q      <= '0;
      bit_cnt_q      <= '0;
      shift_q        <= '0;
      scl_oe_q       <= 1'b0;
      sda_oe_q       <= 1'b0;
      ack_recv_q     <= 1'b0;
      arb_lost_q     <= 1'b0;
      rx_data_q      <= '0;
      xfer_done      <= 1'b0;
      xfer_ctrl_q    <= '0;
    end else begin
      xfer_done <= 1'b0;
      ctrl_pending_clr <= 1'b0;

      case (state_q)
        I2C_IDLE: begin
          scl_oe_q <= 1'b0; // release SCL
          sda_oe_q <= 1'b0; // release SDA
          if (ctrl_q[0]) begin // start requested
            // Begin start condition: SDA goes low while SCL is high
            xfer_ctrl_q <= ctrl_q;  // latch STOP/RW/ACK bits
            shift_q   <= tx_data_q;
            bit_cnt_q <= 3'd7;
            clk_cnt_q <= prescale_q - 16'd1;
            sda_oe_q  <= 1'b1; // pull SDA low
            state_q   <= I2C_START_A;
          end
        end

        I2C_START_A: begin
          // SDA is low, SCL is still high — hold for one prescale period
          if (clk_tick) begin
            scl_oe_q  <= 1'b1; // pull SCL low
            clk_cnt_q <= prescale_q - 16'd1;
            state_q   <= I2C_START_B;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_START_B: begin
          if (clk_tick) begin
            clk_cnt_q <= prescale_q - 16'd1;
            // Set up first data bit on SDA
            sda_oe_q  <= xfer_ctrl_q[2] ? 1'b0 : ~shift_q[7]; // read: release SDA; write: drive bit
            state_q   <= I2C_DATA_SCL_LO;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_DATA_SCL_LO: begin
          // SCL low, data bit is on SDA
          scl_oe_q <= 1'b1; // SCL low
          if (clk_tick) begin
            scl_oe_q  <= 1'b0; // release SCL (goes high)
            clk_cnt_q <= prescale_q - 16'd1;
            state_q   <= I2C_DATA_SCL_HI;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_DATA_SCL_HI: begin
          // SCL high — sample SDA for read, check arb for write
          if (clk_tick) begin
            // Sample
            if (xfer_ctrl_q[2]) begin
              // Read mode: capture bit from SDA
              shift_q <= {shift_q[6:0], i2c_sda_i};
            end else begin
              // Write mode: check arbitration
              if (sda_oe_q == 1'b0 && i2c_sda_i == 1'b0) begin
                // We released SDA (sending 1) but it's low — arb lost
                arb_lost_q <= 1'b1;
                state_q    <= I2C_DONE;
              end
            end

            scl_oe_q  <= 1'b1; // pull SCL low
            clk_cnt_q <= prescale_q - 16'd1;

            if (bit_cnt_q == 3'd0) begin
              // All 8 bits done — move to ACK
              state_q  <= I2C_ACK_SCL_LO;
              // For write: release SDA to let slave ACK
              // For read: drive ACK/NACK based on ack_enable
              if (xfer_ctrl_q[2]) begin
                sda_oe_q <= xfer_ctrl_q[3] ? 1'b1 : 1'b0; // ACK (pull low) or NACK (release)
              end else begin
                sda_oe_q <= 1'b0; // release for slave ACK
              end
            end else begin
              bit_cnt_q <= bit_cnt_q - 3'd1;
              state_q   <= I2C_DATA_SCL_LO;
              // Set up next data bit
              if (xfer_ctrl_q[2]) begin
                sda_oe_q <= 1'b0; // read: keep SDA released
              end else begin
                sda_oe_q <= ~shift_q[bit_cnt_q - 3'd1]; // next bit
              end
            end
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_ACK_SCL_LO: begin
          scl_oe_q <= 1'b1; // SCL low
          if (clk_tick) begin
            scl_oe_q  <= 1'b0; // release SCL
            clk_cnt_q <= prescale_q - 16'd1;
            state_q   <= I2C_ACK_SCL_HI;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_ACK_SCL_HI: begin
          // SCL high — sample ACK
          if (clk_tick) begin
            if (!xfer_ctrl_q[2]) begin
              // Write mode: sample slave's ACK (SDA low = ACK)
              ack_recv_q <= ~i2c_sda_i;
            end
            if (xfer_ctrl_q[2]) begin
              rx_data_q <= shift_q;
            end

            scl_oe_q  <= 1'b1; // pull SCL low
            clk_cnt_q <= prescale_q - 16'd1;

            if (xfer_ctrl_q[1]) begin
              // Stop requested
              sda_oe_q <= 1'b1; // pull SDA low for stop setup
              state_q  <= I2C_STOP_A;
            end else begin
              // No stop — hold SCL low, wait for next byte from CPU
              ctrl_pending_clr <= 1'b1;
              state_q <= I2C_WAIT_NEXT;
            end
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_STOP_A: begin
          // SCL low, SDA low
          scl_oe_q <= 1'b1;
          sda_oe_q <= 1'b1;
          if (clk_tick) begin
            scl_oe_q  <= 1'b0; // release SCL (goes high)
            clk_cnt_q <= prescale_q - 16'd1;
            state_q   <= I2C_STOP_B;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_STOP_B: begin
          // SCL high, SDA still low
          if (clk_tick) begin
            sda_oe_q  <= 1'b0; // release SDA (goes high) — stop condition
            state_q   <= I2C_DONE;
          end else begin
            clk_cnt_q <= clk_cnt_q - 16'd1;
          end
        end

        I2C_STOP_C: begin
          state_q <= I2C_DONE;
        end

        I2C_WAIT_NEXT: begin
          // SCL held low from ACK_SCL_HI. Wait for CPU to write new CTRL.
          scl_oe_q <= 1'b1;  // keep SCL low
          if (ctrl_pending_q) begin
            ctrl_pending_clr <= 1'b1;
            xfer_ctrl_q    <= ctrl_q;  // latch new ctrl bits for this byte
            if (ctrl_q[0]) begin
              // Repeated START requested
              sda_oe_q  <= 1'b0; // release SDA before START
              scl_oe_q  <= 1'b0; // release SCL
              clk_cnt_q <= prescale_q - 16'd1;
              shift_q   <= tx_data_q;
              bit_cnt_q <= 3'd7;
              state_q   <= I2C_START_A;
            end else begin
              // Continue: send next byte (may include STOP after ACK)
              shift_q   <= tx_data_q;
              bit_cnt_q <= 3'd7;
              clk_cnt_q <= prescale_q - 16'd1;
              sda_oe_q  <= ctrl_q[2] ? 1'b0 : ~tx_data_q[7]; // first data bit
              state_q   <= I2C_DATA_SCL_LO;
            end
          end
        end

        I2C_DONE: begin
          xfer_done <= 1'b1;
          state_q   <= I2C_IDLE;
        end

        default: state_q <= I2C_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Bus read/write
  // ---------------------------------------------------------------------------
  logic [31:0] rdata_d;
  logic        rvalid_q;

  assign rvalid_o = rvalid_q;
  assign rdata_o  = rdata_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q       <= 1'b0;
      rdata_d        <= '0;
      ctrl_q         <= '0;
      ctrl_pending_q <= 1'b0;
      tx_data_q      <= '0;
      prescale_q     <= '0;
      ier_q          <= 1'b0;
    end else begin
      rvalid_q <= 1'b0;

      // FSM requests clear of ctrl_pending
      if (ctrl_pending_clr) begin
        ctrl_pending_q <= 1'b0;
      end

      // Auto-clear ctrl start/stop bits when FSM leaves IDLE
      if (busy) begin
        ctrl_q[1:0] <= 2'b00;
      end

      if (req_i) begin
        rvalid_q <= 1'b1;
        if (we_i) begin
          case (addr_i[9:0])
            REG_CTRL: begin
              if (be_i[0]) begin
                ctrl_q <= wdata_i[3:0];
                ctrl_pending_q <= 1'b1;
              end
            end
            REG_TX_DATA: begin
              if (be_i[0]) tx_data_q <= wdata_i[7:0];
            end
            REG_PRESCALE: begin
              if (be_i[0]) prescale_q[7:0]  <= wdata_i[7:0];
              if (be_i[1]) prescale_q[15:8] <= wdata_i[15:8];
            end
            REG_IER: begin
              if (be_i[0]) ier_q <= wdata_i[0];
            end
            default: ;
          endcase
        end else begin
          case (addr_i[9:0])
            REG_CTRL:     rdata_d <= {28'b0, ctrl_q};
            REG_STATUS:   rdata_d <= {29'b0, arb_lost_q, ack_recv_q, busy};
            REG_TX_DATA:  rdata_d <= {24'b0, tx_data_q};
            REG_RX_DATA:  rdata_d <= {24'b0, rx_data_q};
            REG_PRESCALE: rdata_d <= {16'b0, prescale_q};
            REG_IER:      rdata_d <= {31'b0, ier_q};
            default:      rdata_d <= '0;
          endcase
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Interrupt — transfer complete
  // ---------------------------------------------------------------------------
  assign irq_o = xfer_done & ier_q;

endmodule
