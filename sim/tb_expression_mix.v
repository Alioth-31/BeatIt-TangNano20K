`timescale 1ns/1ps
module tb_expression_mix;
    reg clk=0,rst=1,ce=0;
    reg [16:0] volume=6554,a=65536,b=66048,gain=65536,pitch=65536;
    wire [16:0] out_volume,out_a,out_b;wire busy,fault;
    integer i,j,checks=0;reg [16:0] ev=0,ea=65536,eb=65536;
    reg [16:0] old_v,old_a,old_b;reg [63:0] wide;
    expression_mix dut(clk,rst,ce,volume,a,b,gain,pitch,out_volume,out_a,out_b,busy,fault);
`ifdef GOWIN_PRIMITIVES
    GSR GSR(.GSRI(1'b1));
`endif
    always #5 clk=~clk;
    function [16:0] ratio;input [16:0] left,right;reg [63:0] p;
        begin p=left;p=p*right;p=p/65536;ratio=p>131071 ? 17'd131071 : p[16:0];end
    endfunction
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;
            if(out_volume!==ev||out_a!==ea||out_b!==eb||fault)begin
                $display("FAIL mix check%0d got%0d/%0d/%0d expected%0d/%0d/%0d fault%b",checks,out_volume,out_a,out_b,ev,ea,eb,fault);$finish;
            end
            checks=checks+1;old_v=out_volume;old_a=out_a;old_b=out_b;
            wide=(volume>65536 ? 65536 : volume);wide=wide*(gain>65536 ? 65536 : gain);ev=wide/65536;
            ea=ratio(a,pitch);eb=ratio(b,pitch);
            // Live changes between sample boundaries must not alter the snapshot.
            volume=0;a=1;b=2;gain=0;pitch=0;
            for(j=0;j<32;j=j+1)begin
                @(negedge clk);
                if(out_volume!==old_v||out_a!==old_a||out_b!==old_b)begin $display("FAIL mix changed outside sample boundary");$finish;end
            end
            if(busy)begin $display("FAIL mix deadline");$finish;end
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;
        frame();volume=6554;a=65536;b=66048;gain=32768;pitch=73562;frame();
        volume=65536;gain=65536;a=131071;b=1;pitch=131071;frame();
        for(i=0;i<1000;i=i+1)begin volume=$random;a=$random;b=$random;gain=$random;pitch=$random;frame();end
        volume=6554;a=65536;b=66048;gain=65536;pitch=65536;frame();frame();
        @(negedge clk);ce=1;@(negedge clk);ce=0;@(negedge clk);ce=1;@(negedge clk);ce=0;
        if(!fault||out_volume!=0||out_a!=65536||out_b!=65536)begin $display("FAIL mix overrun mute");$finish;end
        rst=1;repeat(3)@(negedge clk);rst=0;
        if(fault||busy||out_volume!=0)begin $display("FAIL mix reset");$finish;end
        $display("PASS expression mix %0d snapshots, A/B independence, signed-DSP bounds, overrun mute",checks);$finish;
    end
endmodule
