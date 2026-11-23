`timescale 1ns/1ps
module tb_numeric;
    reg signed [20:0] sum=0;
    reg [16:0] gain=65536;
    wire signed [15:0] pcm;
    pcm_gain #(.WIDTH(21),.SHIFT(2)) dut(sum,gain,pcm);
    initial begin
        sum=-131072; #1; if(pcm!==-32768) begin $display("FAIL negative full scale %d",pcm); $finish; end
        sum=131068; #1; if(pcm!==32767) begin $display("FAIL positive full scale"); $finish; end
        sum=500000; #1; if(pcm!==32767) begin $display("FAIL positive saturation"); $finish; end
        sum=-500000; #1; if(pcm!==-32768) begin $display("FAIL negative saturation"); $finish; end
        gain=32768; sum=-80000; #1; if(pcm!==-10000) begin $display("FAIL signed multiply"); $finish; end
        gain=0; #1; if(pcm!==0) begin $display("FAIL mute"); $finish; end
        $display("PASS widened signed mix, gain, saturation and mute"); $finish;
    end
endmodule
