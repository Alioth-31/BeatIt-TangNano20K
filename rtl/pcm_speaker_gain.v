`timescale 1ns/1ps
// Linear speaker makeup gain with protection at the signed PCM rails.
module pcm_speaker_gain(
    input clk, input rst,
    input signed [15:0] in_pcm, input in_valid,
    output reg signed [15:0] out_pcm, output reg out_valid
);
    always @(posedge clk) begin
        if(rst)begin
            out_pcm<=0;
            out_valid<=0;
        end else begin
            if(in_pcm[15:13]==3'b000 || in_pcm[15:13]==3'b111)
                out_pcm<={in_pcm[13:0],2'b00};
            else
                out_pcm<=in_pcm[15] ? 16'sh8000 : 16'sh7fff;
            out_valid<=in_valid;
        end
    end
endmodule
