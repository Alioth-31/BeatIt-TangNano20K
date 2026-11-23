`timescale 1ns/1ps
module tb_pcm_delay;
    reg clk=0, rst=1, valid=0, bypass=0;
    reg signed [15:0] sample=0;
    wire signed [15:0] result;
    wire result_valid, fault;
    integer tested=0;
    pcm_delay #(.DELAY_SAMPLES(4)) dut(clk,rst,sample,valid,bypass,result,result_valid,fault);
    always #5 clk=~clk;
    task push;
        input signed [15:0] x;
        input bp;
        input signed [15:0] expected;
        begin
            @(negedge clk); sample=x; bypass=bp; valid=1;
            @(negedge clk); valid=0;
            if(result_valid!==0) begin $display("FAIL early valid"); $finish; end
            @(negedge clk);
            if(!result_valid || result!==expected || fault) begin
                $display("FAIL delay sample=%0d output=%0d expected=%0d fault=%b",tested,result,expected,fault);
                $finish;
            end
            tested=tested+1;
            @(negedge clk);
            if(result_valid) begin $display("FAIL double valid"); $finish; end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        push(1000,0,1000);
        push(2000,0,2000);
        push(-4000,0,-4000);
        push(4000,0,4000);
        push(3000,0,3500);    // oldest dry + 50% delayed
        push(3000,0,4000);
        push(-2000,0,-4000);
        push(31000,0,32767); // saturated
        push(31000,0,32625); // history[0] = 3000+1000/4 = 3250
        push(-32768,1,-32768); // bypass preserves signed extrema
        push(0,1,0);
        push(7,0,7);           // history was flushed on entering bypass
        push(0,0,0);
        push(0,0,0);
        push(0,0,0);
        push(0,0,3);           // newest wet sample returns after four frames
        @(negedge clk); rst=1;
        repeat(3) @(negedge clk);
        if(result_valid || result!==0 || fault) begin $display("FAIL reset");$finish;end
        rst=0;
        push(700,0,700);
        push(0,0,0);
        push(0,0,0);
        push(0,0,0);
        push(0,0,350);
        // A second input while a read/write is in flight fails closed.
        @(negedge clk); sample=100; valid=1;
        @(negedge clk); sample=200; valid=1;
        @(negedge clk); valid=0;
        if(!fault || result_valid || result!==0) begin
            $display("FAIL delay input overlap fault=%b valid=%b pcm=%d",fault,result_valid,result);
            $finish;
        end
        $display("PASS pcm_delay: %0d samples, feedback, sat, bypass, startup, reset, overlap",tested);
        $finish;
    end
endmodule
