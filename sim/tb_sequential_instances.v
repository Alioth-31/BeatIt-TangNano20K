`timescale 1ns/1ps
// Controlled producer contract: after the initial snapshot, each accepted on
// increments exactly one source counter by one, at most once per audio frame.
// Full 16-bit mode is an independent cycle/PCM oracle for all valid fixtures.
module tb_sequential_instances;
    reg clk=0,rst=1,ce=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    wire signed [15:0] pcm_seq,pcm_full;
    wire valid_seq,valid_full,fault_seq,fault_full,busy_seq,busy_full;
    wire [31:0] active_seq,active_full;
    integer i,j,f,cycles,max_cycles=0,checks=0,commits=0,count,slot;
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .SEQUENTIAL_INSTANCE_ENABLE(1),.DUAL_OSC_ENABLE(1),
        .INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1)) dut(
        clk,rst,ce,held,2'd2,17'd65536,17'd65536,pcm_seq,valid_seq,
        fault_seq,busy_seq,active_seq,2'd0,17'd65536,2'd1,
        32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,notes,instances,1'b0,1'b0,32'd0);
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.LIVE_WAVE_ENABLE(1)) full_compare(
        clk,rst,ce,held,2'd2,17'd65536,17'd65536,pcm_full,valid_full,
        fault_full,busy_full,active_full,2'd0,17'd65536,2'd1,
        32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,notes,instances,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    always @(negedge clk) if(!rst)begin
        if(valid_seq!==valid_full || pcm_seq!==pcm_full || active_seq!==active_full ||
           busy_seq!==busy_full || fault_seq!==fault_full)begin
            $display("FAIL sequential producer cycle/PCM differs from full instance comparison");$finish;
        end
        if(dut.scheduler==9 && dut.on_events[dut.event_key])commits=commits+1;
    end
    task require;
        input condition;input [639:0] message;
        begin checks=checks+1;if(condition!==1'b1)begin $display("FAIL %0s",message);$finish;end end
    endtask
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;cycles=0;
            while(!valid_seq && cycles<1023)begin @(negedge clk);cycles=cycles+1;end
            require(valid_seq && !fault_seq && cycles<1023,"sequential 40-source sample deadline");
            if(cycles>max_cycles)max_cycles=cycles;
            for(i=0;i<32;i=i+1)begin
                require(dut.owner[i]===full_compare.owner[i] &&
                    dut.pending_owner[i]===full_compare.pending_owner[i] &&
                    dut.pending_live[i]===full_compare.pending_live[i] &&
                    dut.env_state[i]===full_compare.env_state[i] &&
                    dut.env_state_b[i]===full_compare.env_state_b[i] &&
                    dut.increment[i]===full_compare.increment[i] &&
                    dut.increment_b[i]===full_compare.increment_b[i],
                    "sequential source ownership and A/B state match full comparison");
            end
            repeat(1024-cycles-2)@(negedge clk);
        end
    endtask
    task restart;
        input wrap_seed;
        begin
            @(negedge clk);rst=1;held=0;instances=0;notes=0;
            for(j=0;j<40;j=j+1)notes[j*7+:7]=60;
            // Seed an initial idle snapshot representing omitted counter
            // history; every accepted on below still advances exactly +1.
            if(wrap_seed)instances[2*16+:16]=16'hfffe;
            repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);
            repeat(16)frame;commits=0;
        end
    endtask
    task on_source;
        input integer source_id;input [6:0] midi;
        begin
            held[source_id]=1;notes[source_id*7+:7]=midi;
            instances[source_id*16+:16]=instances[source_id*16+:16]+16'd1;
        end
    endtask
    initial begin
        // This reference is deliberately the generic default, not seq=1.
        require(full_compare.SEQUENTIAL_INSTANCE_ENABLE==0 && dut.SEQUENTIAL_INSTANCE_ENABLE==1,
            "sequential optimization is opt-in and generic default stays full-width");
        restart(0);on_source(0,62);on_source(8,62);frame;
        require(active_seq==32'h3 && dut.owner[0]==0 && dut.owner[1]==8,
            "same pitch from two sources remains independently owned");
        on_source(0,74);frame;
        require(dut.env_state[0]==4 && dut.env_state_b[0]==4 &&
            dut.increment[0]==32'd26276679 && dut.increment_b[0]==32'd26276679 &&
            dut.owner[2]==0 && dut.increment[2]==32'd52553357 && dut.increment_b[2]==32'd52553357,
            "consecutive source on preserves old pitch and gates only the latest instance");
        held[8]=0;frame;
        require(dut.env_state[1]==4 && dut.env_state_b[1]==4 && dut.env_state[2]!=4,
            "same-pitch source release remains independent");

        restart(1);on_source(2,69);frame;
        require(instances[2*16+:16]==16'hffff,"wrap fixture advances 65534 to 65535");
        on_source(2,81);frame;
        require(instances[2*16+:16]==0 && dut.env_state[0]==4 && dut.env_state_b[0]==4 &&
            dut.increment[0]==32'd39370534 && dut.increment_b[0]==32'd39370534 &&
            dut.increment[1]==32'd78741067 && dut.increment_b[1]==32'd78741067,
            "consecutive 65535-to-zero wrap releases the old A/B instance");

        restart(0);
        for(j=0;j<32;j=j+1)on_source(j,60);
        repeat(20)frame;
        on_source(32,62);frame;
        require(dut.env_state[0]==5 && dut.pending_owner[0]==32 && dut.pending_live[0],
            "first sequential instance enters steal pending");
        on_source(32,64);frame;
        require(!dut.pending_live[0],"second instance cancels the first pending instance");
        on_source(32,67);frame;
        require(instances[32*16+:16]==3 && !dut.pending_live[0] && !dut.pending_live[1],
            "returning to old parity cannot revive canceled FADE pending instances");
        repeat(34)frame;count=0;slot=-1;
        for(j=0;j<32;j=j+1)if(active_seq[j] && dut.owner[j]==32)begin count=count+1;slot=j;end
        require(count==1 && dut.increment[slot]==32'd35075158 && dut.increment_b[slot]==32'd35075158,
            "only the latest sequential pending instance starts on A and B");

        restart(0);
        for(j=0;j<40;j=j+1)on_source(j,48+j);
        frame;require(commits==40 && active_seq==32'hffffffff,"all forty simultaneous source on events accepted");
        repeat(34)frame;
        for(j=0;j<40;j=j+1)on_source(j,60+j);
        frame;require(commits==80,"forty consecutive on increments accepted while still held");
        repeat(34)frame;held=0;frame;
        for(j=0;j<32;j=j+1)require(dut.env_state[j]==4 && dut.env_state_b[j]==4,
            "all sequential sources release both envelopes");
        $display("PASS opt-in sequential instances: +1, wrap, parity return, same-pitch sources, full-compare equivalence (%0d checks, max=%0d/1024)",checks,max_cycles);
        $finish;
    end
    initial begin #100000000;$display("FAIL sequential instance timeout");$finish;end
endmodule
