`timescale 1ns/1ps
module pcm_gain #(parameter WIDTH=18, parameter SHIFT=2)(
    input signed [WIDTH-1:0] mix, input [16:0] gain,
    output reg signed [15:0] pcm
);
    wire signed [WIDTH-1:0] scaled=mix>>>SHIFT;
    wire signed [17:0] positive_gain=$signed({1'b0,gain});
    wire signed [WIDTH+17:0] product=scaled*positive_gain;
    wire signed [WIDTH+17:0] result=product>>>16;
    always @* begin
        if(result>32767) pcm=16'sh7fff;
        else if(result< -32768) pcm=16'sh8000;
        else pcm=result[15:0];
    end
endmodule
