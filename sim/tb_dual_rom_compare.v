`timescale 1ns/1ps
// Functional equivalence of shared and duplicated synchronous sine ROM.
// Captures independently timed pcm_valid strobes and compares PCM bit-for-bit.
module tb_dual_rom_compare;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0;
    wire signed [15:0] p_shared,p_separate;
    wire v_shared,v_separate,f_shared,f_separate,b_shared,b_separate;
    wire [3:0] active_shared,active_separate;
    reg signed [15:0] last_shared,last_separate;
    reg seen_shared,seen_separate;
    integer count,frame_index;
    synth_core #(.NUM_VOICES(4),.DUAL_OSC_ENABLE(1),
                 .OSC2_WAVEFORM(0),.OSC2_SHARE_ROM(1)) shared(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),.preset(2'd0),
        .volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(p_shared),.pcm_valid(v_shared),.fault(f_shared),.busy(b_shared),
        .active(active_shared),.waveform_select(2'd0),.source_midi(224'd0),.source_instance(512'd0));
    synth_core #(.NUM_VOICES(4),.DUAL_OSC_ENABLE(1),
                 .OSC2_WAVEFORM(0),.OSC2_SHARE_ROM(0)) separate(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),.preset(2'd0),
        .volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(p_separate),.pcm_valid(v_separate),.fault(f_separate),.busy(b_separate),
        .active(active_separate),.waveform_select(2'd0),.source_midi(224'd0),.source_instance(512'd0));
    always #5 clk=~clk;
    task frame;
        begin
            @(negedge clk);ce=1;
            @(negedge clk);ce=0;
            seen_shared=0;seen_separate=0;count=0;
            while(!(seen_shared && seen_separate) && count<900) begin
                @(negedge clk);count=count+1;
                if(v_shared) begin seen_shared=1;last_shared=p_shared;end
                if(v_separate) begin seen_separate=1;last_separate=p_separate;end
            end
            if(count>=900 || f_shared || f_separate || last_shared!==last_separate) begin
                $display("FAIL shared ROM frame=%0d count=%0d shared=%0d separate=%0d faults=%b%b",
                         frame_index,count,last_shared,last_separate,f_shared,f_separate);
                $finish;
            end
            repeat(1024-count-2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        held=32'h0000000f;
        for(frame_index=0;frame_index<16;frame_index=frame_index+1) frame;
        $display("PASS tb_dual_rom_compare shared ROM == duplicated ROM");$finish;
    end
endmodule
