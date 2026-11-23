`timescale 1ns/1ps
module tb_pcm_dc_block;
    reg clk=0,rst=1,valid=0,bypass=0;
    reg signed [15:0] sample=0;
    wire signed [15:0] out;
    wire out_valid;
    integer k;
    pcm_dc_block dut(clk,rst,sample,valid,bypass,out,out_valid);
    always #5 clk=~clk;
    task push;
        input signed [15:0] value;
        input bp;
        begin
            @(negedge clk); sample=value; bypass=bp; valid=1;
            @(posedge clk); #1;
            if(!out_valid || (bp && out!==value)) begin
                $display("FAIL DC strobe/bypass out=%d expect=%d",out,value); $finish;
            end
            @(negedge clk); valid=0;
            @(posedge clk); #1;
            if(out_valid) begin $display("FAIL DC duplicate strobe"); $finish; end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        push(10000,0);
        if(out<9990 || out>10000) begin $display("FAIL DC first transient %d",out); $finish; end
        for(k=0;k<12000;k=k+1) push(10000,0);
        if(out < -2 || out > 2) begin $display("FAIL DC not removed %d",out); $finish; end
        push(-32768,1);
        if(out!==-16'sd32768) begin $display("FAIL DC bypass negative full-scale"); $finish; end
        push(-32768,0);
        if(out!==-16'sd32768) begin $display("FAIL DC output saturation %d",out); $finish; end
        @(negedge clk); rst=1;
        @(posedge clk); #1;
        if(out!==0 || out_valid) begin $display("FAIL DC reset"); $finish; end
        $display("PASS pcm_dc_block: DC rejection, transient, signed sat, bypass, reset"); $finish;
    end
endmodule
