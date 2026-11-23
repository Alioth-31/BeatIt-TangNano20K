`timescale 1ns/1ps
// Breaks if source identity is used as pitch, a held source retunes, a stale
// instance re-gates either envelope, or a canceled pending instance revives.
module tb_performance_core;
    reg clk=0,rst=1,ce=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    reg edit_mapping_during_frame=0;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [3:0] active;
    integer i,j,cycles,max_cycles=0,checks=0,count,old_slot,new_slot;
    reg [31:0] phase_before;
`ifdef BASELINE_CORE
    // RED adapter: exercise the old real core before the new API exists.
    synth_core #(.NUM_VOICES(4),.DUAL_OSC_ENABLE(1),
        .INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held[31:0]),
`else
    synth_core #(.NUM_VOICES(4),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .source_midi(notes),.source_instance(instances),
`endif
        .preset(2'd2),.volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(pcm),.pcm_valid(valid),.fault(fault),.busy(busy),.active(active),
        .waveform_select(2'd0),.osc2_bend_target(17'd65536),.osc2_preset(2'd1),
        .osc1_gate_mask(32'hffffffff),.osc2_gate_mask(32'hffffffff),
        .osc_override_enable(1'b0),.osc_override_id(6'd0),.osc_override_increment(32'd0));
    always #5 clk=~clk;
    task require;
        input condition;input [639:0] message;
        begin
            checks=checks+1;
            if(condition!==1'b1) begin $display("FAIL %0s",message);$finish;end
        end
    endtask
    task frame;
        begin
            @(negedge clk);ce=1;
            @(negedge clk);ce=0;cycles=0;
            if(edit_mapping_during_frame) begin
                notes[0+:7]=74;notes[8*7+:7]=50;edit_mapping_during_frame=0;
            end
            while(!valid && cycles<1023) begin @(negedge clk);cycles=cycles+1;end
            if(cycles>max_cycles)max_cycles=cycles;
            require(valid && !fault && cycles<1023,"performance core sample deadline");
            @(negedge clk);
        end
    endtask
    task restart;
        begin
            @(negedge clk);rst=1;held=0;notes=0;instances=0;
            for(j=0;j<40;j=j+1) begin notes[j*7+:7]=60;instances[j*16+:16]=1;end
            repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);
            repeat(16)frame; // settle B's existing detune smoothing to unity
        end
    endtask
    initial begin
        restart;
        notes[0+:7]=62;notes[8*7+:7]=62;held[0]=1;held[8]=1;
        edit_mapping_during_frame=1;frame;
        require(dut.increment[0]==32'd26276679 && dut.increment_b[0]==32'd26276679,
            "MIDI D4 must drive both DDS instead of legacy source-zero C4");
        require(active==4'b0011 && dut.owner[0]==0 && dut.owner[1]==8,
            "same pitch from physical and remote sources owns separate voices");
        notes[0+:7]=74;notes[8*7+:7]=50;frame;
        require(dut.increment[0]==32'd26276679 && dut.increment[1]==32'd26276679 &&
            dut.increment_b[0]==32'd26276679 && dut.increment_b[1]==32'd26276679,
            "mapping edits preserve held-note pitch snapshots on A and B");
        held[0]=0;frame;
        require(dut.env_state[0]==4 && dut.env_state_b[0]==4 &&
            dut.env_state[1]!=4 && dut.env_state_b[1]!=4,
            "releasing physical source leaves same-pitch remote source gated");
        held[0]=1;instances[0+:16]=2;frame;
        require(dut.env_state[0]==4 && dut.env_state_b[0]==4 &&
            dut.increment[0]==32'd26276679 && dut.increment_b[0]==32'd26276679,
            "repress cannot retune or re-gate the old release instance");
        require(dut.owner[2]==0 && dut.increment[2]==32'd52553357 &&
            dut.increment_b[2]==32'd52553357,
            "new instance takes the new octave on both DDS");

        restart;
        notes[0+:7]=69;instances[0+:16]=16'hffff;held[0]=1;frame;
        instances[0+:16]=0;notes[0+:7]=81;frame;
        require(dut.env_state[0]==4 && dut.env_state_b[0]==4 &&
            dut.increment[0]==32'd39370534 && dut.increment_b[0]==32'd39370534,
            "65535-to-zero instance wrap releases old instance without changing pitch");
        require(dut.owner[1]==0 && dut.increment[1]==32'd78741067 &&
            dut.increment_b[1]==32'd78741067,
            "instance wrap while held triggers the new A5 instance");

        restart;
        held=40'hf;repeat(300)frame;
        notes[4*7+:7]=62;held[4]=1;frame;
        require(dut.env_state[0]==5 && dut.pending_owner[0]==4,"fifth source queues steal");
        // Change a live source's instance without an observed low frame. The
        // old pending event is canceled; a newer event may steal another slot.
        instances[4*16+:16]=2;notes[4*7+:7]=74;frame;
        require(!dut.pending_live[0],"instance change cancels old pending event");
        repeat(34)frame;
        count=0;new_slot=-1;
        for(i=0;i<4;i=i+1) if(active[i] && dut.owner[i]==4) begin count=count+1;new_slot=i;end
        require(count==1,"only latest instance of repressed pending source can sound");
        require(dut.increment[new_slot]==32'd52553357 && dut.increment_b[new_slot]==32'd52553357,
            "pending note keeps its own instance and MIDI snapshot on A and B");
        held[4]=0;frame;
        require(dut.env_state[new_slot]==4 && dut.env_state_b[new_slot]==4,
            "pending replacement releases both oscillator envelopes");

        restart;
        notes[0+:7]=0;notes[7+:7]=127;held=3;frame;
        require(dut.increment[0]==32'd731558 && dut.increment_b[0]==32'd731558 &&
            dut.increment[1]==32'd1122405052 && dut.increment_b[1]==32'd1122405052,
            "full MIDI range endpoints reach both DDS without source-table limits");
        $display("PASS performance core source identity, MIDI snapshots, A/B gates, pending and instance wrap (%0d checks, max=%0d)",checks,max_cycles);
        $finish;
    end
    initial begin #100000000;$display("FAIL performance core timeout");$finish;end
endmodule
