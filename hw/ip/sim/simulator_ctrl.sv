// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Module for communicating with the simulator that interfaces via the memory
 * system.
 *
 * Contains two registers
 *
 * * 0x0 - CHAR_OUT_ADDR - [7:0] of write data output via output_char DPI call
 * and SimOutputManager (see dv/common/cpp/sim_output_manager.cc)
 *
 * * 0x8 - SIM_CTRL_ADDR - Write to halt sim.
 *   bit  [0]    : halt trigger (must be 1)
 *   bits [31:1] : failure count (0 = pass, >0 = fail)
 *
 * The slightly odd spacing is because we also use SIM_CTRL_ADDR when
 * simulating simple_system code with Spike, which requires the address to be
 * 64-bit aligned.
 *
 */

module simulator_ctrl #(
  // passed to simulator via log_name of output_char DPI call
  parameter string LogName = "ibex_out.log",
  // If set flush on every char (useful for monitoring output whilst
  // simulation is running).
  parameter bit    FlushOnChar = 1
) (
  input               clk_i,
  input               rst_ni,

  input               req_i,
  input               we_i,
  input        [ 3:0] be_i,
  input        [31:0] addr_i,
  input        [31:0] wdata_i,
  output logic        rvalid_o,
  output logic [31:0] rdata_o
);

  // Propagate failure count to the Verilator C++ harness via DPI.
  // The harness sets simulation_success accordingly before exiting.
  import "DPI-C" function void dpi_sim_finish(int unsigned failures);

  localparam logic [7:0] CHAR_OUT_ADDR = 8'h0;
  localparam logic [7:0] SIM_CTRL_ADDR = 8'h2;

  logic [7:0]  ctrl_addr;
  logic [2:0]  sim_finish;
  logic [30:0] fail_count_q;

  integer log_fd;

  initial begin
    log_fd = $fopen(LogName, "w");
  end

  final begin
    $fclose(log_fd);
  end

  assign ctrl_addr = addr_i[9:2];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      rvalid_o    <= 0;
      sim_finish  <= 'b0;
      fail_count_q <= '0;
    end else begin
      // Immediately respond to any request
      rvalid_o <= req_i;

      if (req_i & we_i) begin
        case (ctrl_addr)
          CHAR_OUT_ADDR: begin
            if (be_i[0]) begin
              $fwrite(log_fd, "%c", wdata_i[7:0]);

              if(FlushOnChar) begin
                $fflush(log_fd);
              end
            end
          end
          SIM_CTRL_ADDR: begin
            if ((be_i[0] & wdata_i[0]) && (sim_finish == 'b0)) begin
              $display("Terminating simulation by software request.");
              fail_count_q <= wdata_i[31:1];
              sim_finish   <= 3'b001;
            end
          end
          default: ;
        endcase
      end
    end

    if (sim_finish != 'b0) begin
      sim_finish <= sim_finish + 1;
    end
    if (sim_finish >= 3'b010) begin
      dpi_sim_finish({1'b0, fail_count_q});
    end
  end

  assign rdata_o = '0;
endmodule
