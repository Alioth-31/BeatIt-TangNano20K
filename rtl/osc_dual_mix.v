`timescale 1ns/1ps
// Two signed PCM oscillators -> one 16-bit voice sample (no DSP multiplier).
// Sum is explicitly widened to 17 signed bits before /2, so 0x8000+0x8000
// produces -32768 rather than overflowing a 16-bit intermediate.
module osc_dual_mix(
    input signed [15:0] primary,
    input signed [15:0] secondary,
    output signed [15:0] sample_out
);
    wire signed [16:0] sum =
        $signed({primary[15],primary}) + $signed({secondary[15],secondary});
    assign sample_out = sum >>> 1;
endmodule
