# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado synthesis script for OpenSoC on Basys 3 (XC7A35T-1CPG236C)
#
# Prerequisites:
#   Run FuseSoC setup first:
#     make synth-setup
#
# Usage:
#   make synth                  # full flow (setup + synthesis)
#   vivado -mode batch -source hw/fpga/basys3/synth.tcl   # Vivado only

# ============================================================================
# Configuration — derive repo root from this script's location
# ============================================================================
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set REPO_ROOT   [file normalize $SCRIPT_DIR/../../..]

set PART        xc7a35tcpg236-1
set TOP         opensoc_fpga_top
set PROJ_NAME   opensoc_basys3
set PROJ_DIR    $REPO_ROOT/build/vivado
set SRC_DIR     $REPO_ROOT/build/opensoc_fpga_basys3_0/synth-vivado/src
set XDC_FILE    $REPO_ROOT/hw/fpga/basys3/basys3.xdc

# ============================================================================
# Verify FuseSoC setup has been run
# ============================================================================
if {![file exists $SRC_DIR]} {
    puts "ERROR: Source directory '$SRC_DIR' not found."
    puts "Run FuseSoC setup first:  make synth-setup"
    return -code error "FuseSoC setup required"
}

# ============================================================================
# Create project
# ============================================================================
create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language Verilog [current_project]

# ============================================================================
# Verilog defines
# ============================================================================
set VLOG_DEFINES "SYNTHESIS=1 FPGA_XILINX=1"
append VLOG_DEFINES " RegFile=ibex_pkg::RegFileFPGA"
append VLOG_DEFINES " PRIM_DEFAULT_IMPL=prim_pkg::ImplGeneric"

set_property verilog_define $VLOG_DEFINES [current_fileset]

# ============================================================================
# Include directories (for .svh headers)
# ============================================================================
set INC_DIRS [list \
    $SRC_DIR/lowrisc_prim_assert_0.1/rtl \
    $SRC_DIR/lowrisc_prim_secded_0.1/rtl \
    $SRC_DIR/lowrisc_prim_util_get_scramble_params_0/rtl \
    $SRC_DIR/lowrisc_prim_util_memload_0/rtl \
    $SRC_DIR/lowrisc_dv_dv_fcov_macros_0 \
    $SRC_DIR/pulp-platform.org__axi_0.39.9/include \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/include \
]

# ============================================================================
# Source files — packages first (order matters for elaboration)
# ============================================================================
set PKG_FILES [list \
    $SRC_DIR/lowrisc_prim_generic_prim_pkg_0/rtl/prim_pkg.sv \
    $SRC_DIR/lowrisc_prim_util_0.1/rtl/prim_util_pkg.sv \
    $SRC_DIR/lowrisc_prim_generic_ram_1p_pkg_0/rtl/prim_ram_1p_pkg.sv \
    $SRC_DIR/lowrisc_prim_generic_ram_2p_pkg_0/rtl/prim_ram_2p_pkg.sv \
    $SRC_DIR/lowrisc_prim_generic_rom_pkg_0/rtl/prim_rom_pkg.sv \
    $SRC_DIR/lowrisc_prim_pad_wrapper_pkg_0/rtl/prim_pad_wrapper_pkg.sv \
    $SRC_DIR/lowrisc_prim_secded_0.1/rtl/prim_secded_pkg.sv \
    $SRC_DIR/lowrisc_prim_mubi_pkg_0.1/rtl/prim_mubi_pkg.sv \
    $SRC_DIR/lowrisc_prim_cipher_pkg_0.1/rtl/prim_cipher_pkg.sv \
    $SRC_DIR/lowrisc_prim_count_0/rtl/prim_count_pkg.sv \
    $SRC_DIR/lowrisc_ibex_ibex_pkg_0.1/rtl/ibex_pkg.sv \
    $SRC_DIR/lowrisc_ibex_ibex_tracer_0.1/rtl/ibex_tracer_pkg.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/cf_math_pkg.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/ecc_pkg.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/cb_filter_pkg.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/cdc_reset_ctrlr_pkg.sv \
    $SRC_DIR/pulp-platform.org__axi_0.39.9/src/axi_pkg.sv \
]

# ============================================================================
# Source files — all remaining RTL (glob from FuseSoC build directory)
# ============================================================================
# Collect all .sv files, then remove packages (already listed above) and
# header-only files (.svh are handled via includes, prim_assert.sv is
# include-only).  The prim_flop_macros.sv is also include-only.
set ALL_SV [glob -nocomplain \
    $SRC_DIR/lowrisc_prim_assert_0.1/rtl/prim_assert.sv \
    $SRC_DIR/lowrisc_prim_assert_0.1/rtl/prim_flop_macros.sv \
    $SRC_DIR/lowrisc_ibex_ibex_core_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_ibex_ibex_icache_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_ibex_ibex_top_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_ibex_ibex_top_tracing_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_ibex_ibex_tracer_0.1/rtl/ibex_tracer.sv \
    $SRC_DIR/lowrisc_ibex_sim_shared_0/rtl/*.sv \
    $SRC_DIR/lowrisc_ibex_sim_shared_0/rtl/sim/*.sv \
    $SRC_DIR/lowrisc_prim_cdc_rand_delay_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_cipher_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_count_0/rtl/prim_count.sv \
    $SRC_DIR/lowrisc_prim_generic_and2_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_buf_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_clock_buf_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_clock_div_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_clock_gating_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_clock_inv_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_clock_mux2_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_flop_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_flop_2sync_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_flop_en_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_flop_no_rst_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_pad_attr_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_pad_wrapper_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_ram_1p_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_ram_1r1w_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_ram_2p_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_rom_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_rst_sync_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_usb_diff_rx_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_xnor2_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_generic_xor2_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_lfsr_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_mubi_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_onehot_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_onehot_check_0/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_ram_1p_adv_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_ram_1p_scr_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_sec_anchor_0.1/rtl/*.sv \
    $SRC_DIR/lowrisc_prim_secded_0.1/rtl/*.sv \
    $SRC_DIR/pulp-platform.org__axi_0.39.9/src/*.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/*.sv \
    $SRC_DIR/pulp-platform.org__common_cells_1.39.0/src/deprecated/*.sv \
    $SRC_DIR/opensoc_ip_pio_0/rtl/*.sv \
    $SRC_DIR/opensoc_ip_relu_accel_0/rtl/*.sv \
    $SRC_DIR/opensoc_ip_sg_dma_0/rtl/*.sv \
    $SRC_DIR/opensoc_ip_softmax_0/rtl/*.sv \
    $SRC_DIR/opensoc_ip_vec_mac_0/rtl/*.sv \
    $SRC_DIR/opensoc_soc_opensoc_top_0/rtl/*.sv \
    $SRC_DIR/opensoc_fpga_basys3_0/fpga/basys3/*.sv \
]

# Remove package files from ALL_SV (they are already in PKG_FILES)
set PKG_SET [list]
foreach f $PKG_FILES { lappend PKG_SET [file normalize $f] }

set RTL_FILES [list]
foreach f $ALL_SV {
    set fn [file normalize $f]
    if {[lsearch -exact $PKG_SET $fn] == -1} {
        # Skip .svh files that slipped through
        if {[string match "*.svh" $fn]} continue
        lappend RTL_FILES $f
    }
}

# ============================================================================
# Add files to project
# ============================================================================
# Packages (order-sensitive)
add_files -norecurse $PKG_FILES
set_property file_type SystemVerilog [get_files $PKG_FILES]

# RTL modules
add_files -norecurse $RTL_FILES
set_property file_type SystemVerilog [get_files $RTL_FILES]

# Include paths
set_property include_dirs $INC_DIRS [current_fileset]

# Constraints
add_files -fileset constrs_1 -norecurse $XDC_FILE

# Top module
set_property top $TOP [current_fileset]

# ============================================================================
# Synthesis (in-process — reliable in batch mode, unlike launch_runs)
# ============================================================================
puts "=========================================="
puts " Running Synthesis..."
puts "=========================================="
synth_design -top $TOP -part $PART
write_checkpoint -force $PROJ_DIR/post_synth.dcp
report_utilization -file $PROJ_DIR/post_synth_utilization.txt
report_timing_summary -file $PROJ_DIR/post_synth_timing.txt
puts ""
puts "Post-synthesis reports:"
puts "  $PROJ_DIR/post_synth_utilization.txt"
puts "  $PROJ_DIR/post_synth_timing.txt"

# ============================================================================
# Implementation (place & route)
# ============================================================================
puts "=========================================="
puts " Running Place & Route..."
puts "=========================================="
opt_design
place_design
route_design
write_checkpoint -force $PROJ_DIR/post_route.dcp
report_utilization -file $PROJ_DIR/post_route_utilization.txt
report_timing_summary -file $PROJ_DIR/post_route_timing.txt
puts ""
puts "Post-route reports:"
puts "  $PROJ_DIR/post_route_utilization.txt"
puts "  $PROJ_DIR/post_route_timing.txt"

# ============================================================================
# Bitstream generation
# ============================================================================
puts "=========================================="
puts " Generating Bitstream..."
puts "=========================================="
write_bitstream -force $PROJ_DIR/$PROJ_NAME.bit

puts "=========================================="
puts " SUCCESS: Bitstream generated"
puts " $PROJ_DIR/$PROJ_NAME.bit"
puts "=========================================="
