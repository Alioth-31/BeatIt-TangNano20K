`timescale 1ns/1ps
// Finite linear increment interpolation: 2**SHIFT updates after retarget.
// Quotient/remainder accumulation avoids division hardware and directional
// rounding bias. Reuses the existing verified MIDI DDS lookup.
module mono_glide #(parameter SHIFT=11)(
    input clk,input rst,input sample_ce,input enable,input gate,input legato,
    input [6:0] note,output reg [31:0] increment);
    `include "midi_note_table.vh"
    reg pending,snap,descending;
    reg [31:0] requested,target,step;
    reg [SHIFT-1:0] fraction,error;
    reg [SHIFT:0] remaining;
    wire [31:0] distance=(requested>=increment)?requested-increment:increment-requested;
    wire [SHIFT:0] error_sum={1'b0,error}+{1'b0,fraction};
    wire [31:0] movement=step+error_sum[SHIFT];
    always @(posedge clk)begin
        if(rst)begin
            increment<=0;pending<=0;snap<=0;descending<=0;
            requested<=0;target<=0;step<=0;fraction<=0;error<=0;remaining<=0;
        end else begin
            pending<=0;
            if(sample_ce && enable && gate)begin
                requested<=midi_note_increment(note);snap<=!legato;pending<=1;
            end
            if(pending)begin
                if(snap)begin increment<=requested;target<=requested;remaining<=0;error<=0;end
                else if(requested!=target)begin
                    target<=requested;descending<=requested<increment;
                    step<=distance>>SHIFT;fraction<=distance[SHIFT-1:0];error<=0;
                    remaining<={1'b1,{SHIFT{1'b0}}};
                end else if(remaining!=0)begin
                    increment<=(remaining==1)?target:(descending?increment-movement:increment+movement);
                    error<=error_sum[SHIFT-1:0];remaining<=remaining-1'b1;
                end
            end
        end
    end
endmodule
