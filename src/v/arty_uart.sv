`timescale 1ns / 1ps

/**
 *
 * Name:
 *   arty_uart.sv
 *
 * Description:
 *   This is the top-level design to stress test the UART and FPGA Host
 *
 *    This module instantiates:
 *    - a Vivado generated Block Design with 256 MiB DDR3 SDRAM exposed via AXI4 Lite (and associated clocks)
 *    - BedRock I/O to AXI4 Lite interface converter between FPGA Host and the memory block design
 *    - FPGA Host used to communicate between the BedRock I/O converter and the Arty A7 on-board UART
 */

`include "bsg_defines.v"

module arty_uart

  #(parameter uart_clk_per_bit_p = 30 // 30 MHz, 1000000 Baud
    , parameter uart_data_bits_p = 8 // between 5 and 9 bits
    , parameter uart_parity_bits_p = 0 // 0 or 1
    , parameter uart_parity_odd_p = 0 // 0 for even parity, 1 for odd parity
    , parameter uart_stop_bits_p = 1 // 1 or 2
    , parameter uart_rx_buffer_els_p = 16
    , parameter uart_tx_buffer_els_p = 16

    , parameter axi_addr_width_p = 28
    , parameter axi_data_width_p = 64
    , parameter axi_wstrb_width_p = (axi_data_width_p/8)

    )
  (input external_clock_i
  , input external_reset_n_i
  , output logic [3:0][2:0] rgb_led_o
  , output logic [3:0] led_o
  , input [3:0] btn_i
  , input [3:0] switch_i
  , input uart_rx_i
  , output logic uart_tx_o
  );

  logic clock_30M_lo;
  logic clock_60M_lo;

  // reset register and active low to active high conversion
  wire reset = ~external_reset_n_i;
  wire clock = clock_30M_lo;

  // debounce buttons
  logic [3:0] btn_li;
  genvar b;
  for (b = 0; b < 4; b++) begin : btn
    debounce db
      (.clk_i(clock)
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
        (.clk_i(clock)
         ,.reset_i(reset)
         ,.en_i(switch_i[i])
         ,.incr_i(btn_li[j])
         ,.decr_i(1'b0)
         ,.led_o(rgb_led_lo[i][j])
         );
    end
  end

  logic rx_v_lo, rx_ready_and_li;
  logic [uart_data_bits_p-1:0] rx_lo;
  logic rx_parity_error_lo, rx_frame_error_lo, rx_overflow_error_lo;
  // UART
  uart
   #(.clk_per_bit_p(uart_clk_per_bit_p)
     ,.data_bits_p(uart_data_bits_p)
     ,.parity_bits_p(uart_parity_bits_p)
     ,.stop_bits_p(uart_stop_bits_p)
     ,.parity_odd_p(uart_parity_odd_p)
     ,.rx_buffer_els_p(uart_rx_buffer_els_p)
     ,.tx_buffer_els_p(uart_tx_buffer_els_p)
     )
    uart_buffered
    (.clk_i(clock)
     ,.reset_i(reset)
     // from external
     ,.rx_i(uart_rx_i)
     // to logic
     ,.rx_v_o(rx_v_lo)
     ,.rx_o(rx_lo)
     ,.rx_yumi_i(rx_v_lo & rx_ready_and_li)
     // rx errors
     ,.rx_parity_error_o(rx_parity_error_lo)
     ,.rx_frame_error_o(rx_frame_error_lo)
     ,.rx_overflow_error_o(rx_overflow_error_lo)
     // to external
     ,.tx_o(uart_tx_o)
     ,.tx_v_o(/* unused */)
     ,.tx_done_o(/* unused */)
     // from logic
     ,.tx_v_i(rx_v_lo)
     ,.tx_ready_and_o(rx_ready_and_li)
     ,.tx_i(rx_lo)
     );

  logic [2:0] led_r, led_n;
  always_ff @(posedge clock) begin
    if (reset) begin
      led_r <= '0;
    end else begin
      led_r <= led_n;
    end
  end

  always_comb begin
    led_n[0] = led_r[0] | rx_parity_error_lo;
    led_n[1] = led_r[1] | rx_frame_error_lo;
    led_n[2] = led_r[2] | rx_overflow_error_lo;
    led_o[2:0] = led_r;
    led_o[3] = reset;
  end

  design_1_wrapper design_1_i
    (.external_clock_i(external_clock_i)
     ,.external_reset_n_i(external_reset_n_i)
     ,.clk_30M_o(clock_30M_lo)
     ,.clk_60M_o(clock_60M_lo)
     );

endmodule
