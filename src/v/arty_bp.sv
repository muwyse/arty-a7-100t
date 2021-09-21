`timescale 1ns / 1ps

/**
 *
 * Name:
 *   arty_bp.sv
 *
 * Description:
 *   This is the top-level design for a unicore BlackParrot processor on the Arty A7.
 *
 *    This module instantiates:
 *    - a unicore BlackParrot processor core
 *    - a Vivado generated Block Design with 256 MiB DDR3 SDRAM exposed via AXI4 Lite (and associated clocks)
 *    - BlackParrot BedRock I/O to AXI4 Lite interface converter between BP core and the memory block design
 *    - FPGA Host used to communicate between the BlackParrot I/O ports and the Arty A7 on-board UART
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"
`include "bp_fpga_host_defines.svh"

module arty_bp
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  import bp_fpga_host_pkg::*;

  #(parameter bp_params_e bp_params_p = e_bp_unicore_l1_tiny_cfg
   `declare_bp_proc_params(bp_params_p)
    , parameter nbf_addr_width_p = paddr_width_p
    , parameter nbf_data_width_p = dword_width_gp
    , localparam nbf_width_lp = `bp_fpga_host_nbf_width(nbf_addr_width_p, nbf_data_width_p)

    , parameter uart_clk_per_bit_p = 61 // 30.272728 MHz clock, 500000 baud
    , parameter uart_data_bits_p = 8 // between 5 and 9 bits
    , parameter uart_parity_bit_p = 0 // 0 or 1
    , parameter uart_parity_odd_p = 0 // 0 for even parity, 1 for odd parity
    , parameter uart_stop_bits_p = 1 // 1 or 2

    , parameter io_in_nbf_buffer_els_p = 4
    , parameter io_out_nbf_buffer_els_p = 4

    , parameter axi_addr_width_p = 28
    , parameter axi_data_width_p = 64
    , parameter axi_wstrb_width_p = (axi_data_width_p/8)

    , localparam dma_pkt_width_lp = `bsg_cache_dma_pkt_width(daddr_width_p)

    `declare_bp_bedrock_mem_if_widths(paddr_width_p, dword_width_gp, lce_id_width_p, lce_assoc_p, io)
    )
  (output logic [13:0] ddr3_sdram_addr
  , output logic [2:0] ddr3_sdram_ba
  , output logic ddr3_sdram_cas_n
  , output logic [0:0] ddr3_sdram_ck_n
  , output logic [0:0] ddr3_sdram_ck_p
  , output logic [0:0] ddr3_sdram_cke
  , output logic [0:0] ddr3_sdram_cs_n
  , output logic [1:0] ddr3_sdram_dm
  , inout [15:0] ddr3_sdram_dq
  , inout [1:0] ddr3_sdram_dqs_n
  , inout [1:0] ddr3_sdram_dqs_p
  , output logic [0:0] ddr3_sdram_odt
  , output logic ddr3_sdram_ras_n
  , output logic ddr3_sdram_reset_n
  , output logic ddr3_sdram_we_n
  , output logic [3:0] led_o
  , input external_clock_i
  , input external_reset_n_i
  , output logic [3:0][2:0] rgb_led_o
  , input [3:0] btn_i
  , input [3:0] switch_i
  , input uart_rx_i
  , output logic uart_tx_o
  );

  assign led_o[3] = external_reset_n_i ? 1'b0 : 1'b1;

  wire proc_reset_o;

  // AXI
  wire s_axi_clk;
  wire s_axi_reset_n_o;

  wire [axi_addr_width_p-1:0] s_axi_lite_i_araddr;
  wire [2:0] s_axi_lite_i_arprot;
  wire s_axi_lite_i_arready;
  wire s_axi_lite_i_arvalid;
  wire [axi_addr_width_p-1:0] s_axi_lite_i_awaddr;
  wire [2:0] s_axi_lite_i_awprot;
  wire s_axi_lite_i_awready;
  wire s_axi_lite_i_awvalid;
  wire s_axi_lite_i_bready;
  wire [1:0] s_axi_lite_i_bresp;
  wire s_axi_lite_i_bvalid;
  wire [axi_data_width_p-1:0] s_axi_lite_i_rdata;
  wire s_axi_lite_i_rready;
  wire [1:0] s_axi_lite_i_rresp;
  wire s_axi_lite_i_rvalid;
  wire [axi_data_width_p-1:0] s_axi_lite_i_wdata;
  wire s_axi_lite_i_wready;
  wire [axi_wstrb_width_p-1:0] s_axi_lite_i_wstrb;
  wire s_axi_lite_i_wvalid;

  // reset register and active low to active high conversion
  logic reset_r;
  always_ff @(posedge s_axi_clk) begin
    reset_r <= ~s_axi_reset_n_o;
  end

  // debounce buttons
  logic [3:0] btn_li;
  genvar b;
  for (b = 0; b < 4; b++) begin : btn
    debounce db
      (.clk_i(s_axi_clk)
       ,.i(btn_i[b])
       ,.o(btn_li[b])
       );
  end

  // 4 output RGB LEDs - each LED = [r,g,b]
  logic [3:0][2:0] rgb_led_lo;
  assign rgb_led_o = rgb_led_lo;
  genvar i,j;
  for (i = 0; i < 4; i++) begin : led
    for (j = 0; j < 3; j++) begin : rgb
      led_pwm
       #(.bits_p(4))
        led_rgb
        (.clk_i(s_axi_clk)
         ,.reset_i(reset_r)
         ,.en_i(switch_i[i])
         ,.incr_i(btn_li[j])
         ,.decr_i(1'b0)
         ,.led_o(rgb_led_lo[i][j])
         );
    end
  end

  `declare_bp_bedrock_mem_if(paddr_width_p, dword_width_gp, lce_id_width_p, lce_assoc_p, io)
  // I/O command buses
  // to FPGA Host
  bp_bedrock_io_mem_msg_header_s fpga_host_io_cmd_li, fpga_host_io_resp_lo;
  logic [dword_width_gp-1:0] fpga_host_io_cmd_data_li, fpga_host_io_resp_data_lo;
  logic fpga_host_io_cmd_v_li, fpga_host_io_cmd_ready_and_lo;
  logic fpga_host_io_resp_v_lo, fpga_host_io_resp_yumi_li;
  logic fpga_host_io_cmd_last_li, fpga_host_io_resp_last_lo;

  // from FPGA Host
  bp_bedrock_io_mem_msg_header_s fpga_host_io_cmd_lo, fpga_host_io_resp_li;
  logic [dword_width_gp-1:0] fpga_host_io_cmd_data_lo, fpga_host_io_resp_data_li;
  logic fpga_host_io_cmd_v_lo, fpga_host_io_cmd_yumi_li;
  logic fpga_host_io_resp_v_li, fpga_host_io_resp_ready_and_lo;
  logic fpga_host_io_cmd_last_lo, fpga_host_io_resp_last_li;

  // cache DMA - from unicore to converter
  logic [dma_pkt_width_lp-1:0] dma_pkt_li;
  logic                        dma_pkt_v_li;
  logic                        dma_pkt_yumi_lo;

  logic[l2_fill_width_p-1:0]   dma_data_lo;
  logic                        dma_data_v_lo;
  logic                        dma_data_ready_and_li;

  logic [l2_fill_width_p-1:0]  dma_data_li;
  logic                        dma_data_v_li;
  logic                        dma_data_yumi_lo;

  // FPGA Host
  bp_fpga_host
    #(.bp_params_p              (bp_params_p)
      ,.nbf_addr_width_p        (nbf_addr_width_p)
      ,.nbf_data_width_p        (nbf_data_width_p)
      ,.uart_clk_per_bit_p      (uart_clk_per_bit_p)
      ,.uart_data_bits_p        (uart_data_bits_p)
      ,.uart_parity_bit_p       (uart_parity_bit_p)
      ,.uart_parity_odd_p       (uart_parity_odd_p)
      ,.uart_stop_bits_p        (uart_stop_bits_p)
      ,.io_in_nbf_buffer_els_p  (io_in_nbf_buffer_els_p)
      ,.io_out_nbf_buffer_els_p (io_out_nbf_buffer_els_p)
      )
      fpga_host
      (.clk_i(s_axi_clk)
       ,.reset_i(reset_r)

       // to FPGA Host
       ,.io_cmd_header_i     (fpga_host_io_cmd_li)
       ,.io_cmd_data_i       (fpga_host_io_cmd_data_li)
       ,.io_cmd_v_i          (fpga_host_io_cmd_v_li)
       ,.io_cmd_ready_and_o  (fpga_host_io_cmd_ready_and_lo)
       ,.io_cmd_last_i       (fpga_host_io_cmd_last_li)

       ,.io_resp_header_o    (fpga_host_io_resp_lo)
       ,.io_resp_data_o      (fpga_host_io_resp_data_lo)
       ,.io_resp_v_o         (fpga_host_io_resp_v_lo)
       ,.io_resp_yumi_i      (fpga_host_io_resp_yumi_li)
       ,.io_resp_last_o      (fpga_host_io_resp_last_lo)

       // from FPGA Host
       ,.io_cmd_header_o     (fpga_host_io_cmd_lo)
       ,.io_cmd_data_o       (fpga_host_io_cmd_data_lo)
       ,.io_cmd_v_o          (fpga_host_io_cmd_v_lo)
       ,.io_cmd_yumi_i       (fpga_host_io_cmd_yumi_li)
       ,.io_cmd_last_o       (fpga_host_io_cmd_last_lo)

       ,.io_resp_header_i    (fpga_host_io_resp_li)
       ,.io_resp_data_i      (fpga_host_io_resp_data_li)
       ,.io_resp_v_i         (fpga_host_io_resp_v_li)
       ,.io_resp_ready_and_o (fpga_host_io_resp_ready_and_lo)
       ,.io_resp_last_i      (fpga_host_io_resp_last_li)

       // UART
       ,.rx_i(uart_rx_i)
       ,.tx_o(uart_tx_o)

       // UART error
       ,.error_o(led_o[0])
      );

  // Black Parrot core
  bp_unicore
    #(.bp_params_p(bp_params_p))
    core
    (.clk_i(s_axi_clk)
     ,.reset_i(reset_r)

     // I/O to FPGA Host
     ,.io_cmd_header_o      (fpga_host_io_cmd_li)
     ,.io_cmd_data_o        (fpga_host_io_cmd_data_li)
     ,.io_cmd_v_o           (fpga_host_io_cmd_v_li)
     ,.io_cmd_ready_and_i   (fpga_host_io_cmd_ready_and_lo)
     ,.io_cmd_last_o        (fpga_host_io_cmd_last_li)

     ,.io_resp_header_i     (fpga_host_io_resp_lo)
     ,.io_resp_data_i       (fpga_host_io_resp_data_lo)
     ,.io_resp_v_i          (fpga_host_io_resp_v_lo)
     ,.io_resp_yumi_o       (fpga_host_io_resp_yumi_li)
     ,.io_resp_last_i       (fpga_host_io_resp_last_lo)

     // I/O from FPGA host
     ,.io_cmd_header_i      (fpga_host_io_cmd_lo)
     ,.io_cmd_data_i        (fpga_host_io_cmd_data_lo)
     ,.io_cmd_v_i           (fpga_host_io_cmd_v_lo)
     ,.io_cmd_yumi_o        (fpga_host_io_cmd_yumi_li)
     ,.io_cmd_last_i        (fpga_host_io_cmd_last_lo)

     ,.io_resp_header_o     (fpga_host_io_resp_li)
     ,.io_resp_data_o       (fpga_host_io_resp_data_li)
     ,.io_resp_v_o          (fpga_host_io_resp_v_li)
     ,.io_resp_ready_and_i  (fpga_host_io_resp_ready_and_lo)
     ,.io_resp_last_o       (fpga_host_io_resp_last_li)

     // DMA interface
     ,.dma_pkt_o            (dma_pkt_li)
     ,.dma_pkt_v_o          (dma_pkt_v_li)
     ,.dma_pkt_yumi_i       (dma_pkt_yumi_lo)

     ,.dma_data_i           (dma_data_lo)
     ,.dma_data_v_i         (dma_data_v_lo)
     ,.dma_data_ready_and_o (dma_data_ready_and_li)

     ,.dma_data_o           (dma_data_li)
     ,.dma_data_v_o         (dma_data_v_li)
     ,.dma_data_yumi_i      (dma_data_yumi_lo)
    );

  bp_cache_dma_to_axi4_lite
    #(.bp_params_p(bp_params_p)
      ,.axi_addr_width_p(axi_addr_width_p)
      ,.axi_data_width_p(axi_data_width_p)
      )
    cache_dma_to_axi4_lite
    (.clk_i(s_axi_clk)
     ,.reset_i(reset_r)

     // AXI4 Lite interface
     ,.araddr_o(s_axi_lite_i_araddr)
     ,.arprot_o(s_axi_lite_i_arprot)
     ,.arready_i(s_axi_lite_i_arready)
     ,.arvalid_o(s_axi_lite_i_arvalid)
     ,.awaddr_o(s_axi_lite_i_awaddr)
     ,.awprot_o(s_axi_lite_i_awprot)
     ,.awready_i(s_axi_lite_i_awready)
     ,.awvalid_o(s_axi_lite_i_awvalid)
     ,.bready_o(s_axi_lite_i_bready)
     ,.bresp_i(s_axi_lite_i_bresp)
     ,.bvalid_i(s_axi_lite_i_bvalid)
     ,.rdata_i(s_axi_lite_i_rdata)
     ,.rready_o(s_axi_lite_i_rready)
     ,.rresp_o(s_axi_lite_i_rresp)
     ,.rvalid_i(s_axi_lite_i_rvalid)
     ,.wdata_o(s_axi_lite_i_wdata)
     ,.wready_i(s_axi_lite_i_wready)
     ,.wstrb_o(s_axi_lite_i_wstrb)
     ,.wvalid_o(s_axi_lite_i_wvalid)

     // DMA interface
     ,.dma_pkt_i            (dma_pkt_li)
     ,.dma_pkt_v_i          (dma_pkt_v_li)
     ,.dma_pkt_yumi_o       (dma_pkt_yumi_lo)

     ,.dma_data_o           (dma_data_lo)
     ,.dma_data_v_o         (dma_data_v_lo)
     ,.dma_data_ready_and_i (dma_data_ready_and_li)

     ,.dma_data_i           (dma_data_li)
     ,.dma_data_v_i         (dma_data_v_li)
     ,.dma_data_yumi_o      (dma_data_yumi_lo)

     ,.rd_error_o(led_o[2])
     ,.wr_error_o(led_o[1])
     );

  design_1_wrapper design_ip
   (.ddr3_sdram_addr(ddr3_sdram_addr),
    .ddr3_sdram_ba(ddr3_sdram_ba),
    .ddr3_sdram_cas_n(ddr3_sdram_cas_n),
    .ddr3_sdram_ck_n(ddr3_sdram_ck_n),
    .ddr3_sdram_ck_p(ddr3_sdram_ck_p),
    .ddr3_sdram_cke(ddr3_sdram_cke),
    .ddr3_sdram_cs_n(ddr3_sdram_cs_n),
    .ddr3_sdram_dm(ddr3_sdram_dm),
    .ddr3_sdram_dq(ddr3_sdram_dq),
    .ddr3_sdram_dqs_n(ddr3_sdram_dqs_n),
    .ddr3_sdram_dqs_p(ddr3_sdram_dqs_p),
    .ddr3_sdram_odt(ddr3_sdram_odt),
    .ddr3_sdram_ras_n(ddr3_sdram_ras_n),
    .ddr3_sdram_reset_n(ddr3_sdram_reset_n),
    .ddr3_sdram_we_n(ddr3_sdram_we_n),
    .mig_ddr_init_calib_complete_o(mig_ddr_init_calib_complete_o),
    .proc_reset_o(proc_reset_o),
    .clk_111M_o(),
    .clk_74M_o(),
    .clk_55M_o(),
    .clk_30M_o(s_axi_clk),
    .clk_20M_o(),
    .s_axi_lite_i_araddr(s_axi_lite_i_araddr),
    .s_axi_lite_i_arprot(s_axi_lite_i_arprot),
    .s_axi_lite_i_arready(s_axi_lite_i_arready),
    .s_axi_lite_i_arvalid(s_axi_lite_i_arvalid),
    .s_axi_lite_i_awaddr(s_axi_lite_i_awaddr),
    .s_axi_lite_i_awprot(s_axi_lite_i_awprot),
    .s_axi_lite_i_awready(s_axi_lite_i_awready),
    .s_axi_lite_i_awvalid(s_axi_lite_i_awvalid),
    .s_axi_lite_i_bready(s_axi_lite_i_bready),
    .s_axi_lite_i_bresp(s_axi_lite_i_bresp),
    .s_axi_lite_i_bvalid(s_axi_lite_i_bvalid),
    .s_axi_lite_i_rdata(s_axi_lite_i_rdata),
    .s_axi_lite_i_rready(s_axi_lite_i_rready),
    .s_axi_lite_i_rresp(s_axi_lite_i_rresp),
    .s_axi_lite_i_rvalid(s_axi_lite_i_rvalid),
    .s_axi_lite_i_wdata(s_axi_lite_i_wdata),
    .s_axi_lite_i_wready(s_axi_lite_i_wready),
    .s_axi_lite_i_wstrb(s_axi_lite_i_wstrb),
    .s_axi_lite_i_wvalid(s_axi_lite_i_wvalid),
    .s_axi_reset_n_o(s_axi_reset_n_o),
    .external_clock_i(external_clock_i),
    .external_reset_n_i(external_reset_n_i)
    );

endmodule
