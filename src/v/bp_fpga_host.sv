/**
 *
 * Name:
 *   bp_fpga_host.sv
 *
 * Description:
 *   FPGA Host module for BlackParrot. This host consumes NBF packets sent over UART
 *   from PC Host and forwards them to BP on io_cmd_o/io_resp_i. This host can also
 *   receive minimal IO commands from BP on io_cmd_i/io_resp_o that are then forwarded
 *   to the PC Host as NBF commands over UART.
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"
`include "bp_fpga_host_defines.svh"

module bp_fpga_host
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  import bp_fpga_host_pkg::*;

  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)

    , parameter nbf_addr_width_p = paddr_width_p
    , parameter nbf_data_width_p = dword_width_gp
    , localparam nbf_width_lp = `bp_fpga_host_nbf_width(nbf_addr_width_p, nbf_data_width_p)

    , parameter uart_clk_per_bit_p = 10416 // 100 MHz clock / 9600 Baud
    , parameter uart_data_bits_p = 8 // between 5 and 9 bits
    , parameter uart_parity_bit_p = 0 // 0 or 1
    , parameter uart_parity_odd_p = 0 // 0 for even parity, 1 for odd parity
    , parameter uart_stop_bits_p = 1 // 1 or 2

    , parameter io_in_nbf_buffer_els_p = 4
    , parameter io_out_nbf_buffer_els_p = 4

    `declare_bp_bedrock_mem_if_widths(paddr_width_p, dword_width_gp, lce_id_width_p, lce_assoc_p, io)
    )
  (input                                            clk_i
   , input                                          reset_i

   // From BlackParrot
   , input [io_mem_msg_header_width_lp-1:0]         io_cmd_header_i
   , input [dword_width_gp-1:0]                     io_cmd_data_i
   , input                                          io_cmd_v_i
   , output logic                                   io_cmd_ready_and_o
   , input                                          io_cmd_last_i

   , output logic [io_mem_msg_header_width_lp-1:0]  io_resp_header_o
   , output logic [dword_width_gp-1:0]              io_resp_data_o
   , output logic                                   io_resp_v_o
   , input                                          io_resp_yumi_i
   , output logic                                   io_resp_last_o

   // To BlackParrot
   , output logic [io_mem_msg_header_width_lp-1:0]  io_cmd_header_o
   , output logic [dword_width_gp-1:0]              io_cmd_data_o
   , output logic                                   io_cmd_v_o
   , input                                          io_cmd_yumi_i
   , output logic                                   io_cmd_last_o

   , input [io_mem_msg_header_width_lp-1:0]         io_resp_header_i
   , input [dword_width_gp-1:0]                     io_resp_data_i
   , input                                          io_resp_v_i
   , output logic                                   io_resp_ready_and_o
   , input                                          io_resp_last_i

   // UART from/to PC Host
   , input                                          rx_i
   , output logic                                   tx_o

   // Error bit - typically map to FPGA LED
   , output logic                                   error_o

   );

  if(!(nbf_addr_width_p % 8 == 0))
    $fatal(0,"NBF address width must be a multiple of 8-bits");
  if(!(nbf_addr_width_p == 40))
    $fatal(0,"NBF address width must be 40-bits");
  if(!(nbf_data_width_p == 64))
    $fatal(0,"NBF data width must be 64-bits");
  if(!(uart_data_bits_p == 8))
    $fatal(0,"UART must use 8 data bits");
  if(!(uart_parity_bit_p == 0 || uart_parity_bit_p == 1))
    $fatal(0,"UART parity_bit_p must be 0 (none) or 1");
  if(!(uart_parity_odd_p == 0 || uart_parity_odd_p == 1))
    $fatal(0,"UART parity_odd_p must be 0 (even) or 1 (odd)");
  if(!(uart_stop_bits_p == 1 || uart_stop_bits_p == 2))
    $fatal(0,"Invalid UART stop bits setting. Must be 1 or 2.");
  if(!(nbf_width_lp % uart_data_bits_p == 0))
    $fatal(0,"uart data bits must be even divisor of NBF packet width");

  `declare_bp_fpga_host_nbf_s(nbf_addr_width_p, nbf_data_width_p);

  bp_fpga_host_nbf_s nbf_lo;
  wire nbf_v_lo, nbf_ready_and_li;

  bp_fpga_host_io_in
   #(.bp_params_p(bp_params_p)
     ,.nbf_addr_width_p(nbf_addr_width_p)
     ,.nbf_data_width_p(nbf_data_width_p)
     ,.uart_clk_per_bit_p(uart_clk_per_bit_p)
     ,.uart_data_bits_p(uart_data_bits_p)
     ,.uart_parity_bit_p(uart_parity_bit_p)
     ,.uart_parity_odd_p(uart_parity_odd_p)
     ,.uart_stop_bits_p(uart_stop_bits_p)
     ,.nbf_buffer_els_p(io_in_nbf_buffer_els_p)
     )
    host_io_in
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.io_cmd_header_o(io_cmd_header_o)
     ,.io_cmd_data_o(io_cmd_data_o)
     ,.io_cmd_v_o(io_cmd_v_o)
     ,.io_cmd_yumi_i(io_cmd_yumi_i)
     ,.io_cmd_last_o(io_cmd_last_o)
     ,.io_resp_header_i(io_resp_header_i)
     ,.io_resp_data_i(io_resp_data_i)
     ,.io_resp_v_i(io_resp_v_i)
     ,.io_resp_ready_and_o(io_resp_ready_and_o)
     ,.io_resp_last_i(io_resp_last_i)
     ,.rx_i(rx_i)
     ,.nbf_o(nbf_lo)
     ,.nbf_v_o(nbf_v_lo)
     ,.nbf_ready_and_i(nbf_ready_and_li)
     ,.error_o(error_o)
     );

  bp_fpga_host_io_out
   #(.bp_params_p(bp_params_p)
     ,.nbf_addr_width_p(nbf_addr_width_p)
     ,.nbf_data_width_p(nbf_data_width_p)
     ,.uart_clk_per_bit_p(uart_clk_per_bit_p)
     ,.uart_data_bits_p(uart_data_bits_p)
     ,.uart_parity_bit_p(uart_parity_bit_p)
     ,.uart_parity_odd_p(uart_parity_odd_p)
     ,.uart_stop_bits_p(uart_stop_bits_p)
     ,.nbf_buffer_els_p(io_out_nbf_buffer_els_p)
     )
    host_io_out
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.io_cmd_header_i(io_cmd_header_i)
     ,.io_cmd_data_i(io_cmd_data_i)
     ,.io_cmd_v_i(io_cmd_v_i)
     ,.io_cmd_ready_and_o(io_cmd_ready_and_o)
     ,.io_cmd_last_i(io_cmd_last_i)
     ,.io_resp_header_o(io_resp_header_o)
     ,.io_resp_data_o(io_resp_data_o)
     ,.io_resp_v_o(io_resp_v_o)
     ,.io_resp_yumi_i(io_resp_yumi_i)
     ,.io_resp_last_o(io_resp_last_o)
     ,.tx_o(tx_o)
     ,.nbf_i(nbf_lo)
     ,.nbf_v_i(nbf_v_lo)
     ,.nbf_ready_and_o(nbf_ready_and_li)
     );

 endmodule
