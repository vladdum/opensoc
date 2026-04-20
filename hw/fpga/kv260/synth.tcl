# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Vivado synthesis script for OpenSoC on KV260 (xck26-sfvc784-2LV-c)
#
# Prerequisites:
#   Run FuseSoC setup first:
#     make synth FLOW=fpga-kv260 (runs setup automatically)
#
# Usage:
#   make synth FLOW=fpga-kv260              # full flow (setup + synthesis)
#   vivado -mode batch -source hw/fpga/kv260/synth.tcl   # Vivado only

# ============================================================================
# Configuration — derive repo root from this script's location
# ============================================================================
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set REPO_ROOT   [file normalize $SCRIPT_DIR/../../..]

set PART        xck26-sfvc784-2LV-c
set TOP         opensoc_fpga_kv260_top
set PROJ_NAME   opensoc_kv260
set PROJ_DIR    $REPO_ROOT/build/vivado_kv260
set SRC_DIR     $REPO_ROOT/build/opensoc_fpga_kv260_0/synth-kv260-vivado/src
set XDC_FILE    $REPO_ROOT/hw/fpga/kv260/kv260.xdc
set FILELIST    $REPO_ROOT/hw/synth/sources.f

# ============================================================================
# Clock frequency — single source of truth
# ============================================================================
set CLK_FREQ_MHZ 200
set CLK_PERIOD   [expr {1000.0 / $CLK_FREQ_MHZ}]

# ============================================================================
# Verify FuseSoC setup has been run
# ============================================================================
if {![file exists $SRC_DIR]} {
    puts "ERROR: Source directory '$SRC_DIR' not found."
    puts "Run FuseSoC setup first:  make synth FLOW=fpga-kv260"
    return -code error "FuseSoC setup required"
}

# ============================================================================
# Read shared filelist (sections: includes, packages, rtl)
# ============================================================================
proc read_filelist {filepath section prefix} {
    set in_section 0
    set result [list]
    set fd [open $filepath r]
    while {[gets $fd line] >= 0} {
        regsub {#.*$} $line {} line
        set line [string trim $line]
        if {$line eq ""} continue
        if {[regexp {^\[(.+)\]$} $line -> sec]} {
            set in_section [expr {$sec eq $section}]
            continue
        }
        if {$in_section} { lappend result $prefix/$line }
    }
    close $fd
    return $result
}

# ============================================================================
# Create project
# ============================================================================
create_project $PROJ_NAME $PROJ_DIR -part $PART -force
set_property target_language Verilog [current_project]

# ============================================================================
# Zynq UltraScale+ PS IP — provides pl_clk0 and pl_resetn0
# ============================================================================
set ps_vlnv [lindex [get_ipdefs -filter "NAME == zynq_ultra_ps_e"] 0]
create_ip -vlnv $ps_vlnv -module_name zynq_ultra_ps_e_0
set_property -dict {
    CONFIG.PSU__FPGA_PL0_ENABLE  {1}
    CONFIG.PSU__USE__M_AXI_GP0   {0}
    CONFIG.PSU__USE__M_AXI_GP1   {0}
    CONFIG.PSU__USE__M_AXI_GP2   {0}
    CONFIG.PSU__USE__S_AXI_GP0   {0}
    CONFIG.PSU__USE__S_AXI_GP1   {0}
    CONFIG.PSU__USE__S_AXI_GP2   {0}
    CONFIG.PSU__USE__S_AXI_GP3   {0}
} [get_ips zynq_ultra_ps_e_0]
# Variable substitution requires a separate set_property (braces inhibit it)
set_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $CLK_FREQ_MHZ [get_ips zynq_ultra_ps_e_0]
generate_target {all} [get_ips zynq_ultra_ps_e_0]
# Include PS IP RTL in top-level synthesis (not OOC DCP) so synth_design finds the module
set_property SYNTH_CHECKPOINT_MODE None [get_files zynq_ultra_ps_e_0.xci]

# ============================================================================
# Verilog defines
# Note: no board-specific define beyond FPGA_XILINX — derived config pkg selects
#       opensoc_config_pkg (all accelerators, 512 KB RAM, CUT_ALL_PORTS).
# ============================================================================
set VLOG_DEFINES "SYNTHESIS=1 FPGA_XILINX=1"

set_property verilog_define $VLOG_DEFINES [current_fileset]

# ============================================================================
# Include directories (for .svh headers)
# ============================================================================
set INC_DIRS [read_filelist $FILELIST includes $SRC_DIR]
set_property include_dirs $INC_DIRS [current_fileset]

# ============================================================================
# Source files — packages first (order matters for elaboration)
# ============================================================================
set PKG_FILES [read_filelist $FILELIST packages $SRC_DIR]
# Kronos package must precede Kronos RTL in elaboration order
lappend PKG_FILES $SRC_DIR/opensoc_ip_kronos_riscv_0/rtl/kronos_pkg.sv

# ============================================================================
# Source files — RTL (expand globs, add FPGA wrapper)
# ============================================================================
set rtl_patterns [read_filelist $FILELIST rtl $SRC_DIR]
# FPGA-only: add the board wrapper
lappend rtl_patterns $SRC_DIR/opensoc_fpga_kv260_0/hw/fpga/kv260/*.sv
lappend rtl_patterns $SRC_DIR/opensoc_ip_sim_shared_0/*.sv

set ALL_SV [list]
foreach pat $rtl_patterns {
    set ALL_SV [concat $ALL_SV [glob -nocomplain $pat]]
}

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

# Constraints (pin assignments only — clock constraint applied below)
add_files -fileset constrs_1 -norecurse $XDC_FILE

# Kronos timing constraints (multicycle paths for branch comparator)
set KRONOS_XDC $SRC_DIR/opensoc_ip_kronos_riscv_0/rtl/stage5/kronos_kv260.xdc
if {[file exists $KRONOS_XDC]} {
    add_files -fileset constrs_1 -norecurse $KRONOS_XDC
} else {
    puts "WARNING: Kronos XDC not found at $KRONOS_XDC — multicycle constraints not applied"
}

# Clock constraint — derived from CLK_FREQ_MHZ defined at top of this script
set clk_xdc [file join $PROJ_DIR clk.xdc]
set fd [open $clk_xdc w]
puts $fd "create_clock -period $CLK_PERIOD -name clk_i \[get_pins clk_buf_i/O\]"
close $fd
add_files -fileset constrs_1 -norecurse $clk_xdc

# Top module
set_property top $TOP [current_fileset]

# ============================================================================
# Helper: extract WNS from timing summary, return numeric value
# ============================================================================
proc get_wns {} {
    set rpt [report_timing_summary -return_string -quiet]
    if {[regexp {WNS\(ns\)\s+TNS\(ns\).*?\n\s*(-?[0-9.]+)} $rpt -> wns]} {
        return $wns
    }
    return "N/A"
}

# ============================================================================
# Synthesis (in-process — reliable in batch mode, unlike launch_runs)
# ============================================================================
puts "=========================================="
puts " Running Synthesis..."
puts "=========================================="
set t0 [clock seconds]
set_property XPM_LIBRARIES XPM_MEMORY [current_project]
if {[catch {synth_design -top $TOP -part $PART -retiming} err]} {
    puts "ERROR: synth_design failed: $err"
    return -code error "Synthesis failed"
}
set dt [expr {[clock seconds] - $t0}]
puts [format "  Synthesis completed in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]

write_checkpoint -force $PROJ_DIR/post_synth.dcp
report_utilization -file $PROJ_DIR/post_synth_utilization.txt
report_timing_summary -file $PROJ_DIR/post_synth_timing.txt

set synth_wns [get_wns]
puts ""
puts "Post-synthesis reports:"
puts "  $PROJ_DIR/post_synth_utilization.txt"
puts "  $PROJ_DIR/post_synth_timing.txt"
puts "  WNS (estimated): ${synth_wns} ns"

# ============================================================================
# Implementation (optimize → place → physical optimize → route)
# ============================================================================
puts "=========================================="
puts " Running Place & Route..."
puts "=========================================="
set t0 [clock seconds]

if {[catch {opt_design} err]} {
    puts "ERROR: opt_design failed: $err"
    return -code error "Logic optimization failed"
}

if {[catch {place_design} err]} {
    puts "ERROR: place_design failed: $err"
    return -code error "Placement failed"
}

# Physical optimization after placement — recovers timing on critical paths
if {[catch {phys_opt_design} err]} {
    puts "WARNING: phys_opt_design failed: $err (continuing)"
}

if {[catch {route_design} err]} {
    puts "ERROR: route_design failed: $err"
    return -code error "Routing failed"
}

set dt [expr {[clock seconds] - $t0}]
puts [format "  Place & route completed in %d:%02d" [expr {$dt/60}] [expr {$dt%60}]]

write_checkpoint -force $PROJ_DIR/post_route.dcp
report_utilization -file $PROJ_DIR/post_route_utilization.txt
report_timing_summary -file $PROJ_DIR/post_route_timing.txt
puts ""
puts "Post-route reports:"
puts "  $PROJ_DIR/post_route_utilization.txt"
puts "  $PROJ_DIR/post_route_timing.txt"

# ============================================================================
# Timing closure check
# ============================================================================
set route_wns [get_wns]
puts ""
if {$route_wns ne "N/A"} {
    set fmax_mhz [format "%.1f" [expr {1000.0 / ($CLK_PERIOD - $route_wns)}]]
    if {$route_wns < 0} {
        puts "WARNING: Timing NOT met — WNS = ${route_wns} ns"
        puts "  Max achievable frequency: ${fmax_mhz} MHz (target: ${CLK_FREQ_MHZ}.0 MHz)"
        puts "  Review: $PROJ_DIR/post_route_timing.txt"
    } else {
        puts "Timing met — WNS = ${route_wns} ns"
        puts "  Max achievable frequency: ${fmax_mhz} MHz (target: ${CLK_FREQ_MHZ}.0 MHz)"
    }
} else {
    puts "WARNING: Could not extract WNS from timing report"
}

# ============================================================================
# Bitstream generation
# ============================================================================
puts "=========================================="
puts " Generating Bitstream..."
puts "=========================================="
if {[catch {write_bitstream -force $PROJ_DIR/$PROJ_NAME.bit} err]} {
    puts "ERROR: write_bitstream failed: $err"
    return -code error "Bitstream generation failed"
}

puts "=========================================="
puts " SUCCESS: Bitstream generated"
puts " $PROJ_DIR/$PROJ_NAME.bit"
puts "=========================================="
