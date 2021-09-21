/**
 *
 * Name:
 *   bp_cache_dma_to_axi4_lite.sv
 *
 * Description:
 *   This module consumes a bsg_cache DMA interface and produces an AXI4 Lite Manager interface.
 *
 *   A dma packet arrives and then N AXI4 Lite packets are sent. N = 8 (64 bits * 8 = 512 bit cache blocks)
 *
 *
 */

`include "bp_common_defines.svh"
`include "bsg_cache.vh"
module bp_cache_dma_to_axi4_lite
 import bp_common_pkg::*;
 import bsg_cache_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   , localparam dma_pkt_width_lp = `bsg_cache_dma_pkt_width(daddr_width_p)
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

   // DMA
   , input [dma_pkt_width_lp-1:0]               dma_pkt_i
   , input                                      dma_pkt_v_i
   , output logic                               dma_pkt_yumi_o

   , output logic [l2_fill_width_p-1:0]         dma_data_o
   , output logic                               dma_data_v_o
   , input                                      dma_data_ready_and_i

   , input [l2_fill_width_p-1:0]                dma_data_i
   , input                                      dma_data_v_i
   , output logic                               dma_data_yumi_o

   // error signals - routed to LEDs
   , output logic                               rd_error_o
   , output logic                               wr_error_o
   );

  // Cast inbound DMA packet from cache
  `declare_bsg_cache_dma_pkt_s(daddr_width_p);
  bsg_cache_dma_pkt_s dma_pkt, dma_pkt_li;
  assign dma_pkt_li = dma_pkt_i;

  // Reverse the address hash applied by bp_me_cce_to_cache
  localparam block_offset_lp = `BSG_SAFE_CLOG2(cce_block_width_p/8);
  localparam lg_lce_sets_lp = `BSG_SAFE_CLOG2(lce_sets_p);
  localparam lg_num_cce_lp = `BSG_SAFE_CLOG2(num_cce_p);
  localparam int hash_offset_widths_lp[2:0] = '{(lg_lce_sets_lp-lg_num_cce_lp), lg_num_cce_lp, block_offset_lp};
  logic [daddr_width_p-1:0] addr_lo;
  bp_me_dram_hash_decode
    #(.bp_params_p(bp_params_p)
      ,.offset_widths_p(hash_offset_widths_lp)
      ,.addr_width_p(daddr_width_p)
      )
    dma_addr_hash
    (.addr_i(dma_pkt_li.addr)
      ,.addr_o(addr_lo)
      );

  always_comb begin
    dma_pkt = dma_pkt_li;
    dma_pkt.addr = addr_lo;
  end

  // arbitrate incoming packet valid/yumi between read and write FSMs
  wire is_dma_read = ~dma_pkt.write_not_read;
  wire is_dma_write = dma_pkt.write_not_read;
  wire dma_read_v_li = is_dma_read & dma_pkt_v_i;
  wire dma_write_v_li = is_dma_write & dma_pkt_v_i;
  logic dma_write_yumi_lo, dma_read_yumi_lo;
  logic dma_write_ready_and_lo, dma_read_ready_and_lo;
  assign dma_pkt_yumi_o = is_dma_read ? dma_read_yumi_lo : dma_write_yumi_lo;
  assign dma_write_yumi_lo = dma_write_v_li & dma_write_ready_and_lo;
  assign dma_read_yumi_lo = dma_read_v_li & dma_read_ready_and_lo;

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

  // read FSM
  // issues AXI read requests and processes read responses
  logic rd_burst_done;
  logic [axi_addr_width_p-1:0] axi_rd_addr_lo;
  logic axi_rd_v_lo, axi_rd_ready_and_li;
  axi4_lite_addr_control
    #(.words_per_block_p(8)
      ,.axi_addr_width_p(axi_addr_width_p)
      ,.axi_data_width_p(axi_data_width_p)
      )
    rd_addr_control
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.addr_i(dma_pkt.addr[0+:axi_addr_width_p])
     ,.v_i(dma_read_v_li)
     ,.ready_and_o(dma_read_ready_and_lo)
     ,.addr_o(axi_rd_addr_lo)
     ,.v_o(axi_rd_v_lo)
     ,.ready_and_i(axi_rd_ready_and_li)
     ,.done_o(rd_burst_done)
     );

  always_comb begin
    // no read errors reported yet
    rd_error_n = 1'b0;

    // to axi
    araddr_o = axi_rd_addr_lo;
    arprot_o = 3'b011;
    arvalid_o = axi_rd_v_lo;
    axi_rd_ready_and_li = arready_i;

    // process read axi response
    dma_data_o = rdata_i;
    dma_data_v_o = rvalid_i;
    rready_o = dma_data_ready_and_i;
  end

  // write FSM
  // each write beat sends address in first cycle, followed by data in next cycle
  typedef enum logic [2:0]
  {
    e_wr_reset
    ,e_wr_ready
    ,e_wr_data
    ,e_wr_addr
    ,e_wr_error
  } wr_state_e;
  wr_state_e wr_state_r, wr_state_n;

  logic wr_burst_done;
  logic [axi_addr_width_p-1:0] axi_wr_addr_lo;
  logic axi_wr_v_lo, axi_wr_ready_and_li;
  axi4_lite_addr_control
    #(.words_per_block_p(8)
      ,.axi_addr_width_p(axi_addr_width_p)
      ,.axi_data_width_p(axi_data_width_p)
      )
    wr_addr_control
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.addr_i(dma_pkt.addr[0+:axi_addr_width_p])
     ,.v_i(dma_write_v_li)
     ,.ready_and_o(dma_write_ready_and_lo)
     ,.addr_o(axi_wr_addr_lo)
     ,.v_o(axi_wr_v_lo)
     ,.ready_and_i(axi_wr_ready_and_li)
     ,.done_o(wr_burst_done)
     );

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      wr_state_r <= e_wr_reset;
    end else begin
      wr_state_r <= wr_state_n;
    end
  end

  always_comb begin
    wr_error_n = 1'b0;
    wr_state_n = wr_state_r;
    // from dma
    dma_data_yumi_o = 1'b0;
    // to axi - write address
    awaddr_o = axi_wr_addr_lo;
    awprot_o = 3'b011;
    awvalid_o = 1'b0;
    axi_wr_ready_and_li = 1'b0;
    // to axi - write data
    wdata_o = dma_data_i;
    wstrb_o = '1;
    wvalid_o = 1'b0;

    // from axi - always accept write responses
    bready_o = 1'b1;
    wr_error_n = (bvalid_i & bready_o) & ((bresp_i == 2'b10) || (bresp_i == 2'b11));

    unique case(wr_state_r)
      e_wr_reset: begin
        wr_state_n = e_wr_ready;
      end
      e_wr_ready: begin
        // process write dma packet, send first write address packet
        awvalid_o = axi_wr_v_lo;
        axi_wr_ready_and_li = awready_i;
        wr_state_n = dma_write_yumi_lo ? e_wr_data : e_wr_ready;
      end
      e_wr_data: begin
        // send write data
        wvalid_o = dma_data_v_i;
        dma_data_yumi_o = wvalid_o & wready_i;
        wr_state_n = dma_data_yumi_o
                     ? wr_burst_done
                       ? e_wr_ready
                       : e_wr_addr
                     : e_wr_data;
      end
      e_wr_addr: begin
        // send additional address AXI beats
        awvalid_o = axi_wr_v_lo;
        axi_wr_ready_and_li = awready_i;
        wr_state_n = (awvalid_o & awready_i) ? e_wr_data : e_wr_addr;
      end
      e_wr_error: begin
        wr_state_n = wr_state_r;
      end
      default: begin
        wr_state_n = e_wr_reset;
      end
    endcase
  end

endmodule
