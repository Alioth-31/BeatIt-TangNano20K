`timescale 1ns/1ps
// Mono streaming echo with one 16-bit circular buffer and shift-only gains.
// Accepts one PCM sample per audio frame. Input valid strobes must be at least
// three FPGA clocks apart. RAM has no reset; unwritten positions are masked. A bypass sample flushes
// delay history so returning to wet mode cannot replay stale audio.
// Default 4096 samples = 85.33 ms at 48 kHz, using 65536 RAM bits.
module pcm_delay #(
    parameter DELAY_SAMPLES=4096,
    parameter WET_SHIFT=1,
    parameter FEEDBACK_SHIFT=2
)(
    input clk, input rst,
    input signed [15:0] in_pcm,
    input in_valid, input bypass,
    output reg signed [15:0] out_pcm,
    output reg out_valid,
    output reg fault
);
    function integer clog2;
        input integer value;
        integer v;
        begin
            v=value-1; clog2=0;
            while(v>0) begin clog2=clog2+1; v=v>>1; end
        end
    endfunction
    localparam PTR_W=(DELAY_SAMPLES<=2)?1:clog2(DELAY_SAMPLES);
    localparam COUNT_W=clog2(DELAY_SAMPLES+1);
    (* syn_ramstyle="block_ram" *) reg signed [15:0] history [0:DELAY_SAMPLES-1];
    reg [PTR_W-1:0] ptr;
    reg [COUNT_W-1:0] filled;
    reg signed [15:0] dry, delayed;
    reg sample_bypass, pending;

    wire signed [17:0] dry_w={{2{dry[15]}},dry};
    wire signed [17:0] tap_w={{2{delayed[15]}},delayed};
    wire signed [17:0] output_sum=dry_w+(tap_w >>> WET_SHIFT);
    wire signed [17:0] memory_sum=dry_w+(tap_w >>> FEEDBACK_SHIFT);

    function signed [15:0] sat16;
        input signed [17:0] x;
        begin
            if(x>18'sd32767) sat16=16'sh7fff;
            else if(x< -18'sd32768) sat16=16'sh8000;
            else sat16=x[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if(rst) begin
            ptr<=0; filled<=0; dry<=0; delayed<=0;
            sample_bypass<=1; pending<=0;
            out_pcm<=0; out_valid<=0; fault<=0;
        end else begin
            out_valid<=0;
            if(fault) begin
                pending<=0;
                out_pcm<=0;
            end else if(pending) begin
                if(in_valid) begin
                    // Do not silently lose a sample or output a corrupted frame.
                    fault<=1; pending<=0; out_pcm<=0;
                end else begin
                    if(sample_bypass) begin
                        // Bypass is a true dry state: discard the echo tail.
                        // Clearing the occupancy counter, rather than the RAM,
                        // keeps the memory block inferable as BSRAM.
                        out_pcm<=dry;
                        ptr<=0;
                        filled<=0;
                    end else begin
                        history[ptr]<=sat16(memory_sum);
                        out_pcm<=sat16(output_sum);
                        if(ptr==DELAY_SAMPLES-1) ptr<=0;
                        else ptr<=ptr+1'b1;
                        if(filled<DELAY_SAMPLES) filled<=filled+1'b1;
                    end
                    out_valid<=1;
                    pending<=0;
                end
            end else if(in_valid) begin
                dry<=in_pcm;
                delayed<=(filled==DELAY_SAMPLES) ? history[ptr] : 16'sd0;
                sample_bypass<=bypass;
                pending<=1;
            end
        end
    end
endmodule
