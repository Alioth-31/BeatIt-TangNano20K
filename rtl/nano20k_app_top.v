`timescale 1ns/1ps
// One protocol UART; constraints select BL616 USB or the independent BLE pins.
module nano20k_app_top #(
    parameter NUM_VOICES=4, parameter CONTROLS_ENABLED=1, parameter PERFORMANCE_ENABLED=0,
    parameter PERIPHERALS_ENABLED=0, parameter GUIDE_ENABLED=0,parameter MONO_ENABLED=0,
    parameter WAVEFORM_MODE=0, parameter FX_ENABLE=0,
    parameter FX_DELAY_ENABLE=0, parameter FX_DC_ENABLE=0,
    parameter FX_REVERB_ENABLE=0,
    parameter FX_TONE_ENABLE=0, parameter FX_WAVE_LIVE=0,
    parameter DUAL_OSC_ENABLE=0, parameter OSC2_WAVEFORM=0,
    parameter OSC2_DETUNE_SHIFT=7, parameter OSC2_SHARE_ROM=1, parameter INDEPENDENT_OSC_ENABLE=0, parameter DEBOUNCE_CYCLES=98304,
    parameter ENCODER_FILTER_CYCLES=1024, parameter ENCODER_EDGES=4,
    parameter SETTINGS_HOLD_SAMPLES=16800
)(input clk_audio, input reset_button, input test_button,
  input [7:0] keys_n, input [1:0] volume_ab, input volume_sw_n,
  input [1:0] bend_ab, input bend_sw_n, input uart_rx,
  inout peripheral_scl,inout peripheral_sda,
  output uart_tx, output HP_BCK, output HP_WS, output HP_DIN,
  output PA_EN, output [5:0] led_n,
  output [63:0] display_state,output signed [15:0] display_pcm,output display_valid,
  output [63:0] guide_display_state);
    reg [7:0] reset_pipe=8'hff;
    always @(posedge clk_audio or posedge reset_button)
        if(reset_button) reset_pipe<=8'hff;
        else reset_pipe<={reset_pipe[6:0],1'b0};
    wire rst=reset_pipe[7];
    (* syn_preserve=1, ASYNC_REG="TRUE" *) reg [7:0] raw_keys_meta,raw_keys_sync;
    always @(posedge clk_audio)
        if(rst) begin raw_keys_meta<=8'hff; raw_keys_sync<=8'hff; end
        else begin raw_keys_meta<=keys_n; raw_keys_sync<=raw_keys_meta; end
    wire [7:0] held,faults;
    wire [31:0] held_keys,physical_mask,frame_counter;
    wire [16:0] volume,bend;
    wire [1:0] preset,test_mode;
    wire vu,vd,bu,bd,br,pn;
    wire volume_button_down,bend_button_down;
    wire [7:0] play_keys,ui_preview_value,ui_commit_value;
    wire ui_settings_active,ui_commit_valid;
    wire [2:0] ui_selected_field,ui_commit_field;
    wire [1:0] performance_scale;wire [2:0] performance_timbre;
    wire [3:0] performance_root;wire [2:0] performance_octave;
    wire [15:0] config_revision;
    wire [39:0] performance_held;
    wire [279:0] source_midi;wire [639:0] source_instance;
    localparam SOURCE_COUNT=PERFORMANCE_ENABLED?40:32;
    wire [NUM_VOICES-1:0] active;
    wire ce,pcm_valid,core_fault,tx_fault,fx_fault,ready,busy;
    wire expression_fault;
    wire mono_fault;
    wire audio_fault=core_fault|tx_fault|fx_fault|expression_fault|mono_fault;
    wire signed [15:0] pcm;
    wire [1:0] tone_mode, waveform_mode,osc2_preset;
    wire [16:0] osc2_bend;
    wire [16:0] effective_volume,effective_bend,effective_osc2_bend;
    wire [63:0] peripheral_request;wire peripheral_commit,peripheral_config_valid;
    wire [111:0] peripheral_query;
    wire guide_commit,guide_config_valid,guide_mode,guide_song,guide_toggle;
    wire [1:0] guide_tempo;wire [127:0] guide_query;wire [55:0] mapped_physical_midi;
    wire [7:0] local_led_target,phone_led_mask,peripheral_led_applied;wire peripheral_led_available;
    wire [7:0] key_led_target=phone_led_mask!=0 && !ui_settings_active && !guide_mode ?
        phone_led_mask : local_led_target;
    wire [31:0] osc1_gate_mask,osc2_gate_mask,osc_override_increment;
    wire osc_override_enable;wire [5:0] osc_override_id;
    reg core_ce;
    wire engine_ce,engine_mono,engine_legato;
    wire [31:0] mono_increment;
    reg [31:0] requested;
    wire [SOURCE_COUNT-1:0] engine_keys;
    reg [5:0] active_count;
    // Register the active count for telemetry without delaying PCM.
    localparam ACTIVE_GROUPS=(NUM_VOICES+3)/4;
    wire [ACTIVE_GROUPS*4-1:0] active_padded={{(ACTIVE_GROUPS*4-NUM_VOICES){1'b0}},active};
    reg [2:0] active_group[0:ACTIVE_GROUPS-1];
    reg [5:0] active_sum;integer n;genvar ag;
    generate for(ag=0;ag<ACTIVE_GROUPS;ag=ag+1)begin: count_group
        always @(posedge clk_audio)
            if(rst)active_group[ag]<=0;
            else active_group[ag]<={2'b0,active_padded[ag*4]}+{2'b0,active_padded[ag*4+1]}+
                {2'b0,active_padded[ag*4+2]}+{2'b0,active_padded[ag*4+3]};
    end endgenerate
    always @* begin
        active_sum=0;
        for(n=0;n<ACTIVE_GROUPS;n=n+1)active_sum=active_sum+active_group[n];
    end
    always @(posedge clk_audio)if(rst)active_count<=0;else active_count<=active_sum;
    localparam [31:0] ALL_TEST_KEYS=(NUM_VOICES==32)?32'hffffffff:((32'b1<<NUM_VOICES)-1);
    control_surface #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.ENCODER_FILTER_CYCLES(ENCODER_FILTER_CYCLES),.ENCODER_EDGES(ENCODER_EDGES))
        controls(.clk(clk_audio),.rst(rst),.keys_n(keys_n),.volume_ab(volume_ab),.volume_sw_n(volume_sw_n),
                 .bend_ab(bend_ab),.bend_sw_n(bend_sw_n),.test_button(PERFORMANCE_ENABLED?1'b0:test_button),.held(held),
                 .test_mode(test_mode),.vol_up(vu),.vol_down(vd),.bend_up(bu),.bend_down(bd),
                 .bend_reset(br),.preset_next(pn),.volume_button_down(volume_button_down),.bend_button_down(bend_button_down));
    generate if(PERFORMANCE_ENABLED) begin: performance_panel
        performance_surface #(.HOLD_SAMPLES(SETTINGS_HOLD_SAMPLES),.GUIDE_ENABLED(GUIDE_ENABLED),.MONO_ENABLED(MONO_ENABLED)) surface(
            .clk(clk_audio),.rst(rst),.sample_ce(ce),.physical_keys(CONTROLS_ENABLED?held:8'b0),
            .settings_down(CONTROLS_ENABLED&&volume_button_down),.confirm_down(CONTROLS_ENABLED&&bend_button_down),
            .right_up(CONTROLS_ENABLED&&bu),.right_down(CONTROLS_ENABLED&&bd),
            .current_root(performance_root),.current_scale(performance_scale),
            .current_octave(performance_octave),.current_timbre(performance_timbre),
            .current_guide(guide_mode),.current_song(guide_song),.current_tempo(guide_tempo),.guide_toggle(guide_toggle),
            .play_keys(play_keys),.settings_active(ui_settings_active),.selected_field(ui_selected_field),
            .preview_value(ui_preview_value),.commit_valid(ui_commit_valid),.commit_field(ui_commit_field),.commit_value(ui_commit_value));
    end else begin: no_performance_panel
        assign play_keys=0;assign ui_settings_active=0;assign ui_selected_field=0;assign ui_preview_value=0;
        assign ui_commit_valid=0;assign ui_commit_field=0;assign ui_commit_value=0;
        assign guide_toggle=0;
    end endgenerate
    always @* begin
        case(test_mode)
            1: requested=32'h00000020;
            2: requested=(NUM_VOICES==4)?32'h00000055:ALL_TEST_KEYS;
            default: requested=held_keys;
        endcase
    end
    synth_app_bridge #(.NUM_VOICES(NUM_VOICES),.TONE_CONTROL_ENABLED(FX_TONE_ENABLE),
                         .WAVE_CONTROL_ENABLED(FX_WAVE_LIVE),.WAVE_RESET_MODE(WAVEFORM_MODE),.INDEPENDENT_CONTROL_ENABLED(INDEPENDENT_OSC_ENABLE),
                         .PERFORMANCE_ENABLED(PERFORMANCE_ENABLED),.PERIPHERALS_ENABLED(PERIPHERALS_ENABLED),.GUIDE_ENABLED(GUIDE_ENABLED),.MONO_ENABLED(MONO_ENABLED)) bridge(
        .clk(clk_audio),.rst(rst),.sample_ce(ce),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .raw_keys(raw_keys_sync),.physical_keys(CONTROLS_ENABLED?held:8'b0),
        .vol_up(CONTROLS_ENABLED&&vu),.vol_down(CONTROLS_ENABLED&&vd),
        .bend_up(CONTROLS_ENABLED&&!PERFORMANCE_ENABLED&&bu),.bend_down(CONTROLS_ENABLED&&!PERFORMANCE_ENABLED&&bd),
        .bend_reset(CONTROLS_ENABLED&&!PERFORMANCE_ENABLED&&br),.preset_next(CONTROLS_ENABLED&&!PERFORMANCE_ENABLED&&pn),
        .active_voice_count(active_count),.audio_fault(audio_fault),
        .held_keys(held_keys),.volume(volume),.bend(bend),.preset(preset),.faults(faults),
        .physical_mask(physical_mask),.frame_counter(frame_counter),.tone_mode(tone_mode),.waveform_mode(waveform_mode),
        .osc2_bend(osc2_bend),.osc2_preset(osc2_preset),.osc1_gate_mask(osc1_gate_mask),
        .osc2_gate_mask(osc2_gate_mask),.osc_override_enable(osc_override_enable),
        .osc_override_id(osc_override_id),.osc_override_increment(osc_override_increment),
        .performance_play_keys(play_keys),.ui_commit_valid(ui_commit_valid),.ui_commit_field(ui_commit_field),.ui_commit_value(ui_commit_value),
        .ui_settings_active(ui_settings_active),.ui_selected_field(ui_selected_field),.ui_preview_value(ui_preview_value),
        .performance_root(performance_root),.performance_scale(performance_scale),.performance_octave(performance_octave),
        .performance_timbre(performance_timbre),.config_revision(config_revision),.performance_held(performance_held),
        .source_midi(source_midi),.source_instance(source_instance),
        .peripheral_request(peripheral_request),.peripheral_commit(peripheral_commit),
        .peripheral_config_valid(peripheral_config_valid),.peripheral_query(peripheral_query),
        .mapped_physical_midi(mapped_physical_midi),.guide_commit(guide_commit),
        .guide_config_valid(guide_config_valid),.guide_query(guide_query),.phone_led_mask(phone_led_mask));
    generate if(GUIDE_ENABLED)begin: guide_enabled
        guide_control controller(clk_audio,rst,ce,peripheral_request,guide_commit,guide_config_valid,guide_query,
            ui_commit_valid,ui_commit_field,ui_commit_value,ui_settings_active,ui_selected_field,guide_toggle,
            // Judge keys and their latched pitches from the same bridge commit.
            mapped_physical_midi,source_midi[55:0],performance_held[7:0],MONO_ENABLED && performance_timbre==4,peripheral_led_available,peripheral_led_applied,
            guide_mode,guide_song,guide_tempo,local_led_target,guide_display_state);
    end else begin: guide_disabled
        assign guide_config_valid=0;assign guide_query=0;assign guide_display_state=0;
        assign guide_mode=0;assign guide_song=0;assign guide_tempo=2;
        assign local_led_target=ui_settings_active ? 8'd0 : (PERFORMANCE_ENABLED ? play_keys : held);
    end endgenerate
    generate if(PERIPHERALS_ENABLED)begin: expression_enabled
        wire scl_release,sda_release;
        assign peripheral_scl=scl_release ? 1'bz : 1'b0;
        assign peripheral_sda=sda_release ? 1'bz : 1'b0;
        expression_controls controls(clk_audio,rst,ce,volume,bend,osc2_bend,
            key_led_target,
            peripheral_scl,peripheral_sda,scl_release,sda_release,peripheral_request,peripheral_commit,
            peripheral_config_valid,peripheral_query,effective_volume,effective_bend,effective_osc2_bend,expression_fault,
            peripheral_led_available,peripheral_led_applied);
    end else begin: expression_disabled
        assign peripheral_scl=1'bz;assign peripheral_sda=1'bz;
        assign peripheral_config_valid=0;assign peripheral_query=0;assign expression_fault=0;
        assign peripheral_led_available=0;assign peripheral_led_applied=0;
        assign effective_volume=volume;assign effective_bend=bend;assign effective_osc2_bend=osc2_bend;
    end endgenerate
    // Commit controller state at ce, then start the audio engine one cycle later.
    always @(posedge clk_audio) if(rst) core_ce<=0; else core_ce<=ce;
    generate if(MONO_ENABLED && PERFORMANCE_ENABLED)begin: mono_path
        wire [5:0] selected_source;
        mono_priority #(.SEQUENTIAL_INSTANCE_ENABLE(1)) priority_router(
            clk_audio,rst,core_ce,performance_timbre==4,performance_held,source_instance,
            engine_ce,engine_keys,selected_source,engine_mono,engine_legato,mono_fault);
        mono_glide glide(clk_audio,rst,engine_ce,engine_mono,|engine_keys,engine_legato,
            source_midi[selected_source*7+:7],mono_increment);
    end else begin: no_mono
        assign engine_ce=core_ce;assign engine_keys=PERFORMANCE_ENABLED?performance_held:requested;
        assign engine_mono=0;assign engine_legato=0;assign mono_increment=0;assign mono_fault=0;
    end endgenerate
    synth_core #(.NUM_VOICES(NUM_VOICES),.WAVEFORM_MODE(WAVEFORM_MODE),
                  .LIVE_WAVE_ENABLE(FX_WAVE_LIVE),
                  .DUAL_OSC_ENABLE(DUAL_OSC_ENABLE),.OSC2_WAVEFORM(OSC2_WAVEFORM),
                  .OSC2_DETUNE_SHIFT(OSC2_DETUNE_SHIFT),.OSC2_SHARE_ROM(OSC2_SHARE_ROM),.INDEPENDENT_OSC_ENABLE(INDEPENDENT_OSC_ENABLE),
                  .NUM_SOURCES(SOURCE_COUNT),.MIDI_ENABLE(PERFORMANCE_ENABLED),
                  .SEQUENTIAL_INSTANCE_ENABLE(PERFORMANCE_ENABLED),
                  .A_STATE_RAM_ENABLE(PERFORMANCE_ENABLED),
                  .TEMPORAL_STORAGE_ENABLE(PERFORMANCE_ENABLED),.MONO_ENABLED(MONO_ENABLED),
                  .FREQUENCY_PIPELINE_ENABLE(PERFORMANCE_ENABLED),
                  .MIX_BOOST_SHIFT(PERFORMANCE_ENABLED ? 2 : 0)) core(
        clk_audio,rst,engine_ce,engine_keys,preset,effective_volume,effective_bend,pcm,pcm_valid,core_fault,busy,active,waveform_mode,
        effective_osc2_bend,osc2_preset,osc1_gate_mask,osc2_gate_mask,osc_override_enable,osc_override_id,osc_override_increment,
        source_midi[SOURCE_COUNT*7-1:0],source_instance[SOURCE_COUNT*16-1:0],engine_mono,engine_legato,mono_increment);
    // Optional post-mix effects share the original PCM/valid protocol.
    wire signed [15:0] tx_pcm;
    wire tx_valid;
    wire signed [15:0] fx_pcm;
    wire fx_valid;
    reg dry_play;
    reg [15:0] reverb_wet;
    reg [1:0] reverb_room;
    // Keep the selected ambience when a waveform or envelope edit changes
    // the timbre ID to Custom.
    always @(posedge clk_audio) begin
        if(rst) begin
            reverb_wet<=PERFORMANCE_ENABLED?16'd4096:16'd8192;reverb_room<=1;
            dry_play<=PERFORMANCE_ENABLED && WAVEFORM_MODE==0;
        end
        else if(ce && PERFORMANCE_ENABLED) begin
            case(performance_timbre)
                0:begin reverb_wet<=16'd4096;reverb_room<=1;dry_play<=1;end
                1:begin reverb_wet<=16'd2048;reverb_room<=0;dry_play<=0;end
                2:begin reverb_wet<=16'd8192;reverb_room<=2;dry_play<=0;end
                4:begin reverb_wet<=16'd8192;reverb_room<=1;dry_play<=0;end
                default:begin end
            endcase
        end
    end
    pcm_fx_chain #(.DC_ENABLE(FX_DC_ENABLE),
                   .TREMOLO_ENABLE(FX_ENABLE),.TONE_ENABLE(FX_TONE_ENABLE),
                   .DELAY_ENABLE(FX_DELAY_ENABLE),.REVERB_ENABLE(FX_REVERB_ENABLE)) fx_chain(
        .clk(clk_audio),.rst(rst),.in_pcm(pcm),.in_valid(pcm_valid),.tone_mode(tone_mode),
        .out_pcm(fx_pcm),.out_valid(fx_valid),.fault(fx_fault),.reverb_wet(reverb_wet),.reverb_room(reverb_room),
        .dry_play(dry_play));
    generate if(PERFORMANCE_ENABLED)begin: speaker_stage
        pcm_speaker_gain speaker_gain(clk_audio,rst,fx_pcm,fx_valid,tx_pcm,tx_valid);
    end else begin: speaker_bypass
        assign tx_pcm=fx_pcm;
        assign tx_valid=fx_valid;
    end endgenerate
    i2s_tx audio(clk_audio,rst,tx_pcm,tx_valid,ce,HP_BCK,HP_WS,HP_DIN,tx_fault,ready);
    assign PA_EN=ready && !audio_fault && !rst;
    assign led_n=~{preset,test_mode,(|faults),PA_EN};
    // Passive telemetry only. Unconnected on legacy tops and optimized away.
    assign display_state={(GUIDE_ENABLED ? ui_selected_field[2] : PERFORMANCE_ENABLED!=0),osc_override_enable,PA_EN,faults,
        active_count,play_keys,volume,performance_timbre[1:0],performance_octave,
        performance_scale,performance_root,{(MONO_ENABLED ? performance_timbre[2] : ui_preview_value[7]),ui_preview_value[6:0]},ui_selected_field[1:0],ui_settings_active};
    assign display_pcm=tx_pcm;
    assign display_valid=tx_valid;
endmodule
