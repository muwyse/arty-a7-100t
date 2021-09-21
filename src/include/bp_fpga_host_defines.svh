`ifndef BP_FPGA_HOST_DEFINES_SVH
`define BP_FPGA_HOST_DEFINES_SVH

  /*
   * FPGA Host NBF Packet
   *
   * When sending over UART, bytes are transmitted LSB to MSB
   * - opcode, then addr (LSB to MSB), then data (LSB to MSB)
   *
   */
  `define declare_bp_fpga_host_nbf_s(addr_width_mp, data_width_mp) \
    typedef struct packed                                          \
    {                                                              \
      logic [data_width_mp-1:0]   data;                            \
      logic [addr_width_mp-1:0]   addr;                            \
      bp_fpga_host_nbf_opcode_e   opcode;                          \
    } bp_fpga_host_nbf_s

  `define bp_fpga_host_nbf_width(addr_width_mp, data_width_mp) \
    ($bits(bp_fpga_host_nbf_opcode_e)+addr_width_mp+data_width_mp)

  `define FPGA_HOST_CTRL_ADDR_WR_RESP 3'b000
  `define FPGA_HOST_CTRL_ADDR_RD_ERROR 3'b001
  `define FPGA_HOST_CTRL_ADDR_WR_ERROR 3'b010

`endif
