`timescale 1ns/1ps
// Catch quantized asymmetry/stalling, overshoot, pitch jumps on retarget and
// a new phrase gliding from a stale released pitch. Constants are MIDI A4/A5.
module tb_mono_glide;
    reg clk=0,rst=1,ce=0,enable=1,gate=0,legato=0;
    reg [6:0] note=69;
    wire [31:0] increment;
    integer i,checks=0;
    reg [31:0] previous,start_pitch;
`ifdef LEGACY_MONO_RED
    `include "midi_note_table.vh"
    assign increment=midi_note_increment(note);
`else
    mono_glide dut(clk,rst,ce,enable,gate,legato,note,increment);
`endif
    always #5 clk=~clk;
    task require;
        input ok;input [767:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",label);$finish;end end
    endtask
    task frame;
        begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(5)@(negedge clk);end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        gate=1;frame;require(increment==32'd39370534,"first note snaps to A4");
        legato=1;note=81;frame;
        require(increment==32'd39370534,"retarget starts from the current pitch without jumping");
        for(i=1;i<=2048;i=i+1)begin
            previous=increment;frame;
            require(increment>=previous && increment<=32'd78741067,"upward glide monotonic without overshoot");
            require(increment==32'd39370534+(64'd39370533*i/2048),"upward glide reaches the linear interpolant");
        end
        require(increment==32'd78741067,"upward glide reaches target exactly");
        note=69;frame;
        for(i=1;i<=2048;i=i+1)begin
            previous=increment;frame;
            require(increment<=previous && increment>=32'd39370534,"downward glide monotonic without overshoot");
            require(increment==32'd78741067-(64'd39370533*i/2048),"downward glide is symmetric");
        end
        require(increment==32'd39370534,"downward glide reaches target exactly");
        note=81;frame;repeat(111)frame;start_pitch=increment;
        note=69;frame;require(increment==start_pitch,"mid-glide reversal has no discontinuity");
        repeat(2048)frame;require(increment==32'd39370534,"reversal converges exactly");
        gate=0;note=0;repeat(3)frame;require(increment==32'd39370534,"release freezes the current pitch");
        gate=1;legato=0;note=127;frame;
        require(increment==32'd1122405052,"new phrase snaps across full MIDI range");
        note=0;legato=1;frame;repeat(2048)frame;
        require(increment==32'd731558,"full-range downward glide reaches MIDI zero without wrap");
        enable=0;note=127;repeat(4)frame;
        require(increment==32'd731558,"disabled glide retains released voice pitch");
        $display("PASS mono glide linear2048, exact endpoints, bidirectional and retarget (%0d checks)",checks);$finish;
    end
endmodule
