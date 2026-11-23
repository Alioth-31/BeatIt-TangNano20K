`timescale 1ns/1ps
// Reuse the existing bend LUT and the sample-clock triangle method from
// pcm_tremolo. This output modulates DDS frequency, never PCM amplitude.
// X Q16 +/-1 => +/-2 semitones; Y Q16 0..1 => 0..0.5 semitone vibrato.
// X bend and vibrato multiply, so vibrato is retained at either X end stop.
// A/B legacy pitch factors are composed by the integration layer, preserving
// oscillator B's independently selected tuning. No audio RAM is allocated.
module pitch_modulation #(parameter RATE_STEP=1748)(
    input clk,input rst,input sample_ce,
    input signed [17:0] bend_position,input [16:0] vibrato_depth,
    output reg [16:0] pitch_factor,output busy,output reg fault
);
    localparam IDLE=0,MUL_DEPTH=1,LOOKUP_X=2,MUL_X=3,LOOKUP_VIB=4,
        MUL_VIB=5,COMPOSE=6,MUL_COMPOSE=7,FINISH=8;
    reg [3:0] state;
    reg [23:0] phase;
    reg [14:0] x_coordinate,vib_coordinate;
    reg [16:0] base_factor,x_factor,pending_factor;
    reg pending_valid;
    reg signed [17:0] mul_a,mul_b;
    wire signed [35:0] product;
    wire mul_ce=!fault&&(state==MUL_DEPTH||state==MUL_X||state==MUL_VIB||state==MUL_COMPOSE);
    assign busy=state!=IDLE;
    `include "bend_table.vh"
    wire [14:0] ramp=phase[21:7];
    wire [14:0] magnitude=phase[22] ? ~ramp : ramp;
    wire signed [15:0] triangle=phase[23] ? -$signed({1'b0,magnitude}) : $signed({1'b0,magnitude});
    wire signed [17:0] x_clamped=bend_position>18'sd65536 ? 18'sd65536 :
        (bend_position < -18'sd65536 ? -18'sd65536 : bend_position);
    wire signed [17:0] x_units=(x_clamped+(x_clamped[17] ? 18'sd7 : 18'sd0)) >>> 3;
    wire [16:0] y_clamped=vibrato_depth>17'd65536 ? 17'd65536 : vibrato_depth;
    wire signed [35:0] vib_units=(product+(product[35] ? 36'sd1048575 : 36'sd0)) >>> 20;
    // 1/16-semitone table steps, interpolated with eight fractional bits.
    wire [14:0] coordinate=state==LOOKUP_X ? x_coordinate : vib_coordinate;
    wire [6:0] index=coordinate[14:8];
    wire [16:0] lo=bend_factor(index);
    wire [16:0] hi=bend_factor(index==64 ? 7'd64 : index+7'd1);
    wire [16:0] interpolated=base_factor+(product>>8);
`ifdef GOWIN_PRIMITIVES
    MULT18X18 #(.AREG(1'b0),.BREG(1'b0),.OUT_REG(1'b1),.PIPE_REG(1'b0),
        .ASIGN_REG(1'b0),.BSIGN_REG(1'b0),.MULT_RESET_MODE("SYNC")) multiplier(
        .A(mul_a),.B(mul_b),.SIA(18'd0),.SIB(18'd0),.ASEL(1'b0),.BSEL(1'b0),
        .ASIGN(1'b1),.BSIGN(1'b1),.CLK(clk),.CE(mul_ce),.RESET(rst),
        .DOUT(product),.SOA(),.SOB());
`else
    reg signed [35:0] product_model;
    assign product=product_model;
    always @(posedge clk)if(rst)product_model<=0;else if(mul_ce)product_model<=mul_a*mul_b;
`endif
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;phase<=0;fault<=0;pitch_factor<=65536;pending_factor<=65536;
            x_coordinate<=8192;vib_coordinate<=8192;base_factor<=65536;x_factor<=65536;
            pending_valid<=0;mul_a<=0;mul_b<=0;
        end else if(sample_ce)begin
            if(busy||fault)begin fault<=1;pitch_factor<=65536;state<=IDLE;pending_valid<=0;end
            else begin
                pitch_factor<=pending_valid ? pending_factor : 17'd65536;pending_valid<=0;
                phase<=phase+RATE_STEP;
                x_coordinate<=18'sd8192+x_units;
                mul_a<=triangle;mul_b<=$signed({1'b0,y_clamped});state<=MUL_DEPTH;
            end
        end else if(!fault)case(state)
            MUL_DEPTH:state<=LOOKUP_X;
            LOOKUP_X:begin
                vib_coordinate<=36'sd8192+vib_units;
                base_factor<=lo;mul_a<=$signed({1'b0,hi-lo});mul_b<=$signed({10'b0,coordinate[7:0]});state<=MUL_X;
            end
            MUL_X:state<=LOOKUP_VIB;
            LOOKUP_VIB:begin
                x_factor<=interpolated;
                base_factor<=lo;mul_a<=$signed({1'b0,hi-lo});mul_b<=$signed({10'b0,coordinate[7:0]});state<=MUL_VIB;
            end
            MUL_VIB:state<=COMPOSE;
            COMPOSE:begin mul_a<=$signed({1'b0,x_factor});mul_b<=$signed({1'b0,interpolated});state<=MUL_COMPOSE;end
            MUL_COMPOSE:state<=FINISH;
            FINISH:begin pending_factor<=product[32:16];pending_valid<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
