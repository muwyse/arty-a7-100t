`ifndef BP_FPGA_HOST_PKGDEF_SVH
`define BP_FPGA_HOST_PKGDEF_SVH

  /*
   * FPGA Host NBF Commands
   *
   * These NBF commands encompass the minimal IO supported between the PC Host
   * and the FPGA Host attached to BlackParrot.
   *
   * Every command sent from PC to FPGA and response from FPGA to PC
   * has opcode, address, and data fields. Address and data fields are set to 0 if
   * message does not explicitly use those fields.
   *
   */
  typedef enum logic [7:0]
  {
    // From PC to FPGA

    // Write 2^N bytes to physical memory
    // address = store address, data = zero-padded store data
    // FPGA replies with the same command, but with all-zero data field
    e_fpga_host_nbf_write_4     = 8'b0000_0010 // Write 4 bytes
    ,e_fpga_host_nbf_write_8    = 8'b0000_0011 // Write 8 bytes

    // Read 2^N bytes from physical memory
    // FPGA replies with address = load address, data = zero-padded load data
    ,e_fpga_host_nbf_read_4     = 8'b0001_0010 // Read 4 bytes
    ,e_fpga_host_nbf_read_8     = 8'b0001_0011 // Read 8 bytes

    // FPGA Host Control Register Manipulation
    // FPGA Host replies with same opcode for commands that produce responses
    ,e_fpga_host_ctrl_set        = 8'b0100_0000 // Set bits indicated by one-hot address mask
    ,e_fpga_host_ctrl_clear      = 8'b0100_0001 // Clear bits indicated by one-hot address mask
    ,e_fpga_host_ctrl_write      = 8'b0100_0010 // Write control register using address as mask and data as values
    ,e_fpga_host_ctrl_read       = 8'b0100_0011 // Read control register and send response to PC Host in data

    // From FPGA to PC

    // core finished signal
    // address = core ID, data = 0
    ,e_fpga_host_nbf_core_done  = 8'b1000_0000 // Core finished

    // error
    // address = core ID if reporting error specific to a core
    // address = 0x111...1 if reporting error from FPGA Host
    // data = optional error code, data, or message, else 0
    ,e_fpga_host_nbf_error      = 8'b1000_0001 // Error from FPGA

    // Character output from BlackParrot / FPGA Host
    // address = core ID or 0x111...1 for FPGA Host / global
    // data[0+:8] = ascii character
    ,e_fpga_host_nbf_putch      = 8'b1000_0010 // Put Char from FPGA

    // To FPGA with ack back to PC

    // NBF loading commands
    // Command and Response has address = 0, data = 0
    ,e_fpga_host_nbf_fence      = 8'b1111_1110 // NBF Fence - fence the io_cmd_o/io_resp_i at FPGA Host
    ,e_fpga_host_nbf_finish     = 8'b1111_1111 // Finish NBF load to FPGA

  } bp_fpga_host_nbf_opcode_e;

  // FPGA Host Control Register Definition
  typedef struct packed {
    // Should NBF write commands generate NBF responses to Host PC - 1 enable, 0 disable
    logic wr_resp;
    // Write error detected since last control register read
    logic wr_error;
    // Read error detected since last control register read
    logic rd_error;
  } fpga_host_ctrl_s;

`endif
