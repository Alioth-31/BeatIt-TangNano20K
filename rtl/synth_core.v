`timescale 1ns/1ps
// Independent oscillator state; shared arithmetic. Every request completes < 700 clocks
// at 32 voices. Legal production configurations are 4,8,16,32.
module synth_core #(
    parameter NUM_VOICES=4, parameter WAVEFORM_MODE=0, parameter LIVE_WAVE_ENABLE=0,
    parameter DUAL_OSC_ENABLE=0, parameter OSC2_WAVEFORM=0,
    parameter OSC2_DETUNE_SHIFT=7, parameter OSC2_SHARE_ROM=1,
    parameter INDEPENDENT_OSC_ENABLE=0,
    parameter NUM_SOURCES=32, parameter MIDI_ENABLE=0,
    // Opt-in producer contract: at most one on per source per audio frame,
    // and each on increments its 16-bit instance by exactly one. A changed
    // LSB then identifies every new on; sticky alive flags prevent revival
    // when later increments return to an old parity. Generic tags use all bits.
    parameter SEQUENTIAL_INSTANCE_ENABLE=0, parameter A_STATE_RAM_ENABLE=0, parameter TEMPORAL_STORAGE_ENABLE=0,
    parameter MONO_ENABLED=0, parameter FREQUENCY_PIPELINE_ENABLE=0,
    parameter MIX_BOOST_SHIFT=0
)(
    input clk, input rst, input sample_ce, input [NUM_SOURCES-1:0] held_keys,
    input [1:0] preset, input [16:0] volume_target, input [16:0] bend_target,
    output reg signed [15:0] pcm, output reg pcm_valid,
    output reg fault, output busy, output [NUM_VOICES-1:0] active,
    input [1:0] waveform_select,
    input [16:0] osc2_bend_target, input [1:0] osc2_preset,
    input [31:0] osc1_gate_mask, input [31:0] osc2_gate_mask,
    input osc_override_enable, input [5:0] osc_override_id,
    input [31:0] osc_override_increment,
    input [NUM_SOURCES*7-1:0] source_midi,
    input [NUM_SOURCES*16-1:0] source_instance,
    input mono_mode,input mono_legato,input [31:0] mono_increment
);
    function integer clog2;
        input integer value; integer v;
        begin v=value-1; clog2=0; while(v>0) begin clog2=clog2+1; v=v>>1; end end
    endfunction
    localparam INDEX_W=clog2(NUM_VOICES), SUM_W=16+INDEX_W;
    localparam MIX_SHIFT=(INDEX_W>=MIX_BOOST_SHIFT)?INDEX_W-MIX_BOOST_SHIFT:0;
    localparam SOURCE_W=(NUM_SOURCES<2)?1:clog2(NUM_SOURCES);
    localparam IDLE=0, ALLOC=1, PREP=2, LOAD=3, CALC=4, MUL=5, ACCUM=6, NEXT=7, OUTPUT_PCM=8, COMMIT=9, BLEND=10, MIX_B=11, CAPTURE_B=12, MUL_B=13, ACCUM_B=14, ENV_WAIT=15;
    localparam OFF=0, ATTACK=1, DECAY=2, SUSTAIN=3, RELEASE=4, FADE=5;
    `include "note_table.vh"
    `include "midi_note_table.vh"
    reg [3:0] scheduler /* synthesis syn_maxfan=64 */;
    reg [31:0] phase [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [31:0] increment [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [2:0] env_state [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [24:0] envelope [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [24:0] release_step [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [14:0] remaining [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [SOURCE_W-1:0] owner [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [SOURCE_W-1:0] pending_owner [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [6:0] voice_midi [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [6:0] pending_midi [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [15:0] voice_instance [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [15:0] pending_instance [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    // Once a source instance changes or releases, its old voice never re-gates.
    // Share source comparisons rather than building 64 wide source read muxes.
    reg [NUM_VOICES-1:0] voice_alive;
    reg [1:0] voice_preset [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [1:0] pending_preset [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg pending_live [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [5:0] fade_left [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    // v7 R1: 0=oldest, NUM_VOICES-1=newest; exact permutation.
    reg [INDEX_W-1:0] age [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [NUM_SOURCES-1:0] held, previous_held, on_events;
    reg [NUM_SOURCES*7-1:0] frame_midi;
    // Also the preceding sample's instance snapshot when IDLE accepts a frame.
    reg [NUM_SOURCES*16-1:0] frame_instance;
    wire [NUM_SOURCES-1:0] source_changed;
    wire [NUM_SOURCES-1:0] source_ended=(~held_keys)|source_changed;
    wire [NUM_VOICES-1:0] owner_held,pending_held;
    reg [1:0] frame_preset;
    // The priority adapter presents at most one source in mono mode. Reuse
    // the existing allocator for the first note and one slot thereafter.
    reg frame_mono,frame_legato,mono_slot_valid,mono_pitch_active,pending_mono;
    reg [INDEX_W-1:0] mono_slot;
    reg [31:0] mono_base;
    reg [SOURCE_W-1:0] event_key;
    reg [INDEX_W-1:0] voice_index /* synthesis syn_maxfan=64 */;
    reg [16:0] volume_current, bend_current;
    reg signed [15:0] raw_sample;
    reg signed [33:0] voice_product;
    reg [48:0] frequency_product;
    // Reuse the existing envelope wait slot: LOAD clocks the pitch ROM,
    // ENV_WAIT multiplies its result, and CALC consumes the unchanged product.
    // MIDI updates in PREP are therefore visible, including pending steals.
    localparam PIPE_FREQUENCY=(FREQUENCY_PIPELINE_ENABLE!=0 && MIDI_ENABLE!=0 && INDEPENDENT_OSC_ENABLE!=0);
    wire [31:0] midi_base_increment;
    generate if(PIPE_FREQUENCY)begin: frequency_lookup
        midi_increment_rom lookup(clk,voice_midi[voice_index],midi_base_increment);
    end else begin: no_frequency_lookup
        assign midi_base_increment=32'd0;
    end endgenerate
    // v6 phase/ROM paths retained. Independent mode reuses the original ADSR
    // ALU, frequency multiplier and envelope multiplier at a second time slot.
    reg [31:0] phase_b [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [31:0] increment_b [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [2:0] env_state_b [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [1:0] pending_preset_b [0:NUM_VOICES-1] /* synthesis syn_ramstyle="registers" */;
    reg [4:0] b_init_addr;
    reg b_initialized;
    reg b_write;
    reg [4:0] b_write_addr;
    reg [71:0] b_write_data;
    wire [71:0] b_read;
    wire [4:0] b_read_addr=voice_index;
    osc_envelope_ram #(.DEPTH(NUM_VOICES)) b_state_store(
        clk,b_read_addr,b_read,b_write,b_write_addr,b_write_data);
    reg [16:0] bend_b_current;
    reg a_write;
    reg [4:0] a_write_addr;
    reg [71:0] a_write_data;
    wire [71:0] a_read;
    // PREP may initialize a pending note one clock before LOAD. The explicit
    // known-value bypass avoids depending on DP read-during-write behavior.
    reg a_restart,a_restart_live;
    reg [1:0] a_restart_preset;
    generate if(A_STATE_RAM_ENABLE!=0) begin: a_state_ram
        osc_envelope_ram #(.DEPTH(NUM_VOICES)) store(
            clk,b_read_addr,a_read,a_write,a_write_addr,a_write_data);
    end else begin: no_a_state_ram
        assign a_read=72'd0;
    end endgenerate
    reg phase_restart;
    reg phase_write_a,phase_write_b;
    reg [4:0] phase_write_addr;
    reg [31:0] phase_write_data_a,phase_write_data_b;
    wire [31:0] phase_read_a,phase_read_b;
    generate if(TEMPORAL_STORAGE_ENABLE!=0)begin: phase_low_store
        osc_envelope_ram #(.WIDTH(32),.DEPTH(NUM_VOICES)) a(
            clk,b_read_addr,phase_read_a,phase_write_a,phase_write_addr,phase_write_data_a);
        osc_envelope_ram #(.WIDTH(32),.DEPTH(NUM_VOICES)) b(
            clk,b_read_addr,phase_read_b,phase_write_b,phase_write_addr,phase_write_data_b);
    end else begin: no_phase_low_store
        assign phase_read_a=32'd0;assign phase_read_b=32'd0;
    end endgenerate
    reg [1:0] frame_b_preset;
    reg [31:0] frame_gate_a,frame_gate_b,frame_override_increment;
    reg [31:0] override_mask_a,override_mask_b;
    wire frequency_read_b=(scheduler!=IDLE && scheduler!=ALLOC && scheduler!=COMMIT &&
        scheduler!=PREP && scheduler!=LOAD && scheduler!=NEXT && scheduler!=OUTPUT_PCM);
    wire [5:0] frequency_address={frequency_read_b,{(5-INDEX_W){1'b0}},voice_index};
    wire [31:0] frequency_read;
    osc_envelope_ram #(.WIDTH(32),.ADDR_W(6),.DEPTH(64)) frequency_store(
        clk,frequency_address,frequency_read,
        INDEPENDENT_OSC_ENABLE!=0 && sample_ce && !busy && !rst && !fault && osc_override_enable,
        osc_override_id,osc_override_increment);
    reg frame_override_enable;
    reg [5:0] frame_override_id;
    reg [5:0] fade_for_b;
    reg signed [15:0] primary_pcm;
    reg [31:0] shape_b_phase;
    reg signed [15:0] secondary_candidate;
    wire signed [15:0] secondary_shaped;
    wire signed [15:0] pair_sample;
    wire [31:0] osc2_step = frequency_product[47:16] +
                                  (frequency_product[47:16] >> OSC2_DETUNE_SHIFT);
    osc_wave_shape osc2_shape(.phase(shape_b_phase),
                              .waveform(OSC2_WAVEFORM[1:0]),.sample(secondary_shaped));
    wire signed [15:0] enveloped_b=voice_product>>>16;
    osc_dual_mix pair(.primary(INDEPENDENT_OSC_ENABLE!=0 ? primary_pcm : raw_sample),
                      .secondary(INDEPENDENT_OSC_ENABLE!=0 ? enveloped_b : secondary_candidate),
                      .sample_out(pair_sample));
    wire signed [15:0] secondary_sine [0:NUM_VOICES-1];
    reg [31:0] shape_phase;
    // LOAD snapshots both old phases. A and independent B advance in distinct
    // existing slots, so one explicit adder serves every voice and oscillator.
    wire [31:0] phase_add_base=(INDEPENDENT_OSC_ENABLE!=0 && scheduler==ACCUM)?
        shape_b_phase:shape_phase;
    wire [31:0] shared_phase_next=phase_add_base+frequency_product[47:16];
    // Legacy coupled DDS advances B beside A in CALC and needs a second adder.
    wire [31:0] coupled_phase_b_next=shape_b_phase+osc2_step;
    reg [1:0] wave_current, wave_previous;
    reg [5:0] wave_fade;
    reg signed [15:0] old_candidate, new_candidate;
    reg signed [SUM_W-1:0] mix;
    wire signed [15:0] mixed_pcm;
    wire signed [15:0] wave [0:NUM_VOICES-1];
    reg [24:0] effective_env;
    wire signed [17:0] env_gain=$signed({1'b0,effective_env[24:8]});
    reg [2:0] alu_state;
    reg [24:0] alu_level,alu_step;
    reg [14:0] alu_remaining;
    reg [1:0] alu_preset;
    reg alu_gate;
    wire [2:0] alu_next_state;
    wire [24:0] alu_next_level,alu_next_step;
    wire [14:0] alu_next_remaining;
    reg [2:0] result_state;
    reg [24:0] result_level,result_step;
    reg [14:0] result_remaining;
    reg wait_for_b;
    // One shared result register separates the verified ADSR ALU from the
    // indexed state writes; independent mode adds two clocks per voice.
    wire [2:0] next_state=(INDEPENDENT_OSC_ENABLE!=0)?result_state:alu_next_state;
    wire [24:0] next_level=(INDEPENDENT_OSC_ENABLE!=0)?result_level:alu_next_level;
    wire [24:0] next_step=(INDEPENDENT_OSC_ENABLE!=0)?result_step:alu_next_step;
    wire [14:0] next_remaining=(INDEPENDENT_OSC_ENABLE!=0)?result_remaining:alu_next_remaining;
    wire [24:0] fade_level=(INDEPENDENT_OSC_ENABLE!=0 && scheduler==ACCUM)?alu_level:
        ((A_STATE_RAM_ENABLE!=0)?a_read[27:3]:envelope[voice_index]);
    wire [5:0] fade_count=(INDEPENDENT_OSC_ENABLE!=0 && scheduler==ACCUM)?fade_for_b:fade_left[voice_index];
    wire [30:0] fade_product=fade_level*fade_count;
    reg [2:0] selection_wait;
    reg [1:0] choice_class [1:2*NUM_VOICES-1];
    reg [INDEX_W-1:0] choice_age [1:2*NUM_VOICES-1];
    reg [INDEX_W-1:0] choice_slot [1:2*NUM_VOICES-1];
    wire [INDEX_W-1:0] chosen=(MONO_ENABLED && frame_mono && mono_slot_valid)?mono_slot:choice_slot[1];
    wire [INDEX_W-1:0] chosen_age=(MONO_ENABLED && frame_mono && mono_slot_valid)?age[mono_slot]:choice_age[1];
    wire mono_voice=MONO_ENABLED && mono_slot_valid && mono_pitch_active && voice_index==mono_slot;
    // Hold the last sounding pitch during release and the existing steal
    // fade. A new phrase's snapped pitch is consumed only when it starts.
    wire [31:0] mono_frequency=(frame_mono && voice_alive[voice_index] &&
        env_state[voice_index]!=FADE)?mono_increment:mono_base;
    // One shared non-sine phase shaper; legacy sine remains from paired BRAM.
    wire signed [15:0] alternate_wave;
    osc_wave_shape shape(.phase(shape_phase),
                         .waveform(WAVEFORM_MODE[1:0]),.sample(alternate_wave));
    wire signed [15:0] live_new, live_old;
    osc_wave_shape new_shaper(.phase(shape_phase),.waveform(wave_current),.sample(live_new));
    osc_wave_shape old_shaper(.phase(shape_phase),.waveform(wave_previous),.sample(live_old));
    wire signed [15:0] wave_blended;
    osc_wave_blend wave_fader(
        .sample_old(old_candidate),.sample_new(new_candidate),
        .fade_left(wave_fade),.sample_out(wave_blended));
    // Single writer for the new state RAM; the registered state summary above
    // keeps the existing allocation tree independent of RAM read latency.
    always @* begin
        b_write=0;b_write_addr=voice_index;b_write_data=0;
        if(INDEPENDENT_OSC_ENABLE!=0 && DUAL_OSC_ENABLE!=0) begin
            if(rst || !b_initialized) begin b_write=1;b_write_addr=b_init_addr;end
            else if(!fault && !(sample_ce && busy)) begin
                case(scheduler)
                    COMMIT: if(on_events[event_key] && env_state[chosen]==OFF && env_state_b[chosen]==OFF) begin
                        b_write=1;b_write_addr=chosen;
                        b_write_data={2'd0,frame_b_preset,25'd0,((frame_b_preset==1)?15'd96:15'd240),25'd0,
                            (frame_gate_b[chosen]?3'd1:3'd0)};
                    end
                    PREP: if(env_state[voice_index]==FADE && fade_left[voice_index]==0) begin
                        b_write=1;
                        if(pending_live[voice_index] && pending_held[voice_index])
                            b_write_data={2'd0,pending_preset_b[voice_index],25'd0,
                                ((pending_preset_b[voice_index]==1)?15'd96:15'd240),25'd0,
                                (frame_gate_b[voice_index]?3'd1:3'd0)};
                    end
                    ACCUM: if(env_state[voice_index]!=FADE) begin
                        b_write=1;b_write_data={2'd0,b_read[69:68],next_step,next_remaining,next_level,next_state};
                    end
                endcase
            end
        end
    end
    // A uses the already verified B envelope RAM packing and read schedule.
    // The register arrays remain RTL observation mirrors and are not functional
    // storage when enabled; synthesis can discard their unconsumed bits.
    always @* begin
        a_write=0;a_write_addr=voice_index;a_write_data=0;
        if(A_STATE_RAM_ENABLE!=0) begin
            if(rst || !b_initialized) begin a_write=1;a_write_addr=b_init_addr;end
            else if(!fault && !(sample_ce && busy)) begin
                case(scheduler)
                    COMMIT: if(on_events[event_key] && env_state[chosen]==OFF &&
                        (INDEPENDENT_OSC_ENABLE==0 || env_state_b[chosen]==OFF)) begin
                        a_write=1;a_write_addr=chosen;
                        a_write_data={2'd0,frame_preset,25'd0,
                            ((frame_preset==1)?15'd96:15'd240),25'd0,
                            ((INDEPENDENT_OSC_ENABLE==0 || frame_gate_a[chosen])?3'd1:3'd0)};
                    end
                    PREP: if(env_state[voice_index]==FADE && fade_left[voice_index]==0) begin
                        a_write=1;
                        if(pending_live[voice_index] && pending_held[voice_index])
                            a_write_data={2'd0,pending_preset[voice_index],25'd0,
                                ((pending_preset[voice_index]==1)?15'd96:15'd240),25'd0,
                                ((INDEPENDENT_OSC_ENABLE==0 || frame_gate_a[voice_index])?3'd1:3'd0)};
                    end
                    CALC: if(env_state[voice_index]!=FADE) begin
                        a_write=1;a_write_data={2'd0,a_read[69:68],next_step,next_remaining,next_level,next_state};
                    end
                endcase
            end
        end
    end
    // Same phase write slots as before, using the verified DP state interface.
    // Phase arrays remain read-only RTL mirrors; the enabled datapath reads RAM.
    always @* begin
        phase_write_a=0;phase_write_b=0;phase_write_addr=voice_index;
        phase_write_data_a=0;phase_write_data_b=0;
        if(TEMPORAL_STORAGE_ENABLE!=0)begin
            if(rst || !b_initialized)begin
                phase_write_a=1;phase_write_b=1;phase_write_addr=b_init_addr;
            end else if(!fault && !(sample_ce && busy))begin
                case(scheduler)
                    COMMIT: if(on_events[event_key] && env_state[chosen]==OFF &&
                        (INDEPENDENT_OSC_ENABLE==0 || env_state_b[chosen]==OFF))begin
                        phase_write_a=1;phase_write_b=1;phase_write_addr=chosen;
                    end
                    PREP: if(env_state[voice_index]==FADE && fade_left[voice_index]==0)begin
                        phase_write_a=1;phase_write_b=1;
                    end
                    CALC: begin
                        if(env_state[voice_index]!=OFF)begin
                            phase_write_a=1;phase_write_data_a=shared_phase_next;
                        end
                        if(DUAL_OSC_ENABLE!=0 && INDEPENDENT_OSC_ENABLE==0 && env_state[voice_index]!=OFF)begin
                            phase_write_b=1;phase_write_data_b=coupled_phase_b_next;
                        end
                    end
                    ACCUM: if(INDEPENDENT_OSC_ENABLE!=0 && DUAL_OSC_ENABLE!=0 && env_state_b[voice_index]!=OFF)begin
                        phase_write_b=1;phase_write_data_b=shared_phase_next;
                    end
                endcase
            end
        end
    end
    assign busy=(scheduler!=IDLE);
    genvar g;
    generate
        for(g=0;g<NUM_SOURCES;g=g+1) begin: instance_changes
            assign source_changed[g]=(SEQUENTIAL_INSTANCE_ENABLE!=0)?
                (source_instance[g*16]!=frame_instance[g*16]):
                (source_instance[g*16+:16]!=frame_instance[g*16+:16]);
        end
        if(WAVEFORM_MODE==0 || LIVE_WAVE_ENABLE!=0 ||
           (DUAL_OSC_ENABLE!=0 && OSC2_WAVEFORM==0 && OSC2_SHARE_ROM!=0)) begin: sine_bank
            if(TEMPORAL_STORAGE_ENABLE!=0) begin: temporal
                wire signed [15:0] q_a,q_b;
                // Read the live selected slot, not the LOAD phase registers:
                // coupled mode needs A ready on the following CALC edge.
                // PREP reads phase RAM; LOAD reads the sine ROM; CALC uses A.
                // PREP may clear a stolen slot. Bypass both ROM addresses and
                // LOAD phase latches so DP read-during-write behavior is unused.
                wire [9:0] address_a=phase_restart?10'd0:phase_read_a[31:22];
                wire [9:0] address_b=phase_restart?10'd0:phase_read_b[31:22];
                sine_rom_pair rom(clk,address_a,address_b,q_a,q_b);
                for(g=0;g<NUM_VOICES;g=g+1) begin: shared_wave
                    assign wave[g]=(scheduler==CAPTURE_B)?q_b:q_a;
                end
            end else begin: paired
            for(g=0;g<NUM_VOICES;g=g+2) begin: roms
                // CALC reads B phase; next state captures its synchronous data.
                // Other states read A phase. One ROM per pair, even for two DDS.
                wire [9:0] address_a, address_b;
                assign address_a = (DUAL_OSC_ENABLE!=0 && OSC2_WAVEFORM==0 &&
                    OSC2_SHARE_ROM!=0 && scheduler==CALC) ?
                    phase_b[g][31:22] : phase[g][31:22];
                assign address_b = (DUAL_OSC_ENABLE!=0 && OSC2_WAVEFORM==0 &&
                    OSC2_SHARE_ROM!=0 && scheduler==CALC) ?
                    phase_b[g+1][31:22] : phase[g+1][31:22];
                sine_rom_pair rom(clk,address_a,address_b,wave[g],wave[g+1]);
            end
            end
        end else begin: waveform_only
            // Static nonsine A with nonsine B or duplicated B sine.
            for(g=0;g<NUM_VOICES;g=g+1) begin: unused_rom
                assign wave[g]=16'sd0;
            end
        end
        if(DUAL_OSC_ENABLE!=0 && OSC2_WAVEFORM==0 && OSC2_SHARE_ROM==0) begin: second_sine_bank
            for(g=0;g<NUM_VOICES;g=g+2) begin: second_roms
                sine_rom_pair rom(clk,phase_b[g][31:22],phase_b[g+1][31:22],
                                  secondary_sine[g],secondary_sine[g+1]);
            end
        end else begin: no_second_sine_bank
            for(g=0;g<NUM_VOICES;g=g+1) begin: unused_second
                assign secondary_sine[g]=16'sd0;
            end
        end
        for(g=0;g<NUM_VOICES;g=g+1) begin: activity
            assign owner_held[g]=(MIDI_ENABLE!=0)?voice_alive[g]:held[owner[g]];
            // pending_live is itself the sticky instance-valid latch.
            assign pending_held[g]=(MIDI_ENABLE!=0)?1'b1:held[pending_owner[g]];
            wire slot_free=(env_state[g]==OFF) &&
                (INDEPENDENT_OSC_ENABLE==0 || env_state_b[g]==OFF);
            wire slot_releasing=(env_state[g]==RELEASE || env_state[g]==OFF) &&
                (INDEPENDENT_OSC_ENABLE==0 || env_state_b[g]==RELEASE || env_state_b[g]==OFF);
            assign active[g]=!slot_free;
            always @(posedge clk) begin
                choice_class[NUM_VOICES+g]<=slot_free?0:
                    ((env_state[g]!=FADE && (slot_releasing || !owner_held[g]))?1:2);
                choice_age[NUM_VOICES+g]<=age[g];
                choice_slot[NUM_VOICES+g]<=g;
            end
        end
        for(g=1;g<NUM_VOICES;g=g+1) begin: priority_tree
            wire choose_left=(choice_class[2*g]<choice_class[2*g+1]) ||
                ((choice_class[2*g]==choice_class[2*g+1]) &&
                 ((choice_class[2*g]==0) || (choice_age[2*g] <= choice_age[2*g+1])));
            always @(posedge clk) begin
                choice_class[g]<=choose_left?choice_class[2*g]:choice_class[2*g+1];
                choice_age[g]<=choose_left?choice_age[2*g]:choice_age[2*g+1];
                choice_slot[g]<=choose_left?choice_slot[2*g]:choice_slot[2*g+1];
            end
        end
    endgenerate
    adsr_step env_alu(alu_state,alu_level,alu_remaining,alu_step,alu_preset,alu_gate,
        alu_next_state,alu_next_level,alu_next_remaining,alu_next_step);
    pcm_gain #(.WIDTH(SUM_W),.SHIFT(MIX_SHIFT)) gain(mix,volume_current,mixed_pcm);
    // Flush the registered priority tree after every commit. No event can reuse
    // a stale free-slot decision from the preceding simultaneous key event.
    integer k, j;
    always @(posedge clk) begin
        if(rst) begin
            scheduler<=IDLE; pcm<=0; pcm_valid<=0; fault<=0;
            held<=0; previous_held<=0; on_events<=0;frame_midi<=0;frame_instance<=0;voice_alive<=0;
            frame_preset<=0; event_key<=0; voice_index<=0; mix<=0; shape_phase<=0;
            frame_mono<=0;frame_legato<=0;mono_slot_valid<=0;mono_pitch_active<=0;mono_slot<=0;mono_base<=0;pending_mono<=0;
            wave_current<=WAVEFORM_MODE[1:0];wave_previous<=WAVEFORM_MODE[1:0];
            wave_fade<=0;old_candidate<=0;new_candidate<=0;
            shape_b_phase<=0;secondary_candidate<=0;
            bend_b_current<=65536+(65536>>OSC2_DETUNE_SHIFT);
            frame_b_preset<=0;frame_gate_a<=32'hffffffff;frame_gate_b<=32'hffffffff;
            frame_override_enable<=0;frame_override_id<=0;frame_override_increment<=0;
            override_mask_a<=0;override_mask_b<=0;
            fade_for_b<=0;primary_pcm<=0;
            b_init_addr<=0;b_initialized<=0;
            a_restart<=0;a_restart_live<=0;a_restart_preset<=0;phase_restart<=0;
            selection_wait<=0;
            volume_current<=0; bend_current<=65536;
            raw_sample<=0; effective_env<=0; voice_product<=0; frequency_product<=0;
            alu_state<=0; alu_level<=0; alu_step<=0; alu_remaining<=0; alu_preset<=0; alu_gate<=0;
            result_state<=0;result_level<=0;result_step<=0;result_remaining<=0;wait_for_b<=0;
            for(k=0;k<NUM_VOICES;k=k+1) begin
                phase[k]<=0; increment[k]<=0; env_state[k]<=OFF; envelope[k]<=0;
                phase_b[k]<=0; increment_b[k]<=0;
                env_state_b[k]<=OFF;pending_preset_b[k]<=0;
                remaining[k]<=0; release_step[k]<=0; owner[k]<=0; pending_owner[k]<=0;
                voice_midi[k]<=0;pending_midi[k]<=0;voice_instance[k]<=0;pending_instance[k]<=0;
                voice_preset[k]<=0; pending_preset[k]<=0; fade_left[k]<=0;
                age[k]<=k;  // rank permutation; free slots still choose lowest ID
                pending_live[k]<=0;
            end
        end else begin
            pcm_valid<=0;
            if(((INDEPENDENT_OSC_ENABLE!=0 && DUAL_OSC_ENABLE!=0) || A_STATE_RAM_ENABLE!=0 || TEMPORAL_STORAGE_ENABLE!=0) && !b_initialized) begin
                if(b_init_addr==NUM_VOICES-1)b_initialized<=1;
                else b_init_addr<=b_init_addr+1'b1;
                pcm<=0;pcm_valid<=sample_ce;
            end else if(fault || (sample_ce && busy)) begin
                fault<=1; pcm<=0; pcm_valid<=sample_ce; scheduler<=IDLE;
            end else case(scheduler)
                IDLE: if(sample_ce) begin
                    frame_mono<=MONO_ENABLED && mono_mode;
                    frame_legato<=MONO_ENABLED && mono_legato;
                    held<=held_keys; on_events<=held_keys & ~previous_held; previous_held<=held_keys;
                    if(MIDI_ENABLE!=0) begin
                        frame_midi<=source_midi;frame_instance<=source_instance;
                        on_events<=held_keys & (~previous_held | source_changed);
                        for(k=0;k<NUM_VOICES;k=k+1)
                            if(source_ended[owner[k]])voice_alive[k]<=0;
                    end
                    // Defer another change until the current 32-sample crossfade ends.
                    if(LIVE_WAVE_ENABLE!=0 && wave_fade==0 && waveform_select!=wave_current) begin
                        wave_previous<=wave_current;
                        wave_current<=waveform_select;
                        wave_fade<=32;
                    end
                    frame_preset<=(preset>2)?0:preset;
                    if(INDEPENDENT_OSC_ENABLE!=0) begin
                        frame_b_preset<=(osc2_preset>2)?0:osc2_preset;
                        frame_gate_a<=osc1_gate_mask;frame_gate_b<=osc2_gate_mask;
                        frame_override_enable<=osc_override_enable;
                        frame_override_id<=osc_override_id;frame_override_increment<=osc_override_increment;
                        if(osc2_bend_target>bend_b_current)
                            bend_b_current<=((osc2_bend_target-bend_b_current)>32)?bend_b_current+17'd32:osc2_bend_target;
                        else bend_b_current<=((bend_b_current-osc2_bend_target)>32)?bend_b_current-17'd32:osc2_bend_target;
                        if(!osc_override_enable)begin override_mask_a<=0;override_mask_b<=0;end
                        else if(osc_override_id[5])override_mask_b[osc_override_id[4:0]]<=1;
                        else override_mask_a[osc_override_id[4:0]]<=1;
                    end
                    for(k=0;k<NUM_VOICES;k=k+1)
                        if(env_state[k]==FADE && ((MIDI_ENABLE!=0)?source_ended[pending_owner[k]]:!held_keys[pending_owner[k]]))
                            pending_live[k]<=0;
                    event_key<=0; mix<=0; selection_wait<=0; scheduler<=ALLOC;
                    if(volume_target>volume_current)
                        volume_current<=((volume_target-volume_current)>128)?volume_current+17'd128:volume_target;
                    else volume_current<=((volume_current-volume_target)>128)?volume_current-17'd128:volume_target;
                    if(bend_target>bend_current)
                        bend_current<=((bend_target-bend_current)>32)?bend_current+17'd32:bend_target;
                    else bend_current<=((bend_current-bend_target)>32)?bend_current-17'd32:bend_target;
                end
                ALLOC: begin
                    if(selection_wait==INDEX_W) scheduler<=COMMIT;
                    else selection_wait<=selection_wait+1'b1;
                end
                COMMIT: begin
                    // Update exact LRU rank on accepted event only.
                    // choice_age[1] is the registered rank of the chosen slot;
                    // using it avoids a new 32:1 read mux on age[chosen].
                    if(on_events[event_key]) begin
                        for(j=0;j<NUM_VOICES;j=j+1) begin
                            if(chosen==j) age[j]<=NUM_VOICES-1;
                            else if(age[j]>chosen_age) age[j]<=age[j]-1'b1;
                        end
                        if(MONO_ENABLED && frame_mono) begin mono_slot_valid<=1;mono_slot<=chosen;end
                    end
                    // Constant-index writes avoid a pathological multiport RAM
                    // inference pass in Gowin 1.9.11.03 (notably N=8).
                    for(k=0;k<NUM_VOICES;k=k+1) if(chosen==k) begin
                        if(on_events[event_key]) begin
                            // The rank update is executed above for this event.
                            if(MONO_ENABLED && frame_mono && frame_legato && mono_slot_valid &&
                                env_state[k]!=FADE && (env_state[k]!=OFF || env_state_b[k]!=OFF)) begin
                                // Transfer the gate's owner, keeping each oscillator's
                                // current ADSR state, phase and independent gate mask.
                                owner[k]<=event_key;voice_midi[k]<=frame_midi[event_key*7+:7];
                                voice_instance[k]<=frame_instance[event_key*16+:16];voice_alive[k]<=1;
                            end else if(env_state[k]==OFF && (INDEPENDENT_OSC_ENABLE==0 || env_state_b[k]==OFF)) begin
                                if(MONO_ENABLED)begin
                                    if(frame_mono)mono_pitch_active<=1;
                                    else if(mono_slot==k)begin mono_slot_valid<=0;mono_pitch_active<=0;end
                                end
                                owner[k]<=event_key; voice_preset[k]<=frame_preset;
                                if(MIDI_ENABLE!=0) begin
                                    voice_midi[k]<=frame_midi[event_key*7+:7];
                                    voice_instance[k]<=frame_instance[event_key*16+:16];
                                    voice_alive[k]<=1;
                                end
                                phase[k]<=0; phase_b[k]<=0; envelope[k]<=0; env_state[k]<=ATTACK;
                                remaining[k]<=(frame_preset==1)?96:240;
                                release_step[k]<=0; fade_left[k]<=0;
                                pending_live[k]<=0;
                                if(INDEPENDENT_OSC_ENABLE!=0) begin
                                    env_state[k]<=frame_gate_a[k]?ATTACK:OFF;
                                    env_state_b[k]<=frame_gate_b[k]?ATTACK:OFF;
                                end
                            end else begin
                                if(MONO_ENABLED && (frame_mono || (mono_slot_valid && mono_slot==k)))pending_mono<=frame_mono;
                                pending_owner[k]<=event_key; pending_preset[k]<=frame_preset;
                                if(MIDI_ENABLE!=0) begin
                                    pending_midi[k]<=frame_midi[event_key*7+:7];
                                    pending_instance[k]<=frame_instance[event_key*16+:16];
                                end
                                pending_live[k]<=1;
                                if(env_state[k]!=FADE) fade_left[k]<=32;
                                env_state[k]<=FADE;
                                if(INDEPENDENT_OSC_ENABLE!=0) pending_preset_b[k]<=frame_b_preset;
                            end
                        end
                    end
                    if(event_key==NUM_SOURCES-1) begin voice_index<=0; scheduler<=PREP; end
                    else begin event_key<=event_key+1'b1; selection_wait<=0; scheduler<=ALLOC; end
                end
                PREP: begin
                    if(TEMPORAL_STORAGE_ENABLE!=0)
                        phase_restart<=(env_state[voice_index]==FADE && fade_left[voice_index]==0);
                    if(A_STATE_RAM_ENABLE!=0) begin
                        a_restart<=(env_state[voice_index]==FADE && fade_left[voice_index]==0);
                        a_restart_live<=pending_live[voice_index] && pending_held[voice_index];
                        a_restart_preset<=pending_preset[voice_index];
                    end
                    for(k=0;k<NUM_VOICES;k=k+1) if(voice_index==k) begin
                        if(env_state[k]==FADE && fade_left[k]==0) begin
                            envelope[k]<=0; phase[k]<=0; phase_b[k]<=0; release_step[k]<=0;
                            if(INDEPENDENT_OSC_ENABLE!=0) begin
                                env_state_b[k]<=OFF;
                            end
                            pending_live[k]<=0;
                            if(pending_live[k] && pending_held[k]) begin
                                if(MONO_ENABLED && mono_slot_valid && mono_slot==k)begin
                                    mono_pitch_active<=pending_mono;
                                    if(!pending_mono)mono_slot_valid<=0;
                                end
                                owner[k]<=pending_owner[k];
                                if(MIDI_ENABLE!=0) begin
                                    voice_midi[k]<=pending_midi[k];voice_instance[k]<=pending_instance[k];
                                    voice_alive[k]<=1;
                                end
                                voice_preset[k]<=pending_preset[k];
                                env_state[k]<=ATTACK;
                                remaining[k]<=(pending_preset[k]==1)?96:240;
                                if(INDEPENDENT_OSC_ENABLE!=0) begin
                                    env_state[k]<=frame_gate_a[k]?ATTACK:OFF;
                                    env_state_b[k]<=frame_gate_b[k]?ATTACK:OFF;
                                end
                            end else begin env_state[k]<=OFF; remaining[k]<=0; end
                        end
                    end
                    scheduler<=LOAD;
                end
                LOAD: begin
                    if(mono_voice && frame_mono && voice_alive[voice_index] && env_state[voice_index]!=FADE)
                        mono_base<=mono_increment;
                    if(TEMPORAL_STORAGE_ENABLE!=0)begin
                        shape_phase<=phase_restart?32'd0:phase_read_a;
                        shape_b_phase<=phase_restart?32'd0:phase_read_b;
                    end else begin
                        shape_phase<=phase[voice_index];shape_b_phase<=phase_b[voice_index];
                    end
                    alu_state<=env_state[voice_index];
                    if(A_STATE_RAM_ENABLE!=0) begin
                        alu_level<=a_restart?25'd0:a_read[27:3];
                        alu_remaining<=a_restart?(a_restart_live?
                            ((a_restart_preset==1)?15'd96:15'd240):15'd0):a_read[42:28];
                        alu_step<=a_restart?25'd0:a_read[67:43];
                        alu_preset<=a_restart?a_restart_preset:a_read[69:68];
                    end else begin
                        alu_level<=envelope[voice_index];alu_remaining<=remaining[voice_index];
                        alu_step<=release_step[voice_index];alu_preset<=voice_preset[voice_index];
                    end
                    alu_gate<=owner_held[voice_index] && (INDEPENDENT_OSC_ENABLE==0 || frame_gate_a[voice_index]);
                    if(INDEPENDENT_OSC_ENABLE!=0 && override_mask_a[voice_index])
                        frequency_product<={1'b0,frequency_read,16'b0};
                    else if(!PIPE_FREQUENCY)frequency_product<=(mono_voice?mono_frequency:((MIDI_ENABLE!=0)?midi_note_increment(voice_midi[voice_index]):
                        note_increment(owner[voice_index][4:0])))*bend_current;
                    if(INDEPENDENT_OSC_ENABLE!=0)begin scheduler<=ENV_WAIT;wait_for_b<=0;end
                    else scheduler<=CALC;
                end
                ENV_WAIT: begin
                    if(PIPE_FREQUENCY && !(wait_for_b?override_mask_b[voice_index]:override_mask_a[voice_index]))
                        frequency_product<=(mono_voice?mono_frequency:midi_base_increment)*
                            (wait_for_b?bend_b_current:bend_current);
                    result_state<=alu_next_state;result_level<=alu_next_level;
                    result_step<=alu_next_step;result_remaining<=alu_next_remaining;
                    scheduler<=wait_for_b?ACCUM:CALC;
                end
                CALC: begin
                    for(k=0;k<NUM_VOICES;k=k+1) if(voice_index==k) begin
                        if(LIVE_WAVE_ENABLE!=0) begin
                            old_candidate<=(wave_previous==0)?wave[k]:live_old;
                            new_candidate<=(wave_current==0)?wave[k]:live_new;
                        end else raw_sample<=(WAVEFORM_MODE==0)?wave[k]:alternate_wave;
                        if(DUAL_OSC_ENABLE!=0) begin
                            if(OSC2_WAVEFORM!=0) secondary_candidate<=secondary_shaped;
                            else if(OSC2_SHARE_ROM==0) secondary_candidate<=secondary_sine[k];
                            if(INDEPENDENT_OSC_ENABLE==0) begin
                                increment_b[k]<=osc2_step;
                                if(env_state[k]!=OFF) phase_b[k]<=coupled_phase_b_next;
                            end
                        end
                        increment[k]<=frequency_product[47:16];
                        if(env_state[k]!=OFF) phase[k]<=shared_phase_next;
                        if(env_state[k]==FADE) begin
                            fade_for_b<=fade_left[k];
                            effective_env<=fade_product>>5;
                            fade_left[k]<=fade_left[k]-1'b1;
                        end else begin
                            env_state[k]<=next_state; envelope[k]<=next_level;
                            remaining[k]<=next_remaining; release_step[k]<=next_step;
                            effective_env<=next_level;
                        end
                    end
                    if(DUAL_OSC_ENABLE!=0 && OSC2_WAVEFORM==0 && OSC2_SHARE_ROM!=0)
                        scheduler<=CAPTURE_B;
                    else if(LIVE_WAVE_ENABLE!=0) scheduler<=BLEND;
                    else if(DUAL_OSC_ENABLE!=0 && INDEPENDENT_OSC_ENABLE==0) scheduler<=MIX_B;
                    else scheduler<=MUL;
                end
                CAPTURE_B: begin
                    // Synchronous ROM result from CALC (before B phase update).
                    for(k=0;k<NUM_VOICES;k=k+1)
                        if(voice_index==k) secondary_candidate<=wave[k];
                    scheduler<=(LIVE_WAVE_ENABLE!=0)?BLEND:((INDEPENDENT_OSC_ENABLE!=0)?MUL:MIX_B);
                end
                BLEND: begin
                    raw_sample<=wave_blended;
                    scheduler<=(DUAL_OSC_ENABLE!=0 && INDEPENDENT_OSC_ENABLE==0)?MIX_B:MUL;
                end
                MIX_B: begin
                    raw_sample<=pair_sample; // no additional multiplier
                    scheduler<=MUL;
                end
                MUL: begin
                    voice_product<=raw_sample*env_gain; scheduler<=ACCUM;
                    if(INDEPENDENT_OSC_ENABLE!=0 && DUAL_OSC_ENABLE!=0) begin
                        scheduler<=ENV_WAIT;wait_for_b<=1;
                        alu_state<=b_read[2:0];alu_level<=b_read[27:3];
                        alu_remaining<=b_read[42:28];alu_step<=b_read[67:43];
                        alu_preset<=b_read[69:68];
                        alu_gate<=owner_held[voice_index] && frame_gate_b[voice_index];
                        if(override_mask_b[voice_index])
                            frequency_product<={1'b0,frequency_read,16'b0};
                        else if(!PIPE_FREQUENCY)frequency_product<=(mono_voice?mono_frequency:((MIDI_ENABLE!=0)?midi_note_increment(voice_midi[voice_index]):
                            note_increment(owner[voice_index][4:0])))*bend_b_current;
                    end
                end
                ACCUM: begin
                    if(INDEPENDENT_OSC_ENABLE!=0 && DUAL_OSC_ENABLE!=0) begin
                        primary_pcm<=voice_product>>>16;raw_sample<=secondary_candidate;
                        for(k=0;k<NUM_VOICES;k=k+1) if(voice_index==k) begin
                            increment_b[k]<=frequency_product[47:16];
                            if(env_state_b[k]!=OFF) phase_b[k]<=shared_phase_next;
                            if(env_state[k]==FADE) effective_env<=fade_product>>5;
                            else begin
                                env_state_b[k]<=next_state;
                                effective_env<=next_level;
                            end
                        end
                        scheduler<=MUL_B;
                    end else begin mix<=mix+(voice_product>>>16);scheduler<=NEXT;end
                end
                MUL_B: begin voice_product<=raw_sample*env_gain;scheduler<=ACCUM_B;end
                ACCUM_B: begin mix<=mix+pair_sample;scheduler<=NEXT;end
                NEXT: begin
                    if(voice_index==NUM_VOICES-1) scheduler<=OUTPUT_PCM;
                    else begin voice_index<=voice_index+1'b1; scheduler<=PREP; end
                end
                OUTPUT_PCM: begin
                    pcm<=mixed_pcm;pcm_valid<=1;scheduler<=IDLE;
                    if(LIVE_WAVE_ENABLE!=0 && wave_fade!=0) wave_fade<=wave_fade-1'b1;
                end
                default: begin fault<=1; pcm<=0; scheduler<=IDLE; end
            endcase
        end
    end
endmodule
