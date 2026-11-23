`timescale 1ns/1ps
// Controlled producer contract: after the initial snapshot, each accepted on
// increments exactly one source counter by one, at most once per audio frame.
// The default storage datapath is the independent cycle/PCM/phase oracle.
module tb_temporal_storage_equivalence #(parameter INDEP=1);
    reg clk=0,rst=1,ce=0;
    reg [39:0] held=0;
    reg [279:0] notes=0;
    reg [639:0] instances=0;
    reg [1:0] preset_a=2,preset_b=1,wave=0;
    reg [16:0] volume=65536,bend_a=65536,bend_b=65536;
    reg [31:0] gate_a=32'hffffffff,gate_b=32'hffffffff;
    reg override_enable=0;reg [5:0] override_id=0;reg [31:0] override_step=1;
    reg [31:0] rng=32'h3da7be19;
    wire signed [15:0] pcm_seq,pcm_full;
    wire valid_seq,valid_full,fault_seq,fault_full,busy_seq,busy_full;
    wire [31:0] active_seq,active_full;
    integer i,j,f,cycles,max_cycles=0,checks=0,commits=0,count,slot;
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .SEQUENTIAL_INSTANCE_ENABLE(1),.A_STATE_RAM_ENABLE(1),.TEMPORAL_STORAGE_ENABLE(1),.DUAL_OSC_ENABLE(1),
        .INDEPENDENT_OSC_ENABLE(INDEP),.LIVE_WAVE_ENABLE(1),.FREQUENCY_PIPELINE_ENABLE(1)) dut(
        clk,rst,ce,held,preset_a,volume,bend_a,pcm_seq,valid_seq,
        fault_seq,busy_seq,active_seq,wave,bend_b,preset_b,
        gate_a,gate_b,override_enable,override_id,override_step,notes,instances,1'b0,1'b0,32'd0);
    synth_core #(.NUM_VOICES(32),.NUM_SOURCES(40),.MIDI_ENABLE(1),
        .SEQUENTIAL_INSTANCE_ENABLE(1),.A_STATE_RAM_ENABLE(1),.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(INDEP),.LIVE_WAVE_ENABLE(1)) full_compare(
        clk,rst,ce,held,preset_a,volume,bend_a,pcm_full,valid_full,
        fault_full,busy_full,active_full,wave,bend_b,preset_b,
        gate_a,gate_b,override_enable,override_id,override_step,notes,instances,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    always @(negedge clk) if(!rst)begin
        if(valid_seq!==valid_full || pcm_seq!==pcm_full || active_seq!==active_full ||
           busy_seq!==busy_full || fault_seq!==fault_full)begin
            $display("FAIL sequential producer cycle/PCM differs from full instance comparison");$finish;
        end
        if(dut.shape_phase!==full_compare.shape_phase || dut.shape_b_phase!==full_compare.shape_b_phase)begin
            $display("FAIL actual reconstructed old phase differs from baseline at cycle %0d",checks);$finish;
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
                    dut.increment_b[i]===full_compare.increment_b[i] &&
                    dut.envelope[i]===full_compare.envelope[i] &&
                    dut.remaining[i]===full_compare.remaining[i] &&
                    dut.release_step[i]===full_compare.release_step[i] &&
                    dut.voice_preset[i]===full_compare.voice_preset[i] &&
                    dut.phase[i]===full_compare.phase[i] && dut.phase_b[i]===full_compare.phase_b[i],
                    "sequential source ownership and A/B state match full comparison");
            end
            repeat(1024-cycles-2)@(negedge clk);
        end
    endtask
    task restart;
        input wrap_seed;
        begin
            @(negedge clk);rst=1;held=0;instances=0;notes=0;
            preset_a=2;preset_b=1;wave=0;volume=65536;bend_a=65536;bend_b=65536;
            gate_a=32'hffffffff;gate_b=32'hffffffff;override_enable=0;
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
        require(dut.TEMPORAL_STORAGE_ENABLE==1 && full_compare.TEMPORAL_STORAGE_ENABLE==0,
            "temporal phase and ROM storage is opt-in with default oracle");
        if(INDEP==0)begin
        restart(0);
        for(j=0;j<40;j=j+1)on_source(j,48+j);
        frame;require(commits==40,"I0 accepts forty source events");
        repeat(34)frame;
        for(f=0;f<100;f=f+1)begin
            for(j=0;j<40;j=j+1)begin
                rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                if(rng[3:0]==0)begin
                    if(held[j])held[j]=0;else on_source(j,48+(rng[6:0]%70));
                end else if(rng[5:0]==3 && held[j])on_source(j,48+(rng[6:0]%70));
            end
            preset_a=f%3;preset_b=(f+1)%3;wave=f[1:0];
            bend_a=(f%3==0)?17'd58386:17'd73562;
            volume=(f%8==0)?17'd0:17'd65536;
            frame;
        end
        held=0;repeat(40)frame;
        restart(1);on_source(2,100);frame;on_source(2,112);frame;
        require(instances[2*16+:16]==0,"I0 legal instance wrap");
        repeat(40)frame;
        $display("PASS temporal phase/ROM storage I0 coupled vs baseline cycle/PCM/state equivalence (%0d checks, max=%0d/1024)",checks,max_cycles);
        $finish;
        end
        // This reference is deliberately the generic default, not seq=1.
        require(full_compare.SEQUENTIAL_INSTANCE_ENABLE==1 && dut.SEQUENTIAL_INSTANCE_ENABLE==1,
            "both cores use identical producer and envelope settings");
        require(dut.A_STATE_RAM_ENABLE==1 && full_compare.A_STATE_RAM_ENABLE==1,
            "both cores use A envelope RAM while storage defaults remain comparable");
        require(dut.TEMPORAL_STORAGE_ENABLE==1,"candidate really uses temporal phase and sine storage");
        restart(0);on_source(39,69);frame;
        require(dut.owner[0]==39 && dut.envelope[0]!=0,
            "last source COMMIT initializes RAM before next PREP-to-LOAD");
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
        // Explicitly cancel a pending steal, let PREP leave the slot OFF,
        // then trigger a new preset into that free slot.
        restart(0);for(j=0;j<32;j=j+1)on_source(j,60);repeat(4)frame;
        preset_a=1;preset_b=0;on_source(32,62);frame;held[32]=0;frame;
        preset_a=2;preset_b=2;repeat(34)frame;
        require(dut.env_state[0]==0 && dut.env_state_b[0]==0,
            "canceled pending PREP produces an OFF slot with zero RAM level");
        preset_a=1;on_source(33,69);frame;
        require(dut.owner[0]==33 && dut.voice_preset[0]==1,
            "free slot after canceled pending takes the next confirmed preset");
        // Pending patch data must survive unrelated patch updates during fade.
        restart(0);for(j=0;j<32;j=j+1)on_source(j,60);repeat(4)frame;
        preset_a=1;preset_b=0;on_source(32,62);frame;
        preset_a=2;preset_b=2;repeat(34)frame;
        require(dut.owner[0]==32 && dut.voice_preset[0]==1,
            "pending voice starts with its captured A preset");
        // All updates below are legitimate producer events; no shadow writes
        // or forced RAM/state values are used to claim functional equivalence.
        for(f=0;f<160;f=f+1)begin
            for(j=0;j<40;j=j+1)begin
                rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                if(rng[3:0]==0)begin
                    if(held[j])held[j]=0;else on_source(j,48+(rng[6:0]%60));
                end else if(rng[5:0]==3 && held[j])on_source(j,48+(rng[6:0]%60));
            end
            preset_a=f%3;preset_b=(f+1)%3;wave=f[1:0];
            gate_a=(f%7==0)?32'h55555555:32'hffffffff;
            gate_b=(f%5==0)?32'haaaaaaaa:32'hffffffff;
            override_enable=(f%4!=0);override_id=rng[5:0];
            case(f%3)0:override_step=1;1:override_step=32'h7fffffff;default:override_step=(rng & 32'h7fffffff)|1;endcase
            bend_a=(f%3==0)?17'd58386:17'd73562;
            bend_b=(f%4==0)?17'd65536:17'd67456;volume=(f%8==0)?17'd0:17'd65536;
            frame;
        end
        // Reach phase low-bit carry and 32-bit wrap only through supported
        // diagnostic increment commands; no hierarchical state writes.
        restart(0);on_source(0,69);on_source(8,69);repeat(4)frame;
        for(f=0;f<24;f=f+1)begin
            override_enable=1;override_id=(f[0]?6'd32:6'd0);
            case(f%4)0:override_step=32'hffffffff;1:override_step=32'h003fffff;
                2:override_step=32'h00400001;3:override_step=32'h80000001;endcase
            frame;
        end
        held=0;repeat(250)frame;
        $display("PASS temporal phase/ROM storage vs baseline cycle/PCM/phase/state equivalence (%0d checks, max=%0d/1024)",checks,max_cycles);
        $finish;
    end
    initial begin #100000000;$display("FAIL sequential instance timeout");$finish;end
endmodule
