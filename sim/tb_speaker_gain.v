`timescale 1ns/1ps
module tb_speaker_gain;
    reg clk=0,rst=1,valid=0;
    reg signed [15:0] source=0;
    wire signed [15:0] result;
    wire result_valid;
    integer input_code,expected;
    pcm_speaker_gain dut(clk,rst,source,valid,result,result_valid);
    always #5 clk=~clk;
    task sample;
        input signed [15:0] value;
        begin
            @(negedge clk); source=value; valid=1;
            @(posedge clk); #1;
            if(!result_valid)$fatal(1,"speaker stage lost sample");
        end
    endtask
    initial begin
        @(negedge clk);rst=0;
        for(input_code=-32768;input_code<32768;input_code=input_code+1)begin
            sample(input_code);
            expected=4*input_code;
            if(expected>32767)expected=32767;
            if(expected< -32768)expected=-32768;
            if($signed(result)!=expected)$fatal(1,"nonlinear output at %0d: %0d instead of %0d",input_code,result,expected);
        end
        @(negedge clk);valid=0;rst=1;
        @(posedge clk);#1;
        if(result_valid||result!=0)$fatal(1,"reset must mute");
        $display("PASS exhaustive signed linear speaker gain, rail saturation and reset");$finish;
    end
endmodule
