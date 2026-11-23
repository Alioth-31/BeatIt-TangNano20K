`timescale 1ns/1ps
// Adapt the nine DIVU arithmetic vectors from pinned PicoRV32 tests/divu.S.
// This exercises the extracted unit, not the upstream CPU test harness.
module tb_expression_divider;
    reg clk=0,resetn=0,valid=0;reg [31:0] a,b;
    wire [31:0] result;wire wr,ready,waiting;
    integer checks=0,i,cycles;reg [31:0] ra,rb;
    picorv32_pcpi_div dut(clk,resetn,valid,32'h02005033,a,b,wr,result,waiting,ready);
    always #5 clk=~clk;
    task divide;input [31:0] n,d,expected;
        begin
            a=n;b=d;valid=1;cycles=0;
            while(!ready&&cycles<40)begin @(negedge clk);cycles=cycles+1;end
            if(!ready||!wr||result!==expected)begin $display("FAIL DIVU %h / %h got%h expected%h",n,d,result,expected);$finish;end
            valid=0;checks=checks+1;repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);resetn=1;
        divide(20,6,3);divide(-20,6,715827879);divide(20,-6,0);divide(-20,-6,0);
        divide(32'h80000000,1,32'h80000000);divide(32'h80000000,32'hffffffff,0);
        divide(32'h80000000,0,32'hffffffff);divide(1,0,32'hffffffff);divide(0,0,32'hffffffff);
        for(i=0;i<1000;i=i+1)begin ra=$random;rb=$random;divide(ra,rb,rb==0 ? 32'hffffffff : ra/rb);end
        a=32'hffffffff;b=31;valid=1;repeat(12)@(negedge clk);resetn=0;valid=0;
        repeat(4)@(negedge clk);resetn=1;repeat(40)begin @(negedge clk);if(ready)begin $display("FAIL abandoned divider ready");$finish;end end
        divide(32'h0fff0000,4095,65536);
        $display("PASS pinned DIVU %0d vectors and mid-operation reset",checks);$finish;
    end
endmodule
