`timescale 1ns/1ps
// Optional first-order DC blocker. The pole is 1 - 2^-10 per 48-kHz sample
// (about 7.5 Hz). An 8-bit fraction retains sub-LSB DC estimates.
// One output pulse per input pulse, with one FPGA-clock pipeline delay.
module pcm_dc_block(
    input clk, input rst,
    input signed [15:0] in_pcm,
    input in_valid, input bypass,
    output reg signed [15:0] out_pcm,
    output reg out_valid
);
    reg signed [31:0] dc_q8;
    wire signed [31:0] x_q8 = $signed({{16{in_pcm[15]}},in_pcm}) <<< 8;
    wire signed [31:0] error_q8 = x_q8 - dc_q8;
    wire signed [31:0] step_q8 = (error_q8 > 0 && (error_q8 >>> 10) == 0)
                                 ? 32'sd1 : (error_q8 >>> 10);
    wire signed [31:0] highpass = error_q8 >>> 8;
    reg signed [15:0] filtered;
    always @* begin
        if (highpass > 32'sd32767) filtered = 16'sh7fff;
        else if (highpass < -32'sd32768) filtered = 16'sh8000;
        else filtered = highpass[15:0];
    end
    always @(posedge clk) begin
        if (rst) begin
            dc_q8 <= 0;
            out_pcm <= 0;
            out_valid <= 0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                dc_q8 <= dc_q8 + step_q8;
                out_pcm <= bypass ? in_pcm : filtered;
            end
        end
    end
endmodule
