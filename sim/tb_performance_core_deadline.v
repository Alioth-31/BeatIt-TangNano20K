`timescale 1ns/1ps
// All 40 source events in the full 32-slot/64-DDS scheduling path.
module tb_performance_core_deadline;
    reg clk=0,rst=1,ce=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [31:0] active;
    integer i,f,cycles,max_cycles=0,commits=0,nonzero=0;
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .source_midi(notes),.source_instance(instances),.preset(2'd2),
        .volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(pcm),.pcm_valid(valid),.fault(fault),.busy(busy),.active(active),
        .waveform_select(2'd1),.osc2_bend_target(17'd66048),.osc2_preset(2'd1),
        .osc1_gate_mask(32'hffffffff),.osc2_gate_mask(32'hffffffff),
        .osc_override_enable(1'b0),.osc_override_id(6'd0),.osc_override_increment(32'd0));
    always #5 clk=~clk;
    always @(negedge clk) if(!rst && dut.scheduler==9 && dut.on_events[dut.event_key])commits=commits+1;
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;cycles=0;
            while(!valid && cycles<1023)begin @(negedge clk);cycles=cycles+1;end
            if(!valid || fault || cycles>=1023 || (^pcm)===1'bx)begin
                $display("FAIL 40-source/64-DDS deadline clocks=%0d fault=%b",cycles,fault);$finish;
            end
            if(cycles>max_cycles)max_cycles=cycles;
            if(pcm!=0)nonzero=nonzero+1;
            repeat(1024-cycles-2)@(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<40;i=i+1)begin notes[i*7+:7]=48+i;instances[i*16+:16]=1;end
        repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);
        held=40'hffffffffff;frame;
        if(commits!=40 || active!==32'hffffffff)begin
            $display("FAIL all 40 source events must be accepted into 32 slots commits=%0d active=%h",commits,active);$finish;
        end
        repeat(40)frame;
        for(i=0;i<8;i=i+1) if(dut.owner[i]!==32+i || dut.increment[i]==0 || dut.increment_b[i]==0)begin
            $display("FAIL sources32..39 truncated or pending DDS absent slot=%0d owner=%0d",i,dut.owner[i]);$finish;
        end
        // Another full set of events with every source still held.
        for(i=0;i<40;i=i+1)instances[i*16+:16]=2;
        frame;repeat(40)frame;
        if(commits!=80 || fault || nonzero==0)begin
            $display("FAIL instance retriggers/full polyphony commits=%0d nonzero=%0d",commits,nonzero);$finish;
        end
        held=0;frame;
        for(i=0;i<32;i=i+1)if(dut.env_state[i]!=4 || dut.env_state_b[i]!=4)begin
            $display("FAIL all 40-source owners release A/B slot=%0d",i);$finish;
        end
        $display("PASS 40 sources / 32 voices / 64 DDS worst-case events max_core_cycles=%0d/1024",max_cycles);
        $finish;
    end
    initial begin #100000000;$display("FAIL performance deadline timeout");$finish;end
endmodule
