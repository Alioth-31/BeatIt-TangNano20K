`timescale 1ns/1ps
`include "sim/tb_full64_audio.v"
// Production 32 voices/64 DDS, all original FX plus reverb, 1024-cycle frames.
module tb_reverb_audio;
    tb_full64_audio #(.PERF(1),.REV(1)) full();
endmodule
