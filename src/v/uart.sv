/**
 * UART
 * UART message = 1 start bit, 5-9 data bits, [1 parity bit], 1 or 2 stop bits
 * start bit is low, stop bit is high
 * parity bit is optional and can be configured for odd or even parity
 * TX and RX bytes are buffered in configurable size buffers
 *
 * It is possible for the receiver to overflow the RX Buffer. This is reported by
 * the rx_overflow_error_o signal being raised for one cycle. When this happens,
 * the received data byte will be dropped.
 *
 * If parity is enabled (parity_bits_p == 1), the RX module will report parity errors
 * when detected as determined by the parity setting (odd or even). A parity error
 * is reported by this module raising parity_error_o for one cycle.
 *
 * Frame errors (invalid stop bits) are detected and reported by raising
 * rx_frame_error_o for one cycle.
 *
 */

`include "bp_common_defines.svh"

module uart
    #(parameter clk_per_bit_p = 100 // 100 MHz clock / 1,000,000 Baud
      , parameter data_bits_p = 8 // between 5 and 9 bits
      , parameter parity_bits_p = 0 // 0 or 1
      , parameter parity_odd_p = 0 // 0 for even parity, 1 for odd parity
      , parameter stop_bits_p = 1 // 1 or 2
      , parameter rx_buffer_els_p = 16
      , parameter tx_buffer_els_p = 16
      )
    (input clk_i
    , input reset_i

    // Receive
    // lsb->msb
    , input rx_i
    // handshake: consumed when rx_v_o & rx_yumi_i (valid then yumi)
    , output logic rx_v_o
    , output logic [data_bits_p-1:0] rx_o
    , input rx_yumi_i
    // errors
    , output logic rx_overflow_error_o
    , output logic rx_frame_error_o
    , output logic rx_parity_error_o

    // Transmit
    // lsb->msb
    , output logic tx_o
    // handshake: tx_i accepted when tx_v_i & tx_ready_and_o
    , input tx_v_i
    , output logic tx_ready_and_o
    , input [data_bits_p-1:0] tx_i
    );

  // UART TX Buffer
  logic tx_v_li, tx_ready_and_lo;
  logic [data_bits_p-1:0] tx_li;
  bsg_fifo_1r1w_small
   #(.width_p(data_bits_p)
     ,.els_p(tx_buffer_els_p)
     ,.ready_THEN_valid_p(0)
     )
    uart_tx_buffer
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.v_i(tx_v_i)
     ,.ready_o(tx_ready_and_o)
     ,.data_i(tx_i)
     ,.v_o(tx_v_li)
     ,.data_o(tx_li)
     ,.yumi_i(tx_v_li & tx_ready_and_lo)
     );

  // UART TX
  uart_tx
   #(.clk_per_bit_p(clk_per_bit_p)
     ,.data_bits_p(data_bits_p)
     ,.parity_bits_p(parity_bits_p)
     ,.stop_bits_p(stop_bits_p)
     ,.parity_odd_p(parity_odd_p)
     )
    tx
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.tx_v_i(tx_v_li)
     ,.tx_i(tx_li)
     ,.tx_ready_and_o(tx_ready_and_lo)
     ,.tx_o(tx_o)
     );

  // UART RX Buffer
  logic rx_v_lo, rx_ready_and_li;
  logic [data_bits_p-1:0] rx_lo;
  bsg_fifo_1r1w_small
   #(.width_p(data_bits_p)
     ,.els_p(rx_buffer_els_p)
     ,.ready_THEN_valid_p(0)
     )
    uart_rx_buffer
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.v_i(rx_v_lo)
     ,.ready_o(rx_ready_and_li)
     ,.data_i(rx_lo)
     ,.v_o(rx_v_o)
     ,.data_o(rx_o)
     ,.yumi_i(rx_yumi_i)
     );

  logic [`BSG_WIDTH(rx_buffer_els_p)-1:0] rx_credits_lo;
  bsg_flow_counter
   #(.els_p(rx_buffer_els_p))
    rx_credit_counter
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.v_i(rx_v_lo)
     ,.ready_i(rx_ready_and_li)
     ,.yumi_i(rx_yumi_i)
     ,.count_o(rx_credits_lo)
     );
  assign rx_credits_full = (rx_credits_lo == rx_buffer_els_p);
  assign rx_credits_empty = (rx_credits_lo == '0);
  assign rx_overflow_error_o = rx_credits_full & rx_v_lo;

  // UART RX
  uart_rx
   #(.clk_per_bit_p(clk_per_bit_p)
     ,.data_bits_p(data_bits_p)
     ,.parity_bits_p(parity_bits_p)
     ,.stop_bits_p(stop_bits_p)
     ,.parity_odd_p(parity_odd_p)
     )
    rx
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.rx_i(rx_i)
     ,.rx_v_o(rx_v_lo)
     ,.rx_o(rx_lo)
     ,.rx_frame_error_o(rx_frame_error_o)
     ,.rx_parity_error_o(rx_parity_error_o)
     );

endmodule
