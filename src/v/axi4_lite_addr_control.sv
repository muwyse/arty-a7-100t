/**
 *
 * Name:
 *   axi4_lite_addr_control.sv
 *
 * Description:
 *   This module computes an aligned address to issue for each of N requests
 *
 */

module axi4_lite_addr_control
 #(parameter words_per_block_p = 8
   ,parameter axi_addr_width_p = 28
   ,parameter axi_data_width_p = 64
   ,localparam axi_data_offset_lp = $clog2(axi_data_width_p)
   ,localparam word_cnt_width_lp = $clog2(words_per_block_p)
   ,localparam axi_addr_upper_bits_lp = axi_addr_width_p-axi_data_offset_lp-word_cnt_width_lp
 )
 (input                                 clk_i
  , input                               reset_i
  // input address - arrives only first cycle
  , input [axi_addr_width_p-1:0]        addr_i
  , input                               v_i
  , output logic                        ready_and_o
  // output address - output first cycle and for n-1 beats following
  , output logic [axi_addr_width_p-1:0] addr_o
  , output logic                        v_o
  , input                               ready_and_i
  , output logic                        done_o
  );

  if (words_per_block_p == 1) begin : passthrough
    assign addr_o = addr_i;
    assign v_o = v_i;
    assign ready_and_o = ready_and_i;

  end else begin : wraparound
    logic [axi_addr_width_p-1:0] addr_r, addr_n;
    logic [word_cnt_width_lp-1:0] cnt_r, cnt_n, wrap_cnt_r, wrap_cnt_n;
    wire is_last = (cnt_r == (words_per_block_p-1));
    assign done_o = is_last & v_o & ready_and_i;

    typedef enum logic [2:0]
    {
      e_reset
      ,e_first
      ,e_rest
    } state_e;
    state_e state_r, state_n;

    always_ff @(posedge clk_i) begin
      if (reset_i) begin
        state_r <= e_reset;
        addr_r <= '0;
        cnt_r <= '0;
        wrap_cnt_r <= '0;
      end else begin
        state_r <= state_n;
        addr_r <= addr_n;
        cnt_r <= cnt_n;
        wrap_cnt_r <= wrap_cnt_n;
      end
    end

    always_comb begin
      state_n = state_r;
      addr_o = '0;
      v_o = 1'b0;
      ready_and_o = 1'b0;
      addr_n = addr_r;
      cnt_n = cnt_r;
      wrap_cnt_n = wrap_cnt_r;
      unique case (state_r)
        e_reset: begin
          state_n = e_first;
        end
        e_first: begin
          // send out first address, as is
          addr_o = addr_i;
          v_o = v_i;
          ready_and_o = ready_and_i;
          state_n = (v_o & ready_and_i) ? e_rest : e_first;
          // setup address and count registers
          addr_n = addr_i;
          cnt_n = 'd1;
          wrap_cnt_n = addr_i[axi_data_offset_lp+:word_cnt_width_lp] + 'd1;

        end
        e_rest: begin
          // send incremented and wrapped address
          addr_o = {addr_r[(axi_addr_width_p-1)-:axi_addr_upper_bits_lp], wrap_cnt_r, axi_data_offset_lp'(0)};
          v_o = 1'b1;
          // when address sends, increment counts, check if all beats sent
          if (v_o & ready_and_i) begin
            // done sending all beats
            if (is_last) begin
              state_n = e_first;
              cnt_n = '0;
              wrap_cnt_n = '0;
              addr_n = '0;
            end
            // more beats to send
            else begin
              state_n = e_rest;
              wrap_cnt_n = wrap_cnt_r + 'd1;
              cnt_n = cnt_r + 'd1;
            end
          end
        end
        default: begin
          state_n = e_reset;
        end
      endcase
    end

  end

endmodule
