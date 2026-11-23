`timescale 1ns/1ps
module tb_osc_dual_mix;
    reg signed [15:0] a,b;
    wire signed [15:0] result;
    osc_dual_mix dut(.primary(a),.secondary(b),.sample_out(result));
    task check;
        input signed [15:0] x,y,z;
        begin
            a=x;b=y;#1;
            if(result!==z) begin
                $display("FAIL dual mix a=%0d b=%0d got=%0d expected=%0d",x,y,result,z);
                $finish;
            end
        end
    endtask
    initial begin
        check(16'sd0,16'sd0,16'sd0);
        check(16'sd32767,16'sd32767,16'sd32767);
        check(16'sh8000,16'sh8000,16'sh8000);
        check(16'sh8000,16'sd32767,-16'sd1);
        check(16'sd20000,-16'sd10000,16'sd5000);
        check(-16'sd1001,16'sd1000,-16'sd1);
        $display("PASS tb_osc_dual_mix");$finish;
    end
endmodule
