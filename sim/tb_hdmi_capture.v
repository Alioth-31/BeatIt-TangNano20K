`timescale 1ns/1ps
module tb_hdmi_capture #(parameter W=64);
    reg ac=0,vc=0,rst=1,valid=0,tick=0;reg [W-1:0] state=128'hfedcba9876543210123456789abcdef0;
    reg signed [15:0] pcm=0;reg [8:0] address=0;
    wire [W-1:0] visible;wire [7:0] wave;wire ready;
    integer i;reg [W-1:0] saved;
    hdmi_capture #(.STATE_WIDTH(W)) dut(ac,rst,state,pcm,valid,vc,rst,tick,address,visible,wave,ready,);
    always #7 ac=~ac;always #11 vc=~vc;
    task boundary;begin @(negedge vc);tick=1;@(negedge vc);tick=0;end endtask
    task samples;input [7:0] base;integer n;begin
        for(n=0;n<512;n=n+1)begin @(negedge ac);pcm={(base+n[7:0]),8'b0};valid=1;end
        @(negedge ac);valid=0;
    end endtask
    initial begin
        repeat(5)@(negedge vc);rst=0;boundary;
        repeat(12)@(negedge ac);samples(8'h20);repeat(10)@(negedge vc);
        if(ready)$fatal(1,"published outside frame boundary");
        boundary;if(!ready || visible!==state)$fatal(1,"coherent state publish");
        saved=visible;state=~state;
        repeat(12)@(negedge ac);
        // A new capture writes the opposite bank while the old frame is read.
        fork samples(8'h80);
        begin for(i=0;i<80;i=i+1)begin @(negedge vc);address=i;repeat(2)@(negedge vc);
            if(wave!==(8'h20+i[7:0]) || visible!==saved)$fatal(1,"display bank changed while acquiring");end end
        join
        repeat(10)@(negedge vc);boundary;
        if(visible!==state)$fatal(1,"next coherent state");
        address=9'd511;repeat(3)@(negedge vc);
        if(wave!==8'h7f)$fatal(1,"last captured sample %h",wave);
        rst=1;repeat(4)@(negedge vc);if(ready)$fatal(1,"reset exposes old buffer");
        $display("PASS asynchronous snapshot, immutable banks, frame publish/reset");$finish;
    end
    initial begin #200000;$fatal(1,"capture timeout");end
endmodule
