`timescale 1ns/1ps
// Catch retriggered A/B envelopes, phase reset, extra voices and stale ownership
// during legato. Uses the production temporal RAM/DDS/ADSR path.
module tb_mono_core;
    reg clk=0,rst=1,ce=0,mono=1,legato=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    reg [31:0] glide=32'd23409859;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [31:0] active;
    integer i,j,cycles,max_cycles=0,slot,checks=0;
    reg [31:0] old_a,old_b;
    reg [24:0] level_a,level_b;
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1),
        .SEQUENTIAL_INSTANCE_ENABLE(1),.A_STATE_RAM_ENABLE(1),.TEMPORAL_STORAGE_ENABLE(1),.FREQUENCY_PIPELINE_ENABLE(1)
`ifndef LEGACY_MONO_RED
        ,.MONO_ENABLED(1)
`endif
    ) dut(.clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .source_midi(notes),.source_instance(instances),.preset(2'd2),
        .volume_target(17'd6554),.bend_target(17'd65536),
        .pcm(pcm),.pcm_valid(valid),.fault(fault),.busy(busy),.active(active),
        .waveform_select(2'd0),.osc2_bend_target(17'd65536),.osc2_preset(2'd2),
        .osc1_gate_mask(32'hffffffff),.osc2_gate_mask(32'hffffffff),
        .osc_override_enable(1'b0),.osc_override_id(6'd0),.osc_override_increment(32'd0)
`ifndef LEGACY_MONO_RED
        ,.mono_mode(mono),.mono_legato(legato),.mono_increment(glide)
`endif
    );
    always #5 clk=~clk;
    task require;
        input ok;input [767:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",label);$finish;end end
    endtask
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;cycles=0;
            while(!valid && cycles<1023)begin @(negedge clk);cycles=cycles+1;end
            require(valid && !fault && cycles<1023,"mono core frame deadline");
            if(cycles>max_cycles)max_cycles=cycles;
            repeat(1024-cycles-2)@(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<40;i=i+1)begin notes[i*7+:7]=60+i;instances[i*16+:16]=1;end
        repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);
        held=1;repeat(500)frame;
        slot=0;
        require(active==1,"first mono note uses one dual-DDS voice");
        old_a=dut.phase[slot];old_b=dut.phase_b[slot];
        level_a=dut.envelope[slot];level_b=dut.b_state_store.words[slot][27:3];
        // Priority router changes owner but never sends a zero gate between
        // overlapping notes. The actual glide value is between C4 and D4.
        held=40'h100;notes[8*7+:7]=62;legato=1;glide=32'd24000000;frame;
        require(active==1 && dut.owner[slot]==8,"overlap transfers one voice instead of allocating another");
        require(dut.increment[slot]==glide && dut.increment_b[slot]==glide,
            "independent A/B DDS use the current glide, not final MIDI target");
        require(dut.phase[slot]==old_a+glide && dut.phase_b[slot]==old_b+glide,
            "legato preserves both oscillator phases");
        require(dut.env_state[slot]==2 && dut.env_state_b[slot]==2 &&
            dut.envelope[slot]==level_a-350 && dut.b_state_store.words[slot][27:3]==level_b-350,
            "legato does not restart either attack");
        // Return to the still-held earlier key; no new attack or stolen tail.
        old_a=dut.phase[slot];held=1;glide=32'd23900000;frame;
        require(active==1 && dut.owner[slot]==0 && dut.phase[slot]==old_a+glide,
            "fallback transfers ownership and keeps phase continuous");
        held=0;legato=0;frame;
        require(dut.env_state[slot]==4 && dut.env_state_b[slot]==4,"last release closes both envelopes");
        // A separated attack must reuse/fade the releasing mono voice, not
        // allocate another release tail. New pitch applies after the fade.
        held=40'h200;notes[9*7+:7]=69;glide=32'd39370534;frame;
        require(active==1 && dut.env_state[slot]==5 && dut.increment[slot]==32'd23900000,
            "separated attack fades old pitch in the same slot");
        repeat(34)frame;
        require(active==1 && dut.owner[slot]==9 && dut.increment[slot]==32'd39370534,
            "separated note retriggers after bounded fade");
        // The routed blank frame on mode change releases mono. Its tail must
        // retain the last pitch while the usual allocator accepts a chord.
        held=0;mono=0;frame;
        held=40'h6;frame;
        require(active==7 && dut.increment[slot]==32'd39370534,
            "returning to poly accepts chords and preserves mono tail pitch");
        require(dut.env_state[slot]==4 && dut.env_state_b[slot]==4,
            "new poly keys cannot reopen the old mono release");
        @(negedge clk);rst=1;held=0;repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);
        mono=0;legato=0;held=40'h00ffffffff;repeat(30)frame;
        require(active==32'hffffffff,"full poly fixture fills all slots");
        held=0;mono=1;frame;old_a=dut.increment[0];old_b=dut.increment_b[0];
        held=40'h8000000000;notes[39*7+:7]=69;glide=32'd39370534;frame;
        require(dut.env_state[0]==5 && dut.increment[0]==old_a && dut.increment_b[0]==old_b,
            "full poly-to-mono takeover fades the old poly pitch, not uninitialized mono pitch");
        $display("PASS mono core A/B ownership, envelopes, phase, release and poly return (%0d checks, max=%0d)",checks,max_cycles);
        $finish;
    end
    initial begin #20000000;$display("FAIL mono core timeout");$finish;end
endmodule
