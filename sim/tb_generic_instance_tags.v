`timescale 1ns/1ps
// The public default must still detect arbitrary full-width instance tags.
module tb_generic_instance_tags;
    reg clk=0,rst=1,ce=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    wire signed [15:0] pcm;wire valid,fault,busy;wire [3:0] active;
    synth_core #(.NUM_VOICES(4),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1)) dut(
        clk,rst,ce,held,2'd2,17'd65536,17'd65536,pcm,valid,fault,busy,active,
        2'd0,17'd65536,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,notes,instances,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    task frame;
        begin @(negedge clk);ce=1;@(negedge clk);ce=0;wait(valid);@(negedge clk);end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);repeat(16)frame;
        held=1;notes[0+:7]=62;instances[0+:16]=2;frame;
        notes[0+:7]=74;instances[0+:16]=4;frame; // same parity, different public tag
        if(dut.env_state[0]!=4 || dut.env_state_b[0]!=4 || dut.owner[1]!=0 ||
            dut.increment[0]!=32'd26276679 || dut.increment_b[0]!=32'd26276679 ||
            dut.increment[1]!=32'd52553357 || dut.increment_b[1]!=32'd52553357 || fault)begin
            $display("FAIL generic instance mode must detect same-parity tag changes");$finish;
        end
        $display("PASS generic default preserves full 16-bit arbitrary-tag comparison");$finish;
    end
    initial begin #10000000;$display("FAIL generic tag timeout");$finish;end
endmodule
