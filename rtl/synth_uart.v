`timescale 1ns/1ps
// 115200 8N1 at 49.152 MHz uses 427 clocks/bit (0.078% rate error).
// RX validates the start and stop centers; framing errors never expose a byte.
module synth_uart #(parameter CLOCK_HZ=49152000, parameter BAUD=115200)(
    input clk,input rst,input rx,output reg tx,
    output reg [7:0] rx_data,output reg rx_valid,output reg rx_error,
    input [7:0] tx_data,input tx_send,output reg tx_busy
);
    function integer timer_width;
        input integer value;integer v;
        begin v=value-1;timer_width=0;while(v>0) begin v=v>>1;timer_width=timer_width+1;end end
    endfunction
    localparam BIT_CLOCKS=(CLOCK_HZ+BAUD/2)/BAUD;
    localparam HALF_CLOCKS=BIT_CLOCKS/2;
    reg rx_meta,rx_sync;
    reg [1:0] rx_state;
    localparam TIMER_WIDTH=(BIT_CLOCKS<2 || BIT_CLOCKS>=32'h80000000)?32:timer_width(BIT_CLOCKS);
    reg [TIMER_WIDTH-1:0] rx_timer,tx_timer;
    reg [2:0] rx_bit;
    reg [3:0] tx_bit;
    reg [7:0] rx_shift;
    reg [9:0] tx_shift;
    always @(posedge clk) begin
        if(rst) begin
            rx_meta<=1;rx_sync<=1;rx_state<=0;rx_timer<=0;rx_bit<=0;
            rx_shift<=0;rx_data<=0;rx_valid<=0;rx_error<=0;
            tx<=1;tx_busy<=0;tx_timer<=0;tx_bit<=0;tx_shift<=10'h3ff;
        end else begin
            rx_meta<=rx;rx_sync<=rx_meta;rx_valid<=0;rx_error<=0;
            case(rx_state)
                0: if(!rx_sync) begin rx_timer<=HALF_CLOCKS-1;rx_state<=1;end
                1: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                   else if(rx_sync) rx_state<=0;
                   else begin rx_state<=2;rx_timer<=BIT_CLOCKS-1;rx_bit<=0;end
                2: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                   else begin
                       rx_shift[rx_bit]<=rx_sync;rx_timer<=BIT_CLOCKS-1;
                       if(rx_bit==7) rx_state<=3;else rx_bit<=rx_bit+1'b1;
                   end
                3: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
                   else begin
                       rx_state<=0;
                       if(rx_sync) begin rx_data<=rx_shift;rx_valid<=1;end
                       else rx_error<=1;
                   end
            endcase
            if(!tx_busy) begin
                tx<=1;
                if(tx_send) begin
                    tx_shift<={1'b1,tx_data,1'b0};tx<=0;
                    tx_busy<=1;tx_bit<=0;tx_timer<=BIT_CLOCKS-1;
                end
            end else if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
            else begin
                tx_timer<=BIT_CLOCKS-1;
                if(tx_bit==9) begin tx<=1;tx_busy<=0;end
                else begin tx_shift<={1'b1,tx_shift[9:1]};tx<=tx_shift[1];tx_bit<=tx_bit+1'b1;end
            end
        end
    end
endmodule
