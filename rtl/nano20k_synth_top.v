`timescale 1ns/1ps
module nano20k_synth_top #(
    parameter NUM_VOICES=4,
    parameter WAVEFORM_MODE=0, parameter FX_ENABLE=0,
    parameter FX_DELAY_ENABLE=0, parameter FX_DC_ENABLE=0,
    parameter FX_REVERB_ENABLE=0,
    parameter FX_TONE_ENABLE=0, parameter FX_WAVE_LIVE=0,
    parameter DUAL_OSC_ENABLE=0, parameter OSC2_WAVEFORM=0,
    parameter OSC2_DETUNE_SHIFT=7, parameter OSC2_SHARE_ROM=1, parameter INDEPENDENT_OSC_ENABLE=0,
    parameter DEBOUNCE_CYCLES=98304,
    parameter ENCODER_FILTER_CYCLES=1024,
    parameter ENCODER_EDGES=4
)(input clk_audio, input reset_button, input test_button,
  input [7:0] keys_n, input [1:0] volume_ab, input volume_sw_n,
  input [1:0] bend_ab, input bend_sw_n,
  output HP_BCK, output HP_WS, output HP_DIN, output PA_EN, output [5:0] led_n);
    // FPGA configuration initializes asserted reset; key S2 also asserts it.
    // All core registers see synchronous release on clk_audio.
    reg [7:0] reset_pipe=8'hff;
    always @(posedge clk_audio or posedge reset_button)
        if(reset_button) reset_pipe<=8'hff;
        else reset_pipe<={reset_pipe[6:0],1'b0};
    wire rst=reset_pipe[7];
    wire [7:0] held;
    wire [16:0] volume,bend;
    wire [1:0] preset,test_mode;
    wire [NUM_VOICES-1:0] active;
    wire ce,pcm_valid,core_fault,tx_fault,fx_fault,ready,busy;
    wire signed [15:0] pcm;
    wire [1:0] tone_mode=2'd0;
    reg [31:0] requested;
    localparam [31:0] ALL_TEST_KEYS=(NUM_VOICES==32)?32'hffffffff:((32'b1<<NUM_VOICES)-1);
    control_surface #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),.ENCODER_FILTER_CYCLES(ENCODER_FILTER_CYCLES),.ENCODER_EDGES(ENCODER_EDGES))
        controls(.clk(clk_audio),.rst(rst),.keys_n(keys_n),.volume_ab(volume_ab),.volume_sw_n(volume_sw_n),
                 .bend_ab(bend_ab),.bend_sw_n(bend_sw_n),.test_button(test_button),.held(held),
                 .volume(volume),.bend(bend),.preset(preset),.test_mode(test_mode));
    always @* begin
        case(test_mode)
            1: requested=32'h00000020; // A4, 440 Hz
            2: requested=(NUM_VOICES==4)?32'h00000055:ALL_TEST_KEYS;
            default: requested={24'b0,held};
        endcase
    end
    synth_core #(.NUM_VOICES(NUM_VOICES),.WAVEFORM_MODE(WAVEFORM_MODE),
                  .LIVE_WAVE_ENABLE(FX_WAVE_LIVE),
                  .DUAL_OSC_ENABLE(DUAL_OSC_ENABLE),.OSC2_WAVEFORM(OSC2_WAVEFORM),
                  .OSC2_DETUNE_SHIFT(OSC2_DETUNE_SHIFT),.OSC2_SHARE_ROM(OSC2_SHARE_ROM),.INDEPENDENT_OSC_ENABLE(INDEPENDENT_OSC_ENABLE))
        core(clk_audio,rst,ce,requested,preset,volume,bend,pcm,pcm_valid,core_fault,busy,active,WAVEFORM_MODE[1:0],17'd66048,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,224'd0,512'd0,1'b0,1'b0,32'd0);
    // Optional post-mix effects share the original PCM/valid protocol.
    wire signed [15:0] tx_pcm;
    wire tx_valid;
    pcm_fx_chain #(.DC_ENABLE(FX_DC_ENABLE),
                   .TREMOLO_ENABLE(FX_ENABLE),.TONE_ENABLE(FX_TONE_ENABLE),
                   .DELAY_ENABLE(FX_DELAY_ENABLE),.REVERB_ENABLE(FX_REVERB_ENABLE)) fx_chain(
        .clk(clk_audio),.rst(rst),.in_pcm(pcm),.in_valid(pcm_valid),.tone_mode(tone_mode),
        .out_pcm(tx_pcm),.out_valid(tx_valid),.fault(fx_fault),.reverb_wet(16'd8192),.reverb_room(2'd1),.dry_play(1'b0));
    i2s_tx tx(clk_audio,rst,tx_pcm,tx_valid,ce,HP_BCK,HP_WS,HP_DIN,tx_fault,ready);
    assign PA_EN=ready && !core_fault && !tx_fault && !fx_fault && !rst;
    // Active-low board LEDs: run, fault, test mode[1:0], preset[1:0].
    assign led_n=~{preset,test_mode,(core_fault|tx_fault|fx_fault),PA_EN};
endmodule
