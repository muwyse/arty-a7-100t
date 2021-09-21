/**
 * UART Receiver
 * UART message = 1 start bit, 5-9 data bits, [1 parity bit], 1 or 2 stop bits
 * start bit is low, stop bit is high
 *
 * TODO:
 * - report frame error if detected
 */

`include "bp_common_defines.svh"

module uart_rx
    #(parameter clk_per_bit_p = 10416 // 100 MHz clock / 9600 Baud
      , parameter data_bits_p = 8 // between 5 and 9 bits
      , parameter parity_bit_p = 0 // 0 or 1
      , parameter parity_odd_p = 0 // 0 for even parity, 1 for odd parity
      , parameter stop_bits_p = 1 // 1 or 2
      )
    (input clk_i
    , input reset_i
    // LSB->MSB
    , input rx_i
    , output logic rx_v_o
    , output logic [data_bits_p-1:0] rx_o
    , output logic rx_error_o
    );

    typedef enum logic [2:0] {
        e_reset
        , e_idle
        , e_start_bit
        , e_data_bits
        , e_parity_bit
        , e_stop_bit
        , e_finish
    } state_e;
    state_e rx_state_r, rx_state_n;

    logic [`BSG_SAFE_CLOG2(clk_per_bit_p+1)-1:0] clk_cnt_r, clk_cnt_n;
    logic [`BSG_SAFE_CLOG2(data_bits_p)-1:0] data_cnt_r, data_cnt_n;
    logic [`BSG_SAFE_CLOG2(data_bits_p)-1:0] parity_cnt_r, parity_cnt_n;

    logic data_in_r, data_in_n;
    logic data_r, data_n;
    // start bit is low
    wire rx_start = (data_r == 1'b0);
    // stop bit is high
    wire rx_stop = (data_r == 1'b1);

    logic [data_bits_p-1:0] rx_data_r, rx_data_n;
    logic rx_v_r, rx_v_n;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            rx_state_r <= e_reset;
            clk_cnt_r <= '0;
            data_cnt_r <= '0;
            data_in_r <= '0;
            data_r <= '0;
            rx_data_r <= '0;
            rx_v_r <= '0;
            parity_cnt_r <= '0;
        end else begin
            rx_state_r <= rx_state_n;
            clk_cnt_r <= clk_cnt_n;
            data_cnt_r <= data_cnt_n;
            data_in_r <= data_in_n;
            data_r <= data_n;
            rx_data_r <= rx_data_n;
            rx_v_r <= rx_v_n;
            parity_cnt_r <= parity_cnt_n;
        end
    end

    always_comb begin
        // state
        rx_state_n = rx_state_r;

        // outputs
        rx_o = rx_data_r;
        rx_v_o = rx_v_r;
        rx_error_o = 1'b0;

        // input and data buffering
        // rx_i -> data_in_r -> data_r
        data_in_n = rx_i;
        data_n = data_in_r;
        parity_cnt_n = parity_cnt_r;

        // rx valid and data registers
        rx_v_n = rx_v_r;
        rx_data_n = rx_data_r;

        // clock and data counters
        clk_cnt_n = clk_cnt_r;
        data_cnt_n = data_cnt_r;

        case (rx_state_r)
            e_reset: begin
                rx_state_n = e_idle;
            end
            e_idle: begin
                clk_cnt_n = '0;
                data_cnt_n = '0;
                rx_v_n = '0;
                rx_data_n = '0;
                parity_cnt_n = '0;
                // on start bit detected, begin transaction
                rx_state_n = rx_start ? e_start_bit : e_idle;
            end
            // check start bit half-way into expected cycles per bit
            e_start_bit: begin
                if (clk_cnt_r == (clk_per_bit_p-1)/2) begin
                    if (data_r == 1'b0) begin
                        clk_cnt_n = '0;
                        rx_state_n = e_data_bits;
                    end else begin
                        // TODO: raise an error here or ignore as transient fault?
                        rx_state_n = e_idle;
                    end
                end else begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end
            end
            e_data_bits: begin
                if (clk_cnt_r == (clk_per_bit_p - 'd1)) begin
                    clk_cnt_n = '0;
                    rx_data_n[data_cnt_r] = data_r;
                    if (parity_bit_p == 1) begin
                        parity_cnt_n = parity_cnt_r + data_r;
                    end
                    if (data_cnt_r < (data_bits_p-1)) begin
                        data_cnt_n = data_cnt_r + 'd1;
                    end else begin
                        data_cnt_n = '0;
                        rx_state_n = (parity_bit_p == 1) ? e_parity_bit : e_stop_bit;
                    end
                end else begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end
            end
            e_parity_bit: begin
                if (clk_cnt_r == (clk_per_bit_p - 'd1)) begin
                    clk_cnt_n = '0;
                    rx_state_n = e_stop_bit;
                    // raise error if captured parity bit does not match received parity
                    if (parity_odd_p == 1) begin
                      // odd parity -> parity bit set when count of ones in data
                      // bits is even (== 0), to make data + parity odd (== 1)
                      rx_error_o = (~parity_cnt_r[0] & data_r);
                    end else begin
                      // even parity -> parity bit set when count of ones in data
                      // bits is odd (== 1), to make data + parity even (== 0)
                      rx_error_o = (parity_cnt_r[0] & data_r);
                    end
                end else begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end
            end
            e_stop_bit: begin
                if (clk_cnt_r == (clk_per_bit_p - 'd1)) begin
                    clk_cnt_n = '0;
                    // error on stop bit if bit is low
                    rx_error_o = ~rx_stop;
                    // stop bits received, make data valid next cycle
                    if (data_cnt_r == stop_bits_p-1) begin
                        rx_state_n = e_finish;
                        data_cnt_n = '0;
                        rx_v_n = 1'b1;
                    // more stop bits coming
                    end else begin
                        rx_state_n = e_stop_bit;
                        data_cnt_n = data_cnt_r + 'd1;
                    end
                end else begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end
            end
            // one cycle raise rx_v_o
            e_finish: begin
                rx_state_n = e_idle;
                rx_v_n = '0;
                parity_cnt_n = '0;
            end
            default: begin
                rx_state_n = e_reset;
            end
        endcase
    end

endmodule
