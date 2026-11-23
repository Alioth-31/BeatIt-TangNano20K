`timescale 1ns/1ps
// Short project-specific exercises, in absolute MIDI pitches, not PCM.
// Word: duration16ths[5:0], gate16ths[5:0], count[1:0], three MIDI7 notes.
// Tiny table uses logic rather than consuming scarce audio BSRAM.
module guide_song_rom(input song,input [3:0] address,
    output reg [34:0] event_word,output [4:0] length) /* synthesis syn_romstyle="logic" */;
    assign length=song ? 5'd8 : 5'd16;
    function [34:0] event_data;
        input [5:0] duration,gate;input [1:0] count;input [6:0] n0,n1,n2;
        begin event_data={duration,gate,count,n2,n1,n0};end
    endfunction
    always @* begin
        event_word=event_data(4,0,0,0,0,0);
        if(!song)case(address)
            0:event_word=event_data(4,3,1,60,0,0);
            1:event_word=event_data(4,4,1,60,0,0);
            2:event_word=event_data(4,4,1,62,0,0);
            3:event_word=event_data(4,4,1,64,0,0);
            4:event_word=event_data(4,4,1,65,0,0);
            5:event_word=event_data(4,4,1,67,0,0);
            6:event_word=event_data(8,8,1,69,0,0);
            7:event_word=event_data(4,0,0,0,0,0);
            8:event_word=event_data(4,4,1,72,0,0);
            9:event_word=event_data(4,4,1,71,0,0);
            10:event_word=event_data(4,4,1,69,0,0);
            11:event_word=event_data(4,4,1,67,0,0);
            12:event_word=event_data(4,4,1,65,0,0);
            13:event_word=event_data(4,4,1,64,0,0);
            14:event_word=event_data(8,8,1,60,0,0);
            15:event_word=event_data(4,0,0,0,0,0);
        endcase
        else case(address)
            0:event_word=event_data(8,8,3,60,64,67);
            1:event_word=event_data(4,0,0,0,0,0);
            2:event_word=event_data(8,8,3,65,69,72);
            3:event_word=event_data(4,0,0,0,0,0);
            4:event_word=event_data(8,8,3,62,67,71);
            5:event_word=event_data(4,0,0,0,0,0);
            6:event_word=event_data(8,8,3,60,64,67);
            7:event_word=event_data(4,0,0,0,0,0);
        endcase
    end
endmodule
