`timescale 1ns/1ps
// One-pole low-pass. Mode changes are sampled with each accepted PCM sample.
// Modes: 0 dry, 1 shift=2 (~2.20 kHz), 2 shift=3 (~1.02 kHz),
// 3 shift=4 (~493 Hz) at Fs=48 kHz. State continues tracking in dry mode.
module pcm_tone_filter(
    input clk, input rst,
    input signed [15:0] in_pcm, input in_valid,
    input [1:0] tone_mode,
    output reg signed [15:0] out_pcm,
    output reg out_valid
);
    reg signed [15:0] state;
    reg signed [17:0] error;
    reg signed [17:0] step;
    reg signed [17:0] next_state;
    reg [2:0] shift;
    always @* begin
        case (tone_mode)
            2'd1: shift=3'd2;
            2'd2: shift=3'd3;
            default: shift=3'd4;
        endcase
        error=$signed({{2{in_pcm[15]}},in_pcm}) - $signed({{2{state[15]}},state});
        step=error >>> shift;
        // Avoid a permanent sub-LSB offset for either polarity.
        if (step==0 && error!=0)
            step=(error>0)?18'sd1:-18'sd1;
        next_state=$signed({{2{state[15]}},state})+step;
    end
    always @(posedge clk) begin
        if (rst) begin
            state<=0;
            out_pcm<=0;
            out_valid<=0;
        end else begin
            out_valid<=in_valid;
            if (in_valid) begin
                if (tone_mode==0) begin
                    state<=in_pcm;
                    out_pcm<=in_pcm;
                end else begin
                    state<=next_state[15:0];
                    out_pcm<=next_state[15:0];
                end
            end
        end
    end
endmodule
