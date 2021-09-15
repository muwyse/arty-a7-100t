`timescale 1ns / 1ps

module led_pwm
  #(parameter bits_p = 4)
  (input clk_i
   ,input reset_i
   ,input en_i
   ,input incr_i
   ,input decr_i
   ,output logic led_o
   );

  // count is always incrementing
  logic [bits_p-1:0] count_r, count_n;
  // cycles starts at 1 and can be incremented or decremented by input
  logic [bits_p-1:0] cycles_r, cycles_n;

  // LED is on when count_r < cycles_r

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      count_r <= 'd0;
      cycles_r <= 'd0;
    end else begin
      count_r <= count_n;
      cycles_r <= cycles_n;
    end
  end

  always_comb begin
    count_n = count_r + 'd1;
    led_o = en_i & (count_r < cycles_r);
    if (en_i) begin
      cycles_n = cycles_r + incr_i - decr_i;
    end else begin
      cycles_n = cycles_r;
    end
  end
endmodule
