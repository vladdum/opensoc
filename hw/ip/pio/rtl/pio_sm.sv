// Copyright OpenSoC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * PIO State Machine Engine
 *
 * Executes a 9-instruction, 16-bit PIO ISA. Each SM has its own PC, ISR, OSR,
 * X/Y scratch registers, shift counters, and clock divider. The top-level
 * pio.sv instantiates 4 of these.
 *
 * Instruction encoding:
 *   [15:13] opcode   [12:8] delay/side-set   [7:0] operands
 *
 * Opcodes: JMP(000) WAIT(001) IN(010) OUT(011) PUSH/PULL(100)
 *          MOV(101) IRQ(110) SET(111)
 */
module pio_sm (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        sm_en_i,

  // SM index (0-3) for relative IRQ
  input  logic [1:0]  sm_idx_i,

  // Instruction fetch (from pio.sv instruction memory)
  output logic [4:0]  pc_o,
  input  logic [15:0] instr_i,

  // Configuration registers (directly from pio.sv register file)
  input  logic [15:0] clkdiv_int_i,      // SMn_CLKDIV[31:16]
  input  logic [4:0]  execctrl_jmp_pin_i, // EXECCTRL[28:24]
  input  logic [4:0]  execctrl_wrap_top_i, // EXECCTRL[16:12]
  input  logic [4:0]  execctrl_wrap_bot_i, // EXECCTRL[11:7]
  input  logic        shiftctrl_autopull_i, // SHIFTCTRL[17]
  input  logic        shiftctrl_autopush_i, // SHIFTCTRL[16]
  input  logic [4:0]  shiftctrl_pull_thresh_i, // SHIFTCTRL[29:25]
  input  logic [4:0]  shiftctrl_push_thresh_i, // SHIFTCTRL[24:20]
  input  logic        shiftctrl_out_shiftdir_i, // SHIFTCTRL[19] 1=right
  input  logic        shiftctrl_in_shiftdir_i,  // SHIFTCTRL[18] 1=right
  input  logic [4:0]  pinctrl_out_base_i,
  input  logic [5:0]  pinctrl_out_count_i,
  input  logic [4:0]  pinctrl_set_base_i,
  input  logic [2:0]  pinctrl_set_count_i,
  input  logic [4:0]  pinctrl_in_base_i,
  input  logic [4:0]  pinctrl_sideset_base_i,
  input  logic [2:0]  pinctrl_sideset_count_i,
  input  logic        execctrl_side_en_i,     // EXECCTRL[30]: optional sideset enable
  input  logic        execctrl_side_pindir_i,  // EXECCTRL[29]: sideset targets pindirs

  // FIFO interface
  output logic        tx_pull_o,
  input  logic [31:0] tx_data_i,
  input  logic        tx_empty_i,
  output logic        rx_push_o,
  output logic [31:0] rx_data_o,
  input  logic        rx_full_i,

  // Pin I/O
  input  logic [31:0] pins_i,
  output logic [31:0] pins_o,
  output logic [31:0] pins_oe_o,

  // IRQ interface
  output logic [7:0]  irq_set_o,
  output logic [7:0]  irq_clr_o,
  input  logic [7:0]  irq_flags_i,

  // Status / control
  output logic        stalled_o,
  input  logic        restart_i,
  input  logic [15:0] force_instr_i,
  input  logic        force_exec_i
);

  // ===========================================================================
  // All internal signal declarations
  // ===========================================================================

  // Core state registers
  logic [4:0]  pc_q;
  logic [31:0] isr_q, osr_q;
  logic [31:0] x_q, y_q;
  logic [5:0]  isr_cnt_q, osr_cnt_q;  // shift counters
  logic [31:0] pins_out_q, pins_oe_q; // latched pin outputs

  // Clock divider
  logic [15:0] div_counter_q;
  logic        tick;
  logic [15:0] div_top;

  // Delay counter
  logic [4:0] delay_cnt_q;
  logic       in_delay;

  // Instruction selection
  logic [15:0] exec_instr;
  logic        use_forced_q;

  // Instruction decode
  logic [2:0]  opcode;
  logic [4:0]  delay_sideset;
  logic [7:0]  operands;

  // Delay and side-set field split (driven by always_comb)
  logic [4:0] instr_delay;
  logic [4:0] sideset_val;

  // Autopush/autopull thresholds
  logic [5:0] push_thresh, pull_thresh;

  // OSR empty flag for JMP !OSRE
  logic osr_empty;

  // Stall / side-set control (driven by always_comb)
  logic        stall;
  logic        do_sideset;

  // EXEC pending register (for OUT EXEC / MOV EXEC)
  logic [15:0] exec_pending_q;
  logic        exec_pending_valid_q;

  // ===========================================================================
  // Output assigns
  // ===========================================================================
  assign pc_o      = pc_q;
  assign pins_o    = pins_out_q;
  assign pins_oe_o = pins_oe_q;

  // Clock divider — INT=0 or INT=1 both produce every-cycle ticks
  assign div_top = (clkdiv_int_i <= 16'd1) ? 16'd0 : (clkdiv_int_i - 16'd1);
  assign tick    = (div_counter_q == 16'd0) && sm_en_i;

  // Delay
  assign in_delay = (delay_cnt_q != 5'd0);

  // Instruction selection: forced > exec_pending > normal fetch
  assign exec_instr = use_forced_q      ? force_instr_i :
                       exec_pending_valid_q ? exec_pending_q :
                                              instr_i;

  // Instruction decode fields
  assign opcode        = exec_instr[15:13];
  assign delay_sideset = exec_instr[12:8];
  assign operands      = exec_instr[7:0];

  // Autopush/autopull thresholds (0 means 32)
  assign push_thresh = (shiftctrl_push_thresh_i == 5'd0) ? 6'd32 : {1'b0, shiftctrl_push_thresh_i};
  assign pull_thresh = (shiftctrl_pull_thresh_i == 5'd0) ? 6'd32 : {1'b0, shiftctrl_pull_thresh_i};
  assign osr_empty   = (osr_cnt_q >= pull_thresh);

  // Stall status output
  assign stalled_o = stall && tick && !in_delay;

  // ===========================================================================
  // Pin helpers — combinational functions
  // ===========================================================================
  // Read N bits from pins starting at base (wrapping at 32)
  function automatic logic [31:0] read_pins(
    input logic [31:0] all_pins,
    input logic [4:0]  base,
    input logic [5:0]  count
  );
    logic [63:0] doubled;
    logic [31:0] mask;
    doubled = {all_pins, all_pins};
    mask = (count == 6'd32) ? 32'hFFFFFFFF : ((32'd1 << count) - 32'd1);
    read_pins = doubled[{1'b0, base} +: 32] & mask;
  endfunction

  // Write N bits to pin output registers starting at base (wrapping at 32)
  function automatic logic [31:0] write_pins(
    input logic [31:0] cur_pins,
    input logic [31:0] data,
    input logic [4:0]  base,
    input logic [5:0]  count
  );
    logic [31:0] mask;
    logic [31:0] result;
    logic [31:0] base32;
    base32 = {27'd0, base};
    mask = (count == 6'd32) ? 32'hFFFFFFFF : ((32'd1 << count) - 32'd1);
    result = cur_pins;
    for (int unsigned i = 0; i < 32; i++) begin
      if (mask[(32 + i - base32) % 32])
        result[i] = data[(32 + i - base32) % 32];
    end
    write_pins = result;
  endfunction

  // ===========================================================================
  // Shift helpers — combinational functions
  // ===========================================================================
  // Shift N bits into ISR
  function automatic logic [31:0] shift_in(
    input logic [31:0] isr,
    input logic [31:0] data,
    input logic [4:0]  bit_count,  // 0 means 32
    input logic        right_shift
  );
    logic [5:0] n;
    n = (bit_count == 5'd0) ? 6'd32 : {1'b0, bit_count};
    if (right_shift) begin
      // Shift right: new data enters from MSB side
      shift_in = (isr >> n) | (data << (6'd32 - n));
    end else begin
      // Shift left: new data enters from LSB side
      shift_in = (isr << n) | (data & ((n == 6'd32) ? 32'hFFFFFFFF : ((32'd1 << n) - 32'd1)));
    end
  endfunction

  // Shift N bits out of OSR
  function automatic logic [31:0] shift_out_data(
    input logic [31:0] osr,
    input logic [4:0]  bit_count,
    input logic        right_shift
  );
    logic [5:0] n;
    n = (bit_count == 5'd0) ? 6'd32 : {1'b0, bit_count};
    if (right_shift) begin
      // Right shift: data comes from LSB side
      shift_out_data = osr & ((n == 6'd32) ? 32'hFFFFFFFF : ((32'd1 << n) - 32'd1));
    end else begin
      // Left shift: data comes from MSB side
      shift_out_data = osr >> (6'd32 - n);
    end
  endfunction

  function automatic logic [31:0] shift_out_remain(
    input logic [31:0] osr,
    input logic [4:0]  bit_count,
    input logic        right_shift
  );
    logic [5:0] n;
    n = (bit_count == 5'd0) ? 6'd32 : {1'b0, bit_count};
    if (right_shift) begin
      shift_out_remain = osr >> n;
    end else begin
      shift_out_remain = osr << n;
    end
  endfunction

  // IRQ relative index helper
  function automatic logic [2:0] irq_rel_idx(
    input logic [4:0] raw_idx,
    input logic [1:0] sm
  );
    if (raw_idx[4])
      irq_rel_idx = (raw_idx[2:0] + {1'b0, sm}) & 3'b011; // mod 4 for flags 0-3
    else
      irq_rel_idx = raw_idx[2:0];
  endfunction

  // ===========================================================================
  // Clock divider — sequential
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_counter_q <= 16'd0;
    end else if (!sm_en_i) begin
      div_counter_q <= div_top;
    end else if (div_counter_q == 16'd0) begin
      div_counter_q <= div_top;
    end else begin
      div_counter_q <= div_counter_q - 16'd1;
    end
  end

  // ===========================================================================
  // Forced instruction latch
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      use_forced_q <= 1'b0;
    end else if (force_exec_i) begin
      use_forced_q <= 1'b1;
    end else if (tick && !in_delay) begin
      use_forced_q <= 1'b0;
    end
  end

  // ===========================================================================
  // Delay and side-set field split — combinational
  // ===========================================================================
  // Side-set uses top N bits of delay_sideset field (N = pinctrl_sideset_count).
  // When SIDE_EN=1, the MSB of those N bits is an enable flag, and the
  // remaining (N-1) bits are the actual sideset data.
  // Delay uses the remaining bits below the sideset field.
  always_comb begin
    sideset_val = 5'd0;
    instr_delay = 5'd0;
    do_sideset  = 1'b0;
    case (pinctrl_sideset_count_i)
      3'd0: begin
        instr_delay = delay_sideset;
        do_sideset  = 1'b0;
      end
      3'd1: begin
        if (execctrl_side_en_i) begin
          // 1 bit allocated: MSB is enable, 0 data bits
          do_sideset  = delay_sideset[4];
          sideset_val = 5'd0;
          instr_delay = {1'b0, delay_sideset[3:0]};
        end else begin
          sideset_val = {4'd0, delay_sideset[4]};
          instr_delay = {1'b0, delay_sideset[3:0]};
          do_sideset  = 1'b1;
        end
      end
      3'd2: begin
        if (execctrl_side_en_i) begin
          // 2 bits allocated: MSB is enable, 1 data bit
          do_sideset  = delay_sideset[4];
          sideset_val = {4'd0, delay_sideset[3]};
          instr_delay = {2'b0, delay_sideset[2:0]};
        end else begin
          sideset_val = {3'd0, delay_sideset[4:3]};
          instr_delay = {2'b0, delay_sideset[2:0]};
          do_sideset  = 1'b1;
        end
      end
      3'd3: begin
        if (execctrl_side_en_i) begin
          // 3 bits allocated: MSB is enable, 2 data bits
          do_sideset  = delay_sideset[4];
          sideset_val = {3'd0, delay_sideset[3:2]};
          instr_delay = {3'b0, delay_sideset[1:0]};
        end else begin
          sideset_val = {2'd0, delay_sideset[4:2]};
          instr_delay = {3'b0, delay_sideset[1:0]};
          do_sideset  = 1'b1;
        end
      end
      3'd4: begin
        if (execctrl_side_en_i) begin
          // 4 bits allocated: MSB is enable, 3 data bits
          do_sideset  = delay_sideset[4];
          sideset_val = {2'd0, delay_sideset[3:1]};
          instr_delay = {4'b0, delay_sideset[0]};
        end else begin
          sideset_val = {1'd0, delay_sideset[4:1]};
          instr_delay = {4'b0, delay_sideset[0]};
          do_sideset  = 1'b1;
        end
      end
      3'd5: begin
        if (execctrl_side_en_i) begin
          // 5 bits allocated: MSB is enable, 4 data bits
          do_sideset  = delay_sideset[4];
          sideset_val = {1'd0, delay_sideset[3:0]};
          instr_delay = 5'd0;
        end else begin
          sideset_val = delay_sideset;
          instr_delay = 5'd0;
          do_sideset  = 1'b1;
        end
      end
      default: begin
        instr_delay = delay_sideset;
        do_sideset  = 1'b0;
      end
    endcase
  end

  // ===========================================================================
  // Stall control — combinational
  // ===========================================================================
  always_comb begin
    stall = 1'b0;
  end

  // ===========================================================================
  // Main execution — sequential
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q        <= 5'd0;
      isr_q       <= 32'd0;
      osr_q       <= 32'd0;
      x_q         <= 32'd0;
      y_q         <= 32'd0;
      isr_cnt_q   <= 6'd0;
      osr_cnt_q   <= 6'd0;
      pins_out_q  <= 32'd0;
      pins_oe_q   <= 32'd0;
      delay_cnt_q          <= 5'd0;
      exec_pending_q       <= 16'd0;
      exec_pending_valid_q <= 1'b0;
      irq_set_o   <= 8'd0;
      irq_clr_o   <= 8'd0;
      tx_pull_o   <= 1'b0;
      rx_push_o   <= 1'b0;
      rx_data_o   <= 32'd0;
    end else begin
      // Default: clear single-cycle pulses
      irq_set_o <= 8'd0;
      irq_clr_o <= 8'd0;
      tx_pull_o <= 1'b0;
      rx_push_o <= 1'b0;

      // Restart: reset PC and registers but NOT FIFOs
      if (restart_i) begin
        pc_q                 <= execctrl_wrap_bot_i;
        isr_q                <= 32'd0;
        osr_q                <= 32'd0;
        x_q                  <= 32'd0;
        y_q                  <= 32'd0;
        isr_cnt_q            <= 6'd0;
        osr_cnt_q            <= 6'd0;
        delay_cnt_q          <= 5'd0;
        exec_pending_valid_q <= 1'b0;
      end else if (tick) begin
        // ---------------------------------------------------------------
        // Delay phase: count down, no instruction execution
        // ---------------------------------------------------------------
        if (in_delay && !force_exec_i) begin
          delay_cnt_q <= delay_cnt_q - 5'd1;
        end else begin
          // =============================================================
          // Instruction execution
          // =============================================================

          // Automatic variables for instruction decode
          automatic logic [2:0] jmp_cond    = operands[7:5];
          automatic logic [4:0] jmp_addr    = operands[4:0];
          automatic logic       wait_pol    = operands[7];
          automatic logic [1:0] wait_src    = operands[6:5];
          automatic logic [4:0] wait_idx    = operands[4:0];
          automatic logic [2:0] in_src      = operands[7:5];
          automatic logic [4:0] in_cnt      = operands[4:0];
          automatic logic [2:0] out_dst     = operands[7:5];
          automatic logic [4:0] out_cnt     = operands[4:0];
          automatic logic       pp_is_pull  = operands[7];
          automatic logic       pp_if_flag  = operands[6];
          automatic logic       pp_block    = operands[5];
          automatic logic [2:0] mov_dst     = operands[7:5];
          automatic logic [1:0] mov_op      = operands[4:3];
          automatic logic [2:0] mov_src     = operands[2:0];
          automatic logic       irq_wait    = operands[6];
          automatic logic       irq_clear   = operands[5];
          automatic logic [4:0] irq_idx_raw = operands[4:0];
          automatic logic [2:0] set_dst     = operands[7:5];
          automatic logic [4:0] set_data    = operands[4:0];

          automatic logic        take_jmp = 1'b0;
          automatic logic        do_stall = 1'b0;
          automatic logic [31:0] in_data  = 32'd0;
          automatic logic [31:0] out_data = 32'd0;
          automatic logic [31:0] mov_val  = 32'd0;
          automatic logic [5:0]  in_n     = (in_cnt == 5'd0) ? 6'd32 : {1'b0, in_cnt};
          automatic logic [5:0]  out_n    = (out_cnt == 5'd0) ? 6'd32 : {1'b0, out_cnt};
          automatic logic [2:0]  irq_flag_idx = irq_rel_idx(irq_idx_raw, sm_idx_i);

          // Side-set: apply on first cycle of instruction (including first stall cycle)
          // When SIDE_EN=1, do_sideset comes from the instruction enable bit.
          // When SIDE_PINDIR=1, sideset targets pindirs (pins_oe_q) not pins_out_q.
          // Effective sideset width: sideset_count when !SIDE_EN, sideset_count-1 when SIDE_EN.
          if (do_sideset) begin
            automatic logic [2:0] ss_width = execctrl_side_en_i ?
                                             (pinctrl_sideset_count_i - 3'd1) :
                                             pinctrl_sideset_count_i;
            if (execctrl_side_pindir_i) begin
              pins_oe_q <= write_pins(pins_oe_q, {27'd0, sideset_val},
                                      pinctrl_sideset_base_i,
                                      {3'd0, ss_width});
            end else begin
              pins_out_q <= write_pins(pins_out_q, {27'd0, sideset_val},
                                       pinctrl_sideset_base_i,
                                       {3'd0, ss_width});
            end
          end

          case (opcode)
            // -----------------------------------------------------------
            // JMP
            // -----------------------------------------------------------
            3'b000: begin
              case (jmp_cond)
                3'd0: take_jmp = 1'b1;                          // always
                3'd1: take_jmp = (x_q == 32'd0);                // !X
                3'd2: begin take_jmp = (x_q != 32'd0); x_q <= x_q - 32'd1; end // X--
                3'd3: take_jmp = (y_q == 32'd0);                // !Y
                3'd4: begin take_jmp = (y_q != 32'd0); y_q <= y_q - 32'd1; end // Y--
                3'd5: take_jmp = (x_q != y_q);                  // X!=Y
                3'd6: take_jmp = pins_i[execctrl_jmp_pin_i];    // PIN
                3'd7: take_jmp = !osr_empty;                    // !OSRE
                default: ;
              endcase

              if (take_jmp) begin
                pc_q <= jmp_addr;
              end else begin
                // Normal PC advance
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
              end
              if (!do_stall) delay_cnt_q <= instr_delay;
            end

            // -----------------------------------------------------------
            // WAIT
            // -----------------------------------------------------------
            3'b001: begin
              do_stall = 1'b1;
              case (wait_src)
                2'd0: begin // GPIO (absolute pin)
                  if (pins_i[wait_idx] == wait_pol) do_stall = 1'b0;
                end
                2'd1: begin // PIN (relative to IN_BASE)
                  automatic logic [4:0] pin_num = pinctrl_in_base_i + wait_idx;
                  if (pins_i[pin_num] == wait_pol) do_stall = 1'b0;
                end
                2'd2: begin // IRQ
                  automatic logic [2:0] flag = irq_rel_idx(wait_idx, sm_idx_i);
                  if (irq_flags_i[flag] == wait_pol) begin
                    do_stall = 1'b0;
                    // Clear IRQ flag when condition is met
                    if (wait_pol) irq_clr_o[flag] <= 1'b1;
                  end
                end
                default: do_stall = 1'b0;
              endcase

              if (!do_stall) begin
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
                delay_cnt_q <= instr_delay;
              end
            end

            // -----------------------------------------------------------
            // IN
            // -----------------------------------------------------------
            3'b010: begin
              case (in_src)
                3'd0: in_data = read_pins(pins_i, pinctrl_in_base_i, 6'd32); // PINS — read all, bit_count mask applied below
                3'd1: in_data = x_q;
                3'd2: in_data = y_q;
                3'd3: in_data = 32'd0; // NULL
                3'd6: in_data = isr_q;
                3'd7: in_data = osr_q;
                default: in_data = 32'd0;
              endcase

              // Mask to bit_count bits
              in_data = in_data & ((in_n == 6'd32) ? 32'hFFFFFFFF : ((32'd1 << in_n) - 32'd1));

              isr_q <= shift_in(isr_q, in_data, in_cnt, shiftctrl_in_shiftdir_i);
              isr_cnt_q <= isr_cnt_q + in_n;

              // Autopush check
              if (shiftctrl_autopush_i && (isr_cnt_q + in_n >= push_thresh)) begin
                if (!rx_full_i) begin
                  rx_push_o <= 1'b1;
                  rx_data_o <= shift_in(isr_q, in_data, in_cnt, shiftctrl_in_shiftdir_i);
                  isr_q     <= 32'd0;
                  isr_cnt_q <= 6'd0;
                end else begin
                  do_stall = 1'b1;
                end
              end

              if (!do_stall) begin
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
                delay_cnt_q <= instr_delay;
              end
            end

            // -----------------------------------------------------------
            // OUT
            // -----------------------------------------------------------
            3'b011: begin
              // Autopull: if OSR empty, automatically pull
              if (shiftctrl_autopull_i && osr_empty) begin
                if (!tx_empty_i) begin
                  tx_pull_o <= 1'b1;
                  osr_q     <= tx_data_i;
                  osr_cnt_q <= 6'd0;
                  // Stall this cycle, execute OUT next tick with fresh OSR
                  do_stall = 1'b1;
                end else begin
                  do_stall = 1'b1;
                end
              end else begin
                out_data = shift_out_data(osr_q, out_cnt, shiftctrl_out_shiftdir_i);
                osr_q    <= shift_out_remain(osr_q, out_cnt, shiftctrl_out_shiftdir_i);
                osr_cnt_q <= osr_cnt_q + out_n;

                case (out_dst)
                  3'd0: pins_out_q <= write_pins(pins_out_q, out_data,
                                                  pinctrl_out_base_i,
                                                  pinctrl_out_count_i);
                  3'd1: x_q <= out_data;
                  3'd2: y_q <= out_data;
                  3'd3: ; // NULL — discard
                  3'd4: pins_oe_q <= write_pins(pins_oe_q, out_data,
                                                 pinctrl_out_base_i,
                                                 pinctrl_out_count_i);
                  3'd5: begin // PC
                    pc_q <= out_data[4:0];
                  end
                  3'd6: begin // ISR
                    isr_q     <= out_data;
                    isr_cnt_q <= 6'd0;
                  end
                  3'd7: begin // EXEC — latch instruction from OSR, execute next tick
                    exec_pending_q       <= out_data[15:0];
                    exec_pending_valid_q <= 1'b1;
                  end
                  default: ;
                endcase
              end

              if (!do_stall) begin
                if (out_dst != 3'd5) begin // PC already set for OUT PC
                  if (pc_q == execctrl_wrap_top_i)
                    pc_q <= execctrl_wrap_bot_i;
                  else
                    pc_q <= pc_q + 5'd1;
                end
                delay_cnt_q <= instr_delay;
              end
            end

            // -----------------------------------------------------------
            // PUSH / PULL
            // -----------------------------------------------------------
            3'b100: begin
              if (!pp_is_pull) begin
                // PUSH
                automatic logic do_push = 1'b1;
                if (pp_if_flag && (isr_cnt_q < push_thresh))
                  do_push = 1'b0;

                if (do_push) begin
                  if (!rx_full_i) begin
                    rx_push_o <= 1'b1;
                    rx_data_o <= isr_q;
                    isr_q     <= 32'd0;
                    isr_cnt_q <= 6'd0;
                  end else if (pp_block) begin
                    do_stall = 1'b1;
                  end
                  // Non-blocking + full: no-op
                end
              end else begin
                // PULL
                automatic logic do_pull = 1'b1;
                if (pp_if_flag && !osr_empty)
                  do_pull = 1'b0;

                if (do_pull) begin
                  if (!tx_empty_i) begin
                    tx_pull_o <= 1'b1;
                    osr_q     <= tx_data_i;
                    osr_cnt_q <= 6'd0;
                  end else if (pp_block) begin
                    do_stall = 1'b1;
                  end else begin
                    // Non-blocking + empty: copy X to OSR
                    osr_q     <= x_q;
                    osr_cnt_q <= 6'd0;
                  end
                end
              end

              if (!do_stall) begin
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
                delay_cnt_q <= instr_delay;
              end
            end

            // -----------------------------------------------------------
            // MOV
            // -----------------------------------------------------------
            3'b101: begin
              // Source select
              case (mov_src)
                3'd0: mov_val = pins_i; // PINS
                3'd1: mov_val = x_q;
                3'd2: mov_val = y_q;
                3'd3: mov_val = 32'd0;  // NULL
                3'd5: mov_val = 32'd0;  // STATUS — returns 0 in Phase 1
                3'd6: mov_val = isr_q;
                3'd7: mov_val = osr_q;
                default: mov_val = 32'd0;
              endcase

              // Operation
              case (mov_op)
                2'b01: mov_val = ~mov_val;       // Invert
                2'b10: ;                           // Bit-reverse — pass through in Phase 1
                default: ;                         // None
              endcase

              // Destination select
              case (mov_dst)
                3'd0: pins_out_q <= write_pins(pins_out_q, mov_val,
                                                pinctrl_out_base_i,
                                                pinctrl_out_count_i);
                3'd1: x_q <= mov_val;
                3'd2: y_q <= mov_val;
                3'd4: begin // EXEC — latch instruction from MOV source, execute next tick
                  exec_pending_q       <= mov_val[15:0];
                  exec_pending_valid_q <= 1'b1;
                end
                3'd5: pc_q <= mov_val[4:0];   // PC
                3'd6: begin isr_q <= mov_val; isr_cnt_q <= 6'd0; end
                3'd7: osr_q <= mov_val;
                default: ;
              endcase

              if (mov_dst != 3'd5) begin
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
              end
              delay_cnt_q <= instr_delay;
            end

            // -----------------------------------------------------------
            // IRQ
            // -----------------------------------------------------------
            3'b110: begin
              if (irq_clear) begin
                irq_clr_o[irq_flag_idx] <= 1'b1;
              end else begin
                irq_set_o[irq_flag_idx] <= 1'b1;
              end

              if (irq_wait && !irq_clear) begin
                // WAIT: stall until the flag we just set gets cleared
                if (irq_flags_i[irq_flag_idx] || 1'b1) begin
                  // On set+wait, set the flag and stall.
                  // We stay in this instruction until the flag is externally cleared.
                  do_stall = 1'b1;
                  // But don't re-set the flag every tick — only set on first cycle
                  // Check if flag is already set from our previous set
                  if (irq_flags_i[irq_flag_idx]) begin
                    irq_set_o[irq_flag_idx] <= 1'b0;
                    // Still stalling — flag hasn't been cleared yet
                  end else begin
                    // Flag has been cleared by external entity — stop stalling
                    do_stall = 1'b0;
                  end
                end
              end

              if (!do_stall) begin
                if (pc_q == execctrl_wrap_top_i)
                  pc_q <= execctrl_wrap_bot_i;
                else
                  pc_q <= pc_q + 5'd1;
                delay_cnt_q <= instr_delay;
              end
            end

            // -----------------------------------------------------------
            // SET
            // -----------------------------------------------------------
            3'b111: begin
              case (set_dst)
                3'd0: pins_out_q <= write_pins(pins_out_q, {27'd0, set_data},
                                                pinctrl_set_base_i,
                                                {3'd0, pinctrl_set_count_i});
                3'd1: x_q <= {27'd0, set_data};
                3'd2: y_q <= {27'd0, set_data};
                3'd4: pins_oe_q <= write_pins(pins_oe_q, {27'd0, set_data},
                                               pinctrl_set_base_i,
                                               {3'd0, pinctrl_set_count_i});
                default: ;
              endcase

              if (pc_q == execctrl_wrap_top_i)
                pc_q <= execctrl_wrap_bot_i;
              else
                pc_q <= pc_q + 5'd1;
              delay_cnt_q <= instr_delay;
            end

            default: begin
              if (pc_q == execctrl_wrap_top_i)
                pc_q <= execctrl_wrap_bot_i;
              else
                pc_q <= pc_q + 5'd1;
            end
          endcase

          // Forced / exec_pending instruction: don't advance PC unless instr itself changes it
          if ((use_forced_q || exec_pending_valid_q) && !do_stall) begin
            // For forced/exec instructions, only JMP/OUT PC/MOV PC change PC
            // For other opcodes, PC should remain unchanged after forced/exec
            if (opcode != 3'b000 && !(opcode == 3'b011 && out_dst == 3'd5) &&
                !(opcode == 3'b101 && mov_dst == 3'd5)) begin
              pc_q <= pc_q; // Keep PC at current value
            end
          end

          // Clear exec_pending after execution (unless stalled)
          if (exec_pending_valid_q && !do_stall) begin
            exec_pending_valid_q <= 1'b0;
          end
        end // !in_delay
      end // tick
    end // !rst
  end

endmodule
