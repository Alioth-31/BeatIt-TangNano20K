`timescale 1ns/1ps
`include "sim/tb_full64_audio.v"
// Worst routing load:40 held sources,32 voices/64 DDS, all FX, peripheral
// polling and guide logic, including poly->mono->poly mode transitions.
module tb_mono_audio;
    tb_full64_audio #(.PERF(1),.REV(1),.MONO(1)) full();
endmodule
