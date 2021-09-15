`timescale 1ns / 1ps

module debounce
  (input clk_i
   ,input i
   ,output logic o
   );

  logic dff_0, dff_1, dff_2;

  always_ff @(posedge clk_i) begin
    dff_0 <= i;
    dff_1 <= dff_0;
    dff_2 <= dff_1;
  end
  assign o = dff_1 & ~dff_2;
endmodule
