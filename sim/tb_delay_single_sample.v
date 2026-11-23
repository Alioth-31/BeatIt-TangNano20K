`timescale 1ns/1ps
module tb_delay_single_sample;
    reg clk=0, rst=1, valid=0, bypass=0;
    reg signed [15:0] din=0;
    wire signed [15:0] dout;
    wire ov, fault;
    pcm_delay #(.DELAY_SAMPLES(1),.WET_SHIFT(1),.FEEDBACK_SHIFT(2)) dut(
        .clk(clk),.rst(rst),.in_pcm(din),.in_valid(valid),.bypass(bypass),
        .out_pcm(dout),.out_valid(ov),.fault(fault));
    always #5 clk=~clk;
    task push;
        input signed [15:0] x;
        input bp;
        input signed [15:0] expected;
        begin
            @(negedge clk); din=x; bypass=bp;valid=1;
            @(negedge clk);valid=0;
            @(negedge clk);
            if (ov!==1'b1 || dout!==expected || fault!==1'b0) begin
                $display("FAIL single-tap delay: got %0d expected %0d fault=%b",dout,expected,fault);
                $finish;
            end
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        push(1000,0,1000);
        push(0,0,500);
        push(0,0,125);
        push(2000,1,2000);
        push(0,0,0);
        push(0,0,0);
        $display("PASS one-sample delay, feedback and dry/wet reset");
        $finish;
    end
endmodule
