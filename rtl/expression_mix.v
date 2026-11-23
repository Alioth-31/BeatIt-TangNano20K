`timescale 1ns/1ps
// Frame-boundary adapter to existing synth_core target controls.
// One shared multiplier preserves independent A/B tuning; the core retains
// its existing volume and frequency smoothing. No samples or audio RAM here.
module expression_mix(
    input clk,input rst,input sample_ce,
    input [16:0] volume,input [16:0] bend_a,input [16:0] bend_b,
    input [16:0] expression_gain,input [16:0] pitch_factor,
    output reg [16:0] effective_volume,output reg [16:0] effective_a,
    output reg [16:0] effective_b,output busy,output reg fault
);
    localparam IDLE=0,MUL_VOLUME=1,PREP_A=2,MUL_A=3,PREP_B=4,MUL_B=5,FINISH=6;
    reg [2:0] state;reg pending_valid;
    reg [16:0] frame_a,frame_b,frame_pitch,pending_volume,pending_a,pending_b;
    reg signed [17:0] mul_a,mul_b;wire signed [35:0] product;
    wire mul_ce=!fault&&(state==MUL_VOLUME||state==MUL_A||state==MUL_B);
    wire [19:0] scaled=product[35:16];
    wire [16:0] ratio=scaled>20'd131071 ? 17'd131071 : scaled[16:0];
    wire [16:0] safe_volume=volume>17'd65536 ? 17'd65536 : volume;
    wire [16:0] safe_gain=expression_gain>17'd65536 ? 17'd65536 : expression_gain;
    assign busy=state!=IDLE;
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
            state<=IDLE;fault<=0;pending_valid<=0;
            effective_volume<=0;effective_a<=65536;effective_b<=65536;
            frame_a<=65536;frame_b<=65536;frame_pitch<=65536;
            pending_volume<=0;pending_a<=65536;pending_b<=65536;mul_a<=0;mul_b<=0;
        end else if(sample_ce)begin
            if(busy||fault)begin
                fault<=1;effective_volume<=0;effective_a<=65536;effective_b<=65536;
                state<=IDLE;pending_valid<=0;
            end else begin
                effective_volume<=pending_valid ? pending_volume : 17'd0;
                effective_a<=pending_valid ? pending_a : 17'd65536;
                effective_b<=pending_valid ? pending_b : 17'd65536;
                pending_valid<=0;frame_a<=bend_a;frame_b<=bend_b;frame_pitch<=pitch_factor;
                mul_a<=$signed({1'b0,safe_volume});mul_b<=$signed({1'b0,safe_gain});state<=MUL_VOLUME;
            end
        end else if(!fault)case(state)
            MUL_VOLUME:state<=PREP_A;
            PREP_A:begin pending_volume<=ratio;mul_a<=$signed({1'b0,frame_a});mul_b<=$signed({1'b0,frame_pitch});state<=MUL_A;end
            MUL_A:state<=PREP_B;
            PREP_B:begin pending_a<=ratio;mul_a<=$signed({1'b0,frame_b});state<=MUL_B;end
            MUL_B:state<=FINISH;
            FINISH:begin pending_b<=ratio;pending_valid<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
