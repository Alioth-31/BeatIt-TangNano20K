`timescale 1ns/1ps
module tb_pcm_tremolo;
    reg clk=0, rst=1, valid=0, bypass=0;
    reg signed [15:0] input_pcm=0;
    wire signed [15:0] dry_pcm, wet_pcm;
    wire dry_valid, wet_valid;
    pcm_tremolo #(.DEPTH(0),.RATE_STEP(24'd8388608)) dry(
        clk,rst,input_pcm,valid,bypass,dry_pcm,dry_valid);
    pcm_tremolo #(.DEPTH(255),.RATE_STEP(24'd8388608)) wet(
        clk,rst,input_pcm,valid,bypass,wet_pcm,wet_valid);
    always #5 clk=~clk;

    task send;
        input signed [15:0] value;
        begin
            @(negedge clk); input_pcm=value; valid=1;
            @(posedge clk); #1;
            if (!dry_valid || !wet_valid || dry_pcm !== value) begin
                $display("FAIL strobe/unity %d dry=%d",value,dry_pcm); $finish;
            end
            @(negedge clk); valid=0;
            @(posedge clk); #1;
            if (dry_valid || wet_valid) begin $display("FAIL duplicate valid"); $finish; end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst=0;
        send(16'sd16384);
        if (wet_pcm !== 16'sd0) begin $display("FAIL full depth minimum %d",wet_pcm); $finish; end
        send(16'sd16384);
        if (wet_pcm < 16'sd16380 || wet_pcm > 16'sd16384) begin
            $display("FAIL full depth maximum %d",wet_pcm); $finish;
        end
        send(-16'sd12345);
        if (wet_pcm !== 16'sd0) begin $display("FAIL full depth half-cycle %d",wet_pcm); $finish; end
        bypass=1;
        send(-16'sd12345);
        if (wet_pcm !== -16'sd12345) begin $display("FAIL bypass"); $finish; end
        @(negedge clk); rst=1;
        @(posedge clk); #1;
        if (dry_valid || wet_valid || dry_pcm!==0 || wet_pcm!==0) begin
            $display("FAIL reset"); $finish;
        end
        $display("PASS tremolo unity, LFO range, sample strobe, bypass and reset");
        $finish;
    end
endmodule
