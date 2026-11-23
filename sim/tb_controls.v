`timescale 1ns/1ps
module tb_controls;
    reg clk=0, rst=1, pin=1;
    wire stable;
    debounce #(.STABLE_CYCLES(8),.INITIAL_LEVEL(1)) db(clk,rst,pin,stable);
    reg [1:0] ab=2'b11;
    wire up,down;
    integer ups=0,downs=0;
    quadrature #(.FILTER_CYCLES(2),.EDGES_PER_STEP(4)) q(clk,rst,ab,up,down);
    always #5 clk=~clk;
    always @(posedge clk) begin if(up) ups=ups+1; if(down) downs=downs+1; end
    task hold; input [1:0] value; begin ab=value; repeat(10) @(negedge clk); end endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        pin=0; repeat(4) @(negedge clk); pin=1; repeat(12) @(negedge clk);
        if(stable!==1) begin $display("FAIL bounce accepted"); $finish; end
        pin=0; repeat(12) @(negedge clk);
        if(stable!==0) begin $display("FAIL stable not accepted"); $finish; end
        hold(2'b10); hold(2'b00); hold(2'b01); hold(2'b11);
        if(ups!=1 || downs!=0) begin $display("FAIL clockwise"); $finish; end
        hold(2'b01); hold(2'b00); hold(2'b10); hold(2'b11);
        if(ups!=1 || downs!=1) begin $display("FAIL reverse"); $finish; end
        hold(2'b00); hold(2'b11); hold(2'b10); hold(2'b11);
        if(ups!=1 || downs!=1) begin $display("FAIL invalid/bounce counted"); $finish; end
        $display("PASS synchronizer debounce, quadrature reverse/invalid/bounce"); $finish;
    end
endmodule
