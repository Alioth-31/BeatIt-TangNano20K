`timescale 1ns/1ps
module tb_i2s;
    reg clk=0, rst=1, valid=0;
    reg signed [15:0] pcm=16'h9234;
    wire ce, bclk, ws, sd, fault, ready;
    integer cycles=0, last_ce=0, pulses=0, bitno=0, words=0;
    reg [31:0] word_data=0;
    reg last_ws=0, aligned=0, delay_bit=0;
    reg [15:0] expect_pcm=16'h9234;
    i2s_tx dut(clk,rst,pcm,valid,ce,bclk,ws,sd,fault,ready);
    always #5 clk=~clk;
    always @(posedge clk) begin
        if (!rst) begin
            cycles=cycles+1;
            valid <= 0;
            if(ce) begin
                if(pulses>0 && cycles-last_ce != 1024) begin $display("FAIL sample period"); $finish; end
                pulses=pulses+1; last_ce=cycles;
                if(pulses<8) valid<=1;
            end
        end
    end
    // Independent I2S receiver: WS edge accompanies the preceding slot's LSB.
    always @(posedge bclk) begin
        if (!rst) begin
            if (ws != last_ws) begin
                if(aligned && bitno!=31) begin $display("FAIL slot width %d",bitno); $finish; end
                last_ws=ws; aligned=1; bitno=0; word_data=0;
            end else if(aligned) begin
                word_data={word_data[30:0],sd}; bitno=bitno+1;
                if(bitno==16 && words<10 && ready) begin
                    if(word_data[15:0]!==expect_pcm) begin $display("FAIL sample %h",word_data); $finish; end
                    words=words+1;
                end
                if(bitno>16 && sd!==0) begin $display("FAIL padding"); $finish; end
            end
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst=0;
        wait(pulses==7); if(fault || words<8) begin $display("FAIL normal stream"); $finish; end
        aligned=0;
        wait(pulses==10); #1;
        if(!fault || ready) begin $display("FAIL underflow not muted"); $finish; end
        rst=1; repeat(3) @(negedge clk);
        if(sd!==0 || fault!==0) begin $display("FAIL reset"); $finish; end
        $display("PASS I2S 32-bit slots, signed PCM, frame rate, underflow/reset"); $finish;
    end
    initial begin #200000; $display("FAIL timeout"); $finish; end
endmodule
