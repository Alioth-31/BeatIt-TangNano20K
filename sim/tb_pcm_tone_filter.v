`timescale 1ns/1ps
module tb_pcm_tone_filter;
    reg clk=0,rst=1,valid=0;
    reg signed [15:0] pcm=0;
    reg [1:0] mode=0;
    wire signed [15:0] y;
    wire y_valid;
    integer k;
    pcm_tone_filter dut(clk,rst,pcm,valid,mode,y,y_valid);
    always #5 clk=~clk;
    task push;
        input signed [15:0] x;
        input [1:0] m;
        input signed [15:0] expected;
        begin
            @(negedge clk); pcm=x; mode=m; valid=1;
            @(negedge clk);
            if(!y_valid || y!==expected) begin
                $display("FAIL tone mode=%0d got=%0d expected=%0d",m,y,expected);$finish;
            end
            valid=0;
            @(negedge clk);
            if(y_valid) begin $display("FAIL duplicated tone valid");$finish;end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        push(1000,0,1000);        // unity dry and state tracks input
        push(0,1,750);           // shift 2: 1000 - 250
        push(0,2,656);           // 750 + (-750 >>> 3) = 656
        // A mode switch while running must not require reset.
        push(-32768,0,-32768);    // bypass tracks negative input exactly
        push(32767,3,-28673);    // -32768 + (65535 >>> 4) = -28673
        $display("PASS tone modes, signed input, state continuity and pulse semantics");
        $finish;
    end
endmodule
