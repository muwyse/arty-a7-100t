/**
 * UART Transmitter
 * UART message = 1 start bit, 5-9 data bits, [1 parity bit], 1 or 2 stop bits
 * start bit is low, stop bit is high
 *
 */

`include "bp_common_defines.svh"

module uart_tx
    #(parameter clk_per_bit_p = 10416 // 100 MHz clock / 9600 Baud
      , parameter data_bits_p = 8 // between 5 and 9 bits
      , parameter parity_bit_p = 0 // 0 or 1
      , parameter parity_odd_p = 0 // 0 for even parity, 1 for odd parity
      , parameter stop_bits_p = 1 // 1 or 2
      )
    (input clk_i
    , input reset_i
    // raise for 1 cycle with valid tx_i data
    , input tx_v_i
    , input [data_bits_p-1:0] tx_i
    , output logic tx_ready_and_o
    , output logic tx_v_o
    , output logic tx_o
    // raised for 1 cycle when transmit complete
    , output logic tx_done_o
    );

    typedef enum logic [2:0] {
        e_reset
        , e_idle
        , e_start_bit
        , e_data_bits
        , e_parity_bit
        , e_stop_bit
    } state_e;
    state_e tx_state_r, tx_state_n;

    logic [`BSG_SAFE_CLOG2(clk_per_bit_p+1)-1:0] clk_cnt_r, clk_cnt_n;
    logic [`BSG_SAFE_CLOG2(data_bits_p)-1:0] data_cnt_r, data_cnt_n;
    logic [`BSG_SAFE_CLOG2(data_bits_p)-1:0] parity_cnt_r, parity_cnt_n;

    // transmit LSB->MSB
    logic [data_bits_p-1:0] tx_data_r, tx_data_n;
    logic tx_r, tx_n;
    logic tx_v_r, tx_v_n;
    logic tx_done_r, tx_done_n;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            tx_state_r <= e_reset;
            clk_cnt_r <= '0;
            data_cnt_r <= '0;
            tx_data_r <= '0;
            // tx bit is default high
            tx_r <= 1'b1;
            tx_v_r <= '0;
            tx_done_r <= '0;
            parity_cnt_r <= '0;
        end else begin
            tx_state_r <= tx_state_n;
            clk_cnt_r <= clk_cnt_n;
            data_cnt_r <= data_cnt_n;
            tx_data_r <= tx_data_n;
            tx_r <= tx_n;
            tx_v_r <= tx_v_n;
            tx_done_r <= tx_done_n;
            parity_cnt_r <= parity_cnt_n;
        end
    end

    assign tx_o = tx_r;
    assign tx_v_o = tx_v_r;
    assign tx_done_o = tx_done_r;

    always_comb begin
        // state
        tx_state_n = tx_state_r;

        tx_data_n = tx_data_r;
        tx_n = tx_r;
        tx_v_n = tx_v_r;
        tx_done_n = tx_done_r;
        parity_cnt_n = parity_cnt_r;

        clk_cnt_n = clk_cnt_r;
        data_cnt_n = data_cnt_r;

        // outputs
        tx_ready_and_o = '0;

        case (tx_state_r)
            e_reset: begin
                tx_state_n = e_idle;
                tx_n = 1'b1;
            end
            // waiting for valid data in
            e_idle: begin
                // hold stop bit
                tx_n = tx_r;
                tx_v_n = '0;
                tx_done_n = '0;
                clk_cnt_n = '0;
                data_cnt_n = '0;
                parity_cnt_n = '0;
                // ready to accept data
                tx_ready_and_o = 1'b1;
                // valid input raised, capture data
                // next cycle starts sending start bit
                if (tx_v_i == 1'b1) begin
                    tx_v_n = 1'b1;
                    tx_data_n = tx_i;
                    // start bit is low
                    tx_state_n = e_start_bit;
                    tx_n = 1'b0;
                end
            end
            // sending start bit
            e_start_bit: begin
                // start bit is low
                tx_n = 1'b0;
                if (clk_cnt_r < clk_per_bit_p-1) begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end else begin
                    // start bit done, send data bits starting next cycle
                    clk_cnt_n = '0;
                    tx_state_n = e_data_bits;
                    tx_n = tx_data_r[data_cnt_r];
                end
            end
            // sending data bits
            e_data_bits: begin
                // send data bit
                tx_n = tx_data_r[data_cnt_r];
                if (clk_cnt_r < clk_per_bit_p-1) begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                end else begin
                    // current bit done, reset clock counter
                    clk_cnt_n = '0;
                    if (parity_bit_p == 1) begin
                        parity_cnt_n = parity_cnt_r + tx_data_r;
                    end
                    // more bits to send, stay in state, increment bit count
                    if (data_cnt_r < (data_bits_p-1)) begin
                        data_cnt_n = data_cnt_r + 'd1;
                    // last bit done
                    end else begin
                        // reset bit count
                        data_cnt_n = '0;
                        if (parity_bit_p == 1) begin
                            tx_state_n = e_parity_bit;
                            if (parity_odd_p == 1) begin
                              // odd parity -> parity bit set when count of ones in data
                              // bits is even (== 0), to make data + parity odd (== 1)
                              tx_n = ~parity_cnt_n[0];
                            end else begin
                              // even parity -> parity bit set when count of ones in data
                              // bits is odd (== 1), to make data + parity even (== 0)
                              tx_n = parity_cnt_n[0];
                            end
                        end else begin
                            // stop bits are high
                            tx_state_n = e_stop_bit;
                            tx_n = 1'b1;
                        end
                    end
                end
            end
            // sending parity bit
            e_parity_bit: begin
                if (parity_odd_p == 1) begin
                  // odd parity -> parity bit set when count of ones in data
                  // bits is even (== 0), to make data + parity odd (== 1)
                  tx_n = ~parity_cnt_r[0];
                end else begin
                  // even parity -> parity bit set when count of ones in data
                  // bits is odd (== 1), to make data + parity even (== 0)
                  tx_n = parity_cnt_r[0];
                end
                if (clk_cnt_r < (clk_per_bit_p - 1)) begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                // done sending parity bit, move to stop bits
                end else begin
                    clk_cnt_n = '0;
                    // reset parity bit
                    parity_cnt_n = 1'b0;
                    // send stop bit; stop bit is high
                    tx_state_n = e_stop_bit;
                    tx_n = 1'b1;
                end
            end
            // sending stop bits
            e_stop_bit: begin
                // stop bit is high
                tx_n = 1'b1;
                if (clk_cnt_r < clk_per_bit_p-1) begin
                    clk_cnt_n = clk_cnt_r + 'd1;
                // done sending stop bit
                end else begin
                    clk_cnt_n = '0;
                    // stop bits sent
                    if (data_cnt_r == stop_bits_p-1) begin
                        tx_state_n = e_idle;
                        // transaction done
                        // one cycle with tx_done_o raised
                        tx_done_n = 1'b1;
                        tx_v_n = 1'b0;
                        data_cnt_n = '0;
                    // more stop bits coming
                    end else begin
                        tx_state_n = e_stop_bit;
                        data_cnt_n = data_cnt_r + 'd1;
                    end
                end
            end
            default: begin
                tx_state_n = e_reset;
            end
        endcase
    end

endmodule
