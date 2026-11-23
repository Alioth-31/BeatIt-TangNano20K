`timescale 1ns/1ps
// 49.152 MHz -> 48 kHz stereo frames, 32-bit slots, standard Philips I2S.
module i2s_tx(
    input clk, input rst,
    input signed [15:0] pcm, input pcm_valid,
    output reg sample_ce, output bclk, output reg ws, output reg sd,
    output reg fault, output reg ready
);
    reg [9:0] divider;
    reg signed [15:0] active_pcm, pending_pcm;
    reg pending_valid, started;
    wire [5:0] bit_index = divider[9:4];
    assign bclk = rst ? 1'b0 : divider[3];
    always @(posedge clk) begin
        if(rst) begin
            divider<=0; ws<=0; sd<=0; sample_ce<=0;
            active_pcm<=0; pending_pcm<=0; pending_valid<=0;
            started<=0; fault<=0; ready<=0;
        end else begin
            divider<=divider+1'b1;
            sample_ce<=0;
            if(pcm_valid) begin
                pending_pcm<=pcm; pending_valid<=1;
                if(pending_valid) begin fault<=1; ready<=0; active_pcm<=0; end
            end
            if(divider==1023) begin
                sample_ce<=1;
                ws<=0; sd<=0;
                pending_valid<=0;
                if(!started) begin
                    started<=1; active_pcm<=0; ready<=0;
                end else if((pending_valid || pcm_valid) && !fault) begin
                    active_pcm<=pending_valid ? pending_pcm : pcm;
                    ready<=1;
                end else begin
                    active_pcm<=0; ready<=0; fault<=1;
                end
            end else if(divider[3:0]==15) begin
                // WS transition marks bit 0/32; MSB follows one BCLK later.
                if(bit_index==31) begin ws<=1; sd<=0; end
                else if(bit_index<16) sd<=active_pcm[15-bit_index];
                else if(bit_index>=32 && bit_index<48) sd<=active_pcm[47-bit_index];
                else sd<=0;
            end
            if(fault) begin active_pcm<=0; sd<=0; ready<=0; end
        end
    end
endmodule
