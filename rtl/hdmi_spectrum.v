`timescale 1ns/1ps
// One 256-point DFT bin per blanking row. The two quadratures share
// one coefficient ROM and multiply-accumulate path across all 32 bins.
module hdmi_spectrum(input clk,input [9:0] x,y,input valid,input signed [7:0] pcm,
    output fetch,output reg hit);
    wire analysis_row=y>=10'd492 && y<10'd524;
    wire [4:0] bin=y[4:0]-5'd12;
    wire [5:0] step={1'b0,bin}+6'd1;
    wire start=x[8:0]==0;
    assign fetch=valid && analysis_row && !x[8];

    reg [7:0] phase;
    wire [7:0] coefficient_address=start ? (x[9] ? 8'd0 : 8'd64) : phase;
    (* syn_romstyle="block_rom" *) reg signed [7:0] sine[0:255];
    initial $readmemh("rtl/display_sine.hex",sine);
    reg signed [7:0] coefficient;
    reg fetch_d;
    reg signed [22:0] accumulator;
    wire signed [15:0] product=pcm*coefficient;
    wire [6:0] component=accumulator[21:15]^{7{accumulator[22]}};
    reg [6:0] cosine;
    wire [7:0] magnitude={1'b0,cosine}+{1'b0,component};
    reg [5:0] bars[0:31];

    reg [5:0] height;
    reg [5:0] from_bottom;
    reg panel_d;
    always @(posedge clk)begin
        coefficient<=sine[coefficient_address];
        fetch_d<=fetch;
        if(fetch)phase<=coefficient_address+step;
        if(start)accumulator<=0;
        else if(fetch_d)accumulator<=accumulator+product;
        if(valid && analysis_row && x[8:0]==9'd257)begin
            if(x[9])bars[bin]<= (|magnitude[7:6]) ? 6'd63 : magnitude[5:0];
            else cosine<=component;
        end
        height<=bars[x[8:4]];
        from_bottom<=y[6:1]^6'b011111;
        panel_d<=valid && !x[9] && y>=10'd320 && y<10'd448 &&
            (x[3:0]==4'd7 || x[3:0]==4'd8);
        hit<=panel_d && from_bottom<height;
    end
endmodule
