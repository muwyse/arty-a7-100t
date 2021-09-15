`timescale 1ns / 1ps

module axi4_lite_traffic_gen(
  // AXI
  input clk_i // connects to traffic gen as clock
  , input reset_n_i // connects to traffic gen as reset_n_i
  // read address
  , output logic [27:0] araddr_o
  , output logic [2:0] arprot_o
  , input arready_i
  , output logic arvalid_o
  // write address
  , output logic [27:0] awaddr_o
  , output logic [2:0] awprot_o
  , input awready_i
  , output logic awvalid_o
  // write response
  , output logic bready_o
  , input [1:0] bresp_i
  , input bvalid_i
  // read data
  , input [63:0] rdata_i
  , output logic rready_o
  , output logic [1:0] rresp_o
  , input rvalid_i
  // write data
  , output logic [63:0] wdata_o
  , input wready_i
  , output logic [7:0] wstrb_o
  , output logic wvalid_o
  , output logic rd_error_o
  , output logic wr_error_o
  , output logic done_o
  , input start_i
  );

  logic [27:0] addr_r, addr_n;
  logic [63:0] data_r, data_n;

  typedef enum logic [2:0]
  {
    e_reset
    ,e_ready
    ,e_write_send
    ,e_write_data_send
    ,e_write_resp
    ,e_read_send
    ,e_read_check
    ,e_done
  } state_e;
  state_e state_r, state_n;

  logic reset_r, reset_n;
  always_ff @(posedge clk_i) begin
    reset_r <= reset_n_i;
  end

  logic rd_error_r, rd_error_n;
  assign rd_error_o = rd_error_r;
  logic wr_error_r, wr_error_n;
  assign wr_error_o = wr_error_r;
  always_ff @(posedge clk_i) begin
    if (~reset_r) begin
      addr_r <=  '0;
      data_r <= '0;
      state_r <= e_reset;
      rd_error_r <= '0;
      wr_error_r <= '0;
    end else begin
      addr_r <= addr_n;
      data_r <= data_n;
      state_r <= state_n;
      rd_error_r <= rd_error_r | rd_error_n;
      wr_error_r <= wr_error_r | wr_error_n;
    end
  end

  always_comb begin
    state_n = state_r;
    data_n = data_r;
    addr_n = addr_r;
    rd_error_n = 1'b0;
    wr_error_n = 1'b0;

    awaddr_o = '0;
    awvalid_o = 1'b0;
    awprot_o = 3'b001;

    araddr_o = '0;
    arvalid_o = 1'b0;
    arprot_o = 3'b001;

    bready_o = 1'b0;

    rready_o = '0;
    rresp_o = '0;

    wdata_o = '0;
    wstrb_o = '0;
    wvalid_o = '0;

    done_o = '0;

    unique case(state_r)
      e_reset: begin
        state_n = e_ready;
      end
      e_ready: begin
        state_n = start_i ? e_write_send : e_ready;
      end
      e_write_send: begin
        awvalid_o = 1'b1;
        awaddr_o = addr_r;
        if (awready_i) begin
          state_n = e_write_data_send;
        end
      end
      e_write_data_send: begin
        wvalid_o = 1'b1;
        wdata_o = {'0, addr_r};
        wstrb_o = '1;
        if (wready_i) begin
          addr_n = addr_r + 'd8;
          state_n = e_write_resp;
        end
      end
      e_write_resp: begin
        if (bvalid_i) begin
          bready_o = 1'b1;
          wr_error_n = ((bresp_i == 2'b10) || (bresp_i == 2'b11));
          state_n = (addr_r == '0)
              ? e_read_send
              : e_write_send;
        end
      end
      e_read_send: begin
        arvalid_o = 1'b1;
        araddr_o = addr_r;
        if (arready_i) begin
          state_n = e_read_check;
        end
      end
      e_read_check: begin
        if (rvalid_i) begin
          rd_error_n = rdata_i != {'0, addr_r};
          addr_n = addr_r + 'd8;
          rready_o = 1'b1;
          rresp_o = 2'b00;
          state_n = (addr_n == '0) ? e_done : e_read_send;
        end
      end
      e_done: begin
        done_o = 1'b1;
      end
      default: begin
        state_n = e_reset;
      end
    endcase
  end

endmodule
