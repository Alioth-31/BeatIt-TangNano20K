`timescale 1ns/1ps
module tb_pending_retrigger;
    parameter INDEP=0;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=15;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [3:0] active;
    integer i,count;
    synth_core #(.DUAL_OSC_ENABLE(INDEP),.INDEPENDENT_OSC_ENABLE(INDEP)) dut(clk,rst,ce,held,2'b0,17'd65536,17'd65536,pcm,valid,fault,busy,active,2'd0,17'd66048,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,224'd0,512'd0,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    task frame; begin @(negedge clk); ce=1; @(negedge clk); ce=0; wait(valid); @(negedge clk); end endtask
    initial begin
        repeat(4) @(negedge clk); rst=0; repeat(300) frame;
        held[4]=1; frame;
        held[4]=0; frame;
        held[4]=1; frame;
        repeat(34) frame;
        count=0;
        for(i=0;i<4;i=i+1) if(active[i] && dut.owner[i]==4) count=count+1;
        if(count!=1) begin $display("FAIL stale pending note revived after re-press: %d",count); $finish; end
        $display("PASS canceled pending note does not revive on re-press"); $finish;
    end
endmodule
