`timescale 1ns/1ps
module tb_rom;
    reg clk=0;
    reg [9:0] a=0,b=0;
    wire signed [15:0] qa,qb;
    reg [15:0] expected [0:1023];
    integer i;
    sine_rom_pair dut(clk,a,b,qa,qb);
    always #5 clk=~clk;
    initial begin
        $readmemh("rtl/sine.hex",expected);
        repeat(2) @(negedge clk);
        for(i=0;i<1024;i=i+1) begin
            a=i; b=1023-i; @(posedge clk); #1;
            if(qa!==expected[i] || qb!==expected[1023-i]) begin $display("FAIL ROM address %d a=%h b=%h",i,qa,qb); $finish; end
            @(negedge clk);
        end
        $display("PASS both ROM ports, all 1024 addresses and signed initialization"); $finish;
    end
endmodule
