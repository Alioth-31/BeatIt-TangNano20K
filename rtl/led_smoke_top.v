`timescale 1ns/1ps
// M0 uses the fixed onboard 27 MHz oscillator, independent of MS5351 setup.
module led_smoke_top(input clk_27m, input reset_button, output [5:0] led_n, output PA_EN);
    reg [24:0] count=0;
    always @(posedge clk_27m) if(reset_button) count<=0; else count<=count+1'b1;
    assign led_n=~count[24:19];
    assign PA_EN=0;
endmodule
