`timescale 1ns/1ps
// Same generated MIDI increments as midi_note_table.vh, one clock later.
// Reuses the project's synchronous ROM inference pattern from sine_rom_pair.
module midi_increment_rom(input clk,input [6:0] note,output reg [31:0] increment);
    (* syn_romstyle="block_rom" *) reg [31:0] steps[0:127];
    initial $readmemh("rtl/midi_increment.hex",steps);
    always @(posedge clk)increment<=steps[note];
endmodule
