`timescale 1ns/1ps
// Single-sample-rate amplitude modulation on a completed PCM frame.
// Independent 16-bit fixed-point design using the standard LFO tremolo method;
// relevant background: Maxixler/fpga-guitar-processor (license unverified).
// fixed-point gain has an exact unity case at depth 0.
// The phase steps once per accepted 48 kHz sample, not per FPGA clock.
module pcm_tremolo #(
    parameter DEPTH=160,                // 0..255; 0 is bit-exact dry
    parameter RATE_STEP=1049            // ~3.001 Hz for a 24-bit LFO at 48 kHz
)(
    input clk, input rst,
    input signed [15:0] in_pcm,
    input in_valid, input bypass,
    output reg signed [15:0] out_pcm,
    output reg out_valid
);
    reg [23:0] phase;
    wire [14:0] ramp = phase[22:8];
    wire [15:0] triangle = phase[23] ? {~ramp,1'b0} : {ramp,1'b0};
    wire [8:0] scaled_depth = (DEPTH==255) ? 9'd256 : DEPTH;
    wire [16:0] gap = 17'd65536 - {1'b0,triangle};
    wire [25:0] attenuation = gap * scaled_depth;
    wire [16:0] gain = 17'd65536 - (attenuation >> 8);
    wire signed [33:0] product = $signed(in_pcm) * $signed({1'b0,gain});
    wire signed [33:0] scaled = product >>> 16;

    always @(posedge clk) begin
        if (rst) begin
            phase <= 0;
            out_pcm <= 0;
            out_valid <= 0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_pcm <= bypass ? in_pcm : scaled[15:0];
                phase <= phase + RATE_STEP;
            end
        end
    end
endmodule
