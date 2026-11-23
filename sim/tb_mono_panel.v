`timescale 1ns/1ps
// Exercises the real proposal/echo and menu path, including sparse patch IDs:
//3 remains read-only custom,4 is mono; no modulo-four truncation to0.
module tb_mono_panel;
    reg clk=0,rst=1,ce=0,left=0,right=0,up=0,down=0;
    reg [2:0] current=0;
    wire [7:0] keys,preview,value;wire settings,commit,toggle;wire [2:0] field,commit_field;
    integer tick=0,checks=0;
    performance_surface #(.HOLD_SAMPLES(2)
`ifndef LEGACY_MONO_RED
        ,.MONO_ENABLED(1)
`endif
    ) dut(clk,rst,ce,8'd0,left,right,up,down,4'd0,2'd0,3'd4,current,
        1'b0,1'b0,2'd2,toggle,keys,settings,field,preview,commit,commit_field,value);
    always #5 clk=~clk;
    always @(negedge clk)begin tick=tick+1;ce=(tick%16)==0;end
    always @(posedge clk)if(!rst && commit && commit_field==0)current<=value[2:0];
    task require;input ok;input [511:0]label;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",label);$finish;end end endtask
    task turn;input direction;
        begin @(negedge clk);up=direction;down=!direction;@(negedge clk);up=0;down=0;repeat(40)@(negedge clk);end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        turn(1);turn(1);turn(1);require(current==4,"third detent selects explicit mono instead of wrapping to soft");
        turn(1);require(current==0,"mono wraps to soft");turn(0);require(current==4,"reverse enters mono");
        left=1;repeat(50)@(negedge clk);require(settings && preview==4,"menu previews full mono ID");
        turn(0);require(preview==2 && current==4,"menu preview does not prematurely change mode");
        right=1;repeat(4)@(negedge clk);right=0;repeat(35)@(negedge clk);
        require(current==2,"confirm commits the poly patch");
        left=0;repeat(35)@(negedge clk);current=3;turn(1);
        require(current==0,"custom mode advances to first selectable preset");
        $display("PASS mono panel sparse patch ring, menu preview/confirm and custom return (%0d checks)",checks);$finish;
    end
endmodule
