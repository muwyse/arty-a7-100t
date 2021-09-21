/**
 *
 * Name:
 *   bp_bedrock_to_axi4_lite.sv
 *
 * Description:
 *   This module consumes BedRock commands and generates AXI4 Lite commands, then consumes the AXI4
 *   Lite responses and sends BedRock responses.
 *
 *
 */

`include "bp_common_defines.svh"

module bp_bedrock_to_axi4_lite
 import bp_common_pkg::*;

 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_bedrock_mem_if_widths(paddr_width_p, dword_width_gp, lce_id_width_p, lce_assoc_p, io)
   , parameter axi_addr_width_p = 28
   , parameter axi_data_width_p = 64
   , parameter axi_wstrb_width_p = (axi_data_width_p/8)
   )
  (input                                        clk_i
   , input                                      reset_i
   // AXI
   // read address
   , output logic [axi_addr_width_p-1:0]        araddr_o
   , output logic [2:0]                         arprot_o
   , input                                      arready_i
   , output logic                               arvalid_o
   // read data
   , input [axi_data_width_p-1:0]               rdata_i
   , output logic                               rready_o
   , output logic [1:0]                         rresp_o
   , input                                      rvalid_i

   // write address
   , output logic [axi_addr_width_p-1:0]        awaddr_o
   , output logic [2:0]                         awprot_o
   , input                                      awready_i
   , output logic                               awvalid_o
   // write data
   , output logic [axi_data_width_p-1:0]        wdata_o
   , input                                      wready_i
   , output logic [axi_wstrb_width_p-1:0]       wstrb_o
   , output logic                               wvalid_o
   // write response
   , output logic                               bready_o
   , input [1:0]                                bresp_i
   , input                                      bvalid_i

   // Commands from BedRock
   , input [io_mem_msg_header_width_lp-1:0]         io_cmd_header_i
   , input [dword_width_gp-1:0]                     io_cmd_data_i
   , input                                          io_cmd_v_i
   , output logic                                   io_cmd_yumi_o
   , input                                          io_cmd_last_i

   , output logic [io_mem_msg_header_width_lp-1:0]  io_resp_header_o
   , output logic [dword_width_gp-1:0]              io_resp_data_o
   , output logic                                   io_resp_v_o
   , input                                          io_resp_ready_and_i
   , output logic                                   io_resp_last_o

   // error signals - routed to LEDs
   , output logic                               rd_error_o
   , output logic                               wr_error_o
   );

  // error bits - sticky bits that stay set if any error occurs
  logic rd_error_r, rd_error_n;
  assign rd_error_o = rd_error_r;
  logic wr_error_r, wr_error_n;
  assign wr_error_o = wr_error_r;
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      rd_error_r <= '0;
      wr_error_r <= '0;
    end else begin
      rd_error_r <= rd_error_r | rd_error_n;
      wr_error_r <= wr_error_r | wr_error_n;
    end
  end

  `declare_bp_bedrock_mem_if(paddr_width_p, dword_width_gp, lce_id_width_p, lce_assoc_p, io);

  // TODO: add FIFO for command headers to support pipelined access to AXI channel
  bp_bedrock_io_mem_msg_header_s io_cmd, io_resp_r, io_resp_n;
  assign io_cmd = io_cmd_header_i;
  wire io_cmd_read_v = io_cmd_v_i & (io_cmd.msg_type.mem == e_bedrock_mem_uc_rd);
  wire io_cmd_write_v = io_cmd_v_i & (io_cmd.msg_type.mem == e_bedrock_mem_uc_wr);
  assign io_resp_header_o = io_resp_r;

  // unused - only single beat messages (<= 8-bytes data)
  wire unused = io_cmd_last_i;
  // stub - only single beat messages (<= 8-bytes data)
  assign io_resp_last_o = io_resp_v_o;

  logic [axi_data_width_p-1:0] axi_wr_data_r, axi_wr_data_n;

  typedef enum logic [2:0]
  {
    e_reset
    ,e_ready
    ,e_send_data
    ,e_write_response
    ,e_read_response
    ,e_error
  } state_e;
  state_e state_r, state_n;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      state_r <= e_reset;
      axi_wr_data_r <= '0;
      io_resp_r <= '0;
    end else begin
      state_r <= state_n;
      axi_wr_data_r <= axi_wr_data_n;
      io_resp_r <= io_resp_n;
    end
  end

  always_comb begin
    rd_error_n = 1'b0;

    state_n = state_r;
    axi_wr_data_n = axi_wr_data_r;
    io_resp_n = io_resp_r;

    // from IO command
    io_cmd_yumi_o = 1'b0;

    // to axi - write address
    awaddr_o = io_cmd.addr[0+:axi_addr_width_p];
    awprot_o = 3'b011;
    awvalid_o = 1'b0;

    // to axi - write data
    wdata_o = axi_wr_data_r;
    wstrb_o = '1;
    wvalid_o = 1'b0;

    // from axi - always accept write responses
    bready_o = 1'b1;
    wr_error_n = (bvalid_i & bready_o) & ((bresp_i == 2'b10) || (bresp_i == 2'b11));

    // to axi - read address
    araddr_o = io_cmd.addr[0+:axi_addr_width_p];
    arprot_o = 3'b011;
    arvalid_o = 1'b0;

    // from axi - read data
    io_resp_n = '0;
    io_resp_data_o = rdata_i;
    io_resp_v_o = 1'b0;
    rready_o = 1'b0;

    unique case(state_r)
      e_reset: begin
        state_n = e_ready;
      end
      e_ready: begin
        axi_wr_data_n = '0;
        if (io_cmd_read_v) begin
          arvalid_o = 1'b1;
          io_cmd_yumi_o = arready_i;
          state_n = io_cmd_yumi_o ? e_read_response : e_ready;
          io_resp_n = io_cmd;
        end else if (io_cmd_write_v) begin
          axi_wr_data_n = io_cmd_data_i;
          awvalid_o = 1'b1;
          io_cmd_yumi_o = awready_i;
          state_n = io_cmd_yumi_o ? e_write_response : e_ready;
          io_resp_n = io_cmd;
        end else begin
          state_n = state_r;
        end
      end
      e_send_data: begin
        wvalid_o = 1'b1;
        state_n = (wvalid_o & wready_i) ? e_write_response : e_send_data;
      end
      e_write_response: begin
        axi_wr_data_n = '0;
        // send io response
        io_resp_v_o = bvalid_i;
        bready_o = io_resp_ready_and_i;
      end
      e_read_response: begin
        // send io response
        rready_o = io_resp_ready_and_i;
        io_resp_v_o = rvalid_i;
      end
      default: begin
        state_n = e_reset;
      end
    endcase
  end

endmodule
