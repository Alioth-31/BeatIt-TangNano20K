`timescale 1ns/1ps
// Phase-to-waveform adapter for the existing 32-bit DDS accumulator.
// Adapted from the phase-only waveform architecture of noaidi-fpga-synth.
// 0: original sine path (handled by synth_core ROM), 1: saw,
// 2: 50% pulse, 3: triangle. Does not own or advance the phase.
module osc_wave_shape(
    input [31:0] phase,
    input [1:0] waveform,
    output reg signed [15:0] sample
);
    wire signed [15:0] saw = $signed(phase[31:16] ^ 16'h8000);
    wire [14:0] slope = phase[29:15];
    reg signed [15:0] triangle;

    always @* begin
        case (phase[31:30])
            2'd0: triangle = $signed({1'b0, slope});
            2'd1: triangle = 16'sd32767 - $signed({1'b0, slope});
            2'd2: triangle = -$signed({1'b0, slope});
            default: triangle = -16'sd32767 + $signed({1'b0, slope});
        endcase
        case (waveform)
            2'd1: sample = saw;
            2'd2: sample = phase[31] ? -16'sd32767 : 16'sd32767;
            2'd3: sample = triangle;
            default: sample = 16'sd0;
        endcase
    end
endmodule
