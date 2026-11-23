`timescale 1ns/1ps
// Optional wrapper; audio timing/control are owned by the original app top.
module nano20k_hdmi_top #(
    parameter NUM_VOICES=4, parameter CONTROLS_ENABLED=1, parameter PERFORMANCE_ENABLED=0,
    parameter PERIPHERALS_ENABLED=0, parameter GUIDE_ENABLED=0,parameter MONO_ENABLED=0,
    parameter WAVEFORM_MODE=0, parameter FX_ENABLE=0,
    parameter FX_DELAY_ENABLE=0, parameter FX_DC_ENABLE=0,
    parameter FX_REVERB_ENABLE=0,
    parameter FX_TONE_ENABLE=0, parameter FX_WAVE_LIVE=0,
    parameter DUAL_OSC_ENABLE=0, parameter OSC2_WAVEFORM=0,
    parameter OSC2_DETUNE_SHIFT=7, parameter OSC2_SHARE_ROM=1, parameter INDEPENDENT_OSC_ENABLE=0,
    parameter DEBOUNCE_CYCLES=98304,parameter ENCODER_FILTER_CYCLES=1024,
    parameter ENCODER_EDGES=4,parameter SETTINGS_HOLD_SAMPLES=16800
)(input clk_audio,input clk_video,input reset_button,input test_button,
    input [7:0] keys_n,input [1:0] volume_ab,input volume_sw_n,
    input [1:0] bend_ab,input bend_sw_n,input uart_rx,
    inout peripheral_scl,inout peripheral_sda,
    output uart_tx,output HP_BCK,output HP_WS,output HP_DIN,output PA_EN,output [5:0] led_n,
    output tmds_clk_p,output tmds_clk_n,output [2:0] tmds_data_p,output [2:0] tmds_data_n);
    wire [63:0] instrument_state,visible_state;wire signed [15:0] output_pcm;wire pcm_valid;
    wire [63:0] guide_state,visible_guide;
    localparam STATE_WIDTH=GUIDE_ENABLED ? 128 : 64;
    wire [STATE_WIDTH-1:0] capture_state,captured_state;
    assign capture_state=GUIDE_ENABLED ? {guide_state,instrument_state} : instrument_state;
    assign visible_state=captured_state[63:0];
    generate if(GUIDE_ENABLED)begin: guide_snapshot
        assign visible_guide=captured_state[127:64];
    end else begin: no_guide_snapshot
        assign visible_guide=0;
    end endgenerate
    nano20k_app_top #(.NUM_VOICES(NUM_VOICES),.CONTROLS_ENABLED(CONTROLS_ENABLED),.PERFORMANCE_ENABLED(PERFORMANCE_ENABLED),
        .PERIPHERALS_ENABLED(PERIPHERALS_ENABLED),.GUIDE_ENABLED(GUIDE_ENABLED),.MONO_ENABLED(MONO_ENABLED),
        .WAVEFORM_MODE(WAVEFORM_MODE),.FX_ENABLE(FX_ENABLE),.FX_DELAY_ENABLE(FX_DELAY_ENABLE),.FX_DC_ENABLE(FX_DC_ENABLE),
        .FX_REVERB_ENABLE(FX_REVERB_ENABLE),
        .FX_TONE_ENABLE(FX_TONE_ENABLE),.FX_WAVE_LIVE(FX_WAVE_LIVE),.DUAL_OSC_ENABLE(DUAL_OSC_ENABLE),
        .OSC2_WAVEFORM(OSC2_WAVEFORM),.OSC2_DETUNE_SHIFT(OSC2_DETUNE_SHIFT),.OSC2_SHARE_ROM(OSC2_SHARE_ROM),
        .INDEPENDENT_OSC_ENABLE(INDEPENDENT_OSC_ENABLE),.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .ENCODER_FILTER_CYCLES(ENCODER_FILTER_CYCLES),.ENCODER_EDGES(ENCODER_EDGES),.SETTINGS_HOLD_SAMPLES(SETTINGS_HOLD_SAMPLES))
        instrument(.clk_audio(clk_audio),.reset_button(reset_button),.test_button(test_button),.keys_n(keys_n),
        .volume_ab(volume_ab),.volume_sw_n(volume_sw_n),.bend_ab(bend_ab),.bend_sw_n(bend_sw_n),.uart_rx(uart_rx),
        .peripheral_scl(peripheral_scl),.peripheral_sda(peripheral_sda),
        .uart_tx(uart_tx),.HP_BCK(HP_BCK),.HP_WS(HP_WS),.HP_DIN(HP_DIN),.PA_EN(PA_EN),.led_n(led_n),
        .display_state(instrument_state),.display_pcm(output_pcm),.display_valid(pcm_valid),.guide_display_state(guide_state));
    wire pixel_clk,video_rst,frame_tick,hs,vs,de,visible_valid;
    wire [1:0] visible_stride;
    wire [9:0] x,y;wire [8:0] wave_address;wire [7:0] wave,red,green,blue;wire out_hs,out_vs,out_de;
    video_timing timing(pixel_clk,video_rst,x,y,hs,vs,de,frame_tick);
    hdmi_capture #(.STATE_WIDTH(STATE_WIDTH)) capture(clk_audio,reset_button,capture_state,output_pcm,pcm_valid,
        pixel_clk,video_rst,frame_tick,wave_address,captured_state,wave,visible_valid,visible_stride);
    hdmi_status #(.GUIDE_ENABLED(GUIDE_ENABLED),.MONO_ENABLED(MONO_ENABLED)) screen(pixel_clk,video_rst,x,y,hs,vs,de,visible_state,visible_valid,wave,wave_address,
        red,green,blue,out_hs,out_vs,out_de,visible_guide,visible_stride);
    hdmi_output display(clk_video,reset_button,red,green,blue,out_hs,out_vs,out_de,pixel_clk,video_rst,
        tmds_clk_p,tmds_clk_n,tmds_data_p,tmds_data_n);
endmodule
