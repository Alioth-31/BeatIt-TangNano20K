`timescale 1ns/1ps
module tb_review_release_repress;
parameter INDEP=0;
reg clk=0,rst=1,ce=0;
reg [31:0] held=15;
wire signed [15:0] pcm;
wire valid,fault,busy;
wire [3:0] active;
integer i;
synth_core #(.DUAL_OSC_ENABLE(INDEP),.INDEPENDENT_OSC_ENABLE(INDEP)) dut(clk,rst,ce,held,2'b0,17'd65536,17'd65536,pcm,valid,fault,busy,active,2'd0,17'd66048,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,224'd0,512'd0,1'b0,1'b0,32'd0);
always #5 clk=~clk;
task frame; begin @(negedge clk); ce=1; @(negedge clk); ce=0; wait(valid); @(negedge clk); end endtask
initial begin
 repeat(4) @(negedge clk); rst=0; repeat(300) frame;
 held[3]=0; frame;
 $display("Released key 3, slot 3 state=%0d",dut.env_state[3]);
 held[3]=1; frame;
 for(i=0;i<4;i=i+1) $display("slot=%0d owner=%0d state=%0d pending=%0d age=%0d",i,dut.owner[i],dut.env_state[i],dut.pending_owner[i],dut.age[i]);
 if(dut.env_state[3] != 5 || dut.env_state[0] == 5) $display("FAIL release-priority on re-press");
 else $display("PASS release-priority on re-press");
 $finish;
end
initial begin #3000000; $display("FAIL timeout"); $finish; end
endmodule
