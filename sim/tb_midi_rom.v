`timescale 1ns/1ps
module tb_midi_rom;
    reg clk=0;
    reg [6:0] note=0;
    wire [31:0] increment;
    reg [31:0] previous;
    integer i;
    `include "midi_note_table.vh"
    midi_increment_rom dut(clk,note,increment);
    always #5 clk=~clk;
    initial begin
        @(negedge clk);
        for(i=0;i<128;i=i+1)begin
            previous=increment;note=i;#1;
            if(increment!==previous)$fatal(1,"MIDI lookup became asynchronous");
            @(negedge clk);
            if(increment!==midi_note_increment(i))$fatal(1,"MIDI ROM mismatch at %0d",i);
        end
        $display("PASS MIDI ROM all128 pitches and registered output");$finish;
    end
endmodule
