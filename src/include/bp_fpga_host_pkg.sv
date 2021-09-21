/*
 * bp_fpga_host_pkg.sv
 *
 * Contains the FPGA Host to PC Host NBF structures.
 *
 */

 package bp_fpga_host_pkg;

  `include "bp_fpga_host_pkgdef.svh"

  // default value of control register
  localparam fpga_host_ctrl_gp = 32'h0000_0000;

 endpackage
