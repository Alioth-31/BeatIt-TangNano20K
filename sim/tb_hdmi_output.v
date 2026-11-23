`timescale 1ns/1ps
module tb_hdmi_output;
    reg clk=0,rst=1;wire pc,vr,cp,cn;wire [2:0] dp,dn;
    hdmi_output dut(clk,rst,8'h12,8'h34,8'h56,1'b1,1'b1,1'b1,pc,vr,cp,cn,dp,dn);
    always #5 clk=~clk;
    initial begin
        repeat(4)@(negedge clk);rst=0;
        wait(!vr);
        repeat(3)@(negedge clk);
        rst=1;#1;if(!vr)$fatal(1,"pixel reset must assert asynchronously");
        repeat(2)@(negedge clk);
        if(dut.symbols[0]!==10'b1010101011)$fatal(1,"reset did not flush to control symbols");
        rst=0;repeat(9)@(negedge clk);if(vr)$fatal(1,"reset recovery");
        $display("PASS pixel reset and control-symbol flush/recovery");$finish;
    end
endmodule
