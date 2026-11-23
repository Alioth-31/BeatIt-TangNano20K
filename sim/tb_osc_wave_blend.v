`timescale 1ns/1ps
// Test blend endpoints, signed extreme values, and smooth monotonic weights.
module tb_osc_wave_blend;
    reg signed [15:0] a,b;
    reg [5:0] left;
    wire signed [15:0] y;
    integer i;
    reg signed [15:0] previous;
    osc_wave_blend dut(a,b,left,y);
    initial begin
        a=-16'sd32768; b=16'sd32767;
        left=32;#1;
        if(y!==a) begin $display("FAIL left endpoint %0d",y);$finish;end
        left=16;#1;
        if(y!==-16'sd1) begin $display("FAIL signed midpoint %0d",y);$finish;end
        left=0;#1;
        if(y!==b) begin $display("FAIL right endpoint %0d",y);$finish;end
        previous=a;
        for(i=31;i>=0;i=i-1) begin
            left=i;#1;
            if(y<previous || y<a || y>b) begin
                $display("FAIL monotonic at %0d: %0d",i,y);$finish;
            end
            previous=y;
        end
        a=16'sd32767;b=-16'sd32768;
        left=16;#1;
        if(y!==-16'sd1) begin $display("FAIL inverse midpoint %0d",y);$finish;end
        a=-16'sd10000;b=-16'sd3000;
        left=16;#1;
        if(y!==-16'sd6500) begin $display("FAIL negative arithmetic %0d",y);$finish;end
        $display("PASS signed waveform crossfade endpoints, bounds, 32 weights");
        $finish;
    end
endmodule
