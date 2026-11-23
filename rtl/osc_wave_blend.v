`timescale 1ns/1ps
// Signed 16-bit waveform crossfade, fade_left=32..1 for the transition.
// Works on samples evaluated at the same oscillator phase. No registers.
module osc_wave_blend(
    input signed [15:0] sample_old,
    input signed [15:0] sample_new,
    input [5:0] fade_left,
    output signed [15:0] sample_out
);
    wire signed [16:0] difference =
        $signed({sample_new[15],sample_new}) -
        $signed({sample_old[15],sample_old});
    wire signed [6:0] new_weight =
        7'sd32 - $signed({1'b0,fade_left});
    wire signed [23:0] weighted = difference * new_weight;
    wire signed [17:0] blended =
        $signed({{2{sample_old[15]}},sample_old}) + (weighted >>> 5);
    assign sample_out = (fade_left==0) ? sample_new : blended[15:0];
endmodule
