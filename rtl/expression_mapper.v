`timescale 1ns/1ps
// Project-specific ADS1015 calibration/normalisation, sharing the unchanged
// PicoRV32 unsigned divider. No CPU, bus firmware or audio clock gating.
// Calibration words, low first: pressure zero/max, X min/centre/max,
// Y min/centre/max. All are SIGNED 12-bit ADC codes, not voltages.
// Outputs: pressure Q16 0..1; X signed Q16 -1..+1; Y magnitude Q16 0..1.
// The next layer applies +/-2 semitone bend and preset vibrato depth/rate.
// Results publish atomically at sample_ce, one frame after the input snapshot.
module expression_mapper #(
    parameter integer STALE_SAMPLES=384, // 8 ms at 48 kHz; per-channel update freshness
    parameter integer DEAD_CODES=16, parameter integer MIN_SPAN=64
)(
    input clk,input rst,input sample_ce,
    input [47:0] adc_samples,input [3:0] adc_valid,input adc_available,
    input sample_update,input [1:0] sample_channel,
    input cal_commit,input [95:0] calibration,input [2:0] calibration_mask,
    input invert_x,input [2:0] enable_mask,
    output reg [16:0] expression_gain,output reg signed [17:0] bend_position,
    output reg [16:0] vibrato_depth,
    output reg [2:0] calibrated,output reg [2:0] active,
    output busy,output reg fault
);
    localparam IDLE=0,PREPARE=1,DIVIDE=2,STORE=3,GAP=4;
    reg [2:0] state;
    reg [1:0] channel,gap_count;
    reg [95:0] cfg;reg reverse_x;
    reg [35:0] frame_samples;
    reg [2:0] frame_active,seen;
    reg [15:0] age [0:2];
    reg [16:0] result [0:2];reg result_negative,negative;
    reg result_ready;
    reg [16:0] answer;
    reg [31:0] numerator,denominator;
    reg div_valid;
    wire [31:0] quotient;wire div_ready;
    wire divider_reset=rst||cal_commit||fault||(sample_ce&&busy);
    assign busy=(state!=IDLE);
    picorv32_pcpi_div divider(.clk(clk),.resetn(!divider_reset),
        .pcpi_valid(div_valid),.pcpi_insn(32'h02005033), // DIVU x0,x0,x0
        .pcpi_rs1(numerator),.pcpi_rs2(denominator),.pcpi_wr(),
        .pcpi_rd(quotient),.pcpi_wait(),.pcpi_ready(div_ready));

    function signed [12:0] word;
        input [95:0] packed_words;input integer index;
        reg signed [11:0] value;
        begin value=packed_words[index*12+:12];word=value;end
    endfunction
    wire [2:0] fresh={seen[2]&&age[2]<STALE_SAMPLES,
                     seen[1]&&age[1]<STALE_SAMPLES,seen[0]&&age[0]<STALE_SAMPLES};
    wire [2:0] usable=calibrated & enable_mask & adc_valid[2:0] & fresh & {3{adc_available}};
    wire signed [11:0] raw_code=frame_samples[channel*12+:12];
    wire signed [12:0] raw_extended=raw_code;
    reg signed [12:0] low,centre,high,dead_edge;
    reg [12:0] distance,span;
    reg mapped_negative;
    always @* begin
        low=word(cfg,0);high=word(cfg,1);centre=0;dead_edge=0;
        distance=0;span=1;mapped_negative=0;
        if(channel!=0)begin
            low=channel==1?word(cfg,2):word(cfg,5);
            centre=channel==1?word(cfg,3):word(cfg,6);
            high=channel==1?word(cfg,4):word(cfg,7);
        end
        if(channel==0)begin
            span=high-low;
            if(raw_extended<=low)distance=0;
            else if(raw_extended>=high)distance=span;
            else distance=raw_extended-low;
        end else if(raw_extended < centre-DEAD_CODES)begin
            dead_edge=centre-DEAD_CODES;span=dead_edge-low;
            distance=raw_extended<=low?span:dead_edge-raw_extended;
            mapped_negative=channel==1&&!reverse_x;
        end else if(raw_extended > centre+DEAD_CODES)begin
            dead_edge=centre+DEAD_CODES;span=high-dead_edge;
            distance=raw_extended>=high?span:raw_extended-dead_edge;
            mapped_negative=channel==1&&reverse_x;
        end
    end

    integer j,k;
    always @(posedge clk)begin
        if(rst)begin
            seen<=0;
            for(j=0;j<3;j=j+1)age[j]<=STALE_SAMPLES;
        end else for(j=0;j<3;j=j+1)begin
            if(!adc_available||!adc_valid[j])begin seen[j]<=0;age[j]<=STALE_SAMPLES;end
            else if(sample_update&&sample_channel==j)begin seen[j]<=1;age[j]<=0;end
            else if(sample_ce&&age[j]<STALE_SAMPLES)age[j]<=age[j]+1'b1;
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;channel<=0;gap_count<=0;cfg<=0;reverse_x<=0;calibrated<=0;
            frame_samples<=0;frame_active<=0;result_ready<=0;result_negative<=0;negative<=0;
            expression_gain<=65536;bend_position<=0;vibrato_depth<=0;active<=0;fault<=0;
            numerator<=0;denominator<=1;div_valid<=0;answer<=0;
            for(k=0;k<3;k=k+1)result[k]<=0;
        end else if(cal_commit)begin
            // Abort the previous epoch, including an in-flight division.
            cfg<=calibration;reverse_x<=invert_x;state<=IDLE;div_valid<=0;result_ready<=0;
            calibrated[0]<=calibration_mask[0] && word(calibration,1)-word(calibration,0)>=MIN_SPAN;
            calibrated[1]<=calibration_mask[1] && word(calibration,3)-word(calibration,2)>=MIN_SPAN+DEAD_CODES
                && word(calibration,4)-word(calibration,3)>=MIN_SPAN+DEAD_CODES;
            calibrated[2]<=calibration_mask[2] && word(calibration,6)-word(calibration,5)>=MIN_SPAN+DEAD_CODES
                && word(calibration,7)-word(calibration,6)>=MIN_SPAN+DEAD_CODES;
            if(sample_ce)begin expression_gain<=65536;bend_position<=0;vibrato_depth<=0;active<=0;end
        end else if(sample_ce)begin
            if(busy||fault)begin
                fault<=1;expression_gain<=65536;bend_position<=0;vibrato_depth<=0;active<=0;
                div_valid<=0;state<=IDLE;result_ready<=0;
            end else begin
                active<=result_ready?(frame_active&usable):3'b0;
                expression_gain<=(result_ready&&frame_active[0]&&usable[0])?result[0]:17'd65536;
                bend_position<=(result_ready&&frame_active[1]&&usable[1])?
                    (result_negative?-$signed({1'b0,result[1]}):$signed({1'b0,result[1]})):18'sd0;
                vibrato_depth<=(result_ready&&frame_active[2]&&usable[2])?result[2]:17'd0;
                frame_samples<=adc_samples[35:0];frame_active<=usable;
                result_ready<=0;channel<=0;state<=PREPARE;
            end
        end else if(!fault)case(state)
            PREPARE:begin
                negative<=mapped_negative;
                if(!frame_active[channel])begin answer<=channel==0?17'd65536:17'd0;negative<=0;state<=STORE;end
                else if(distance==0)begin answer<=0;state<=STORE;end
                else if(distance>=span)begin answer<=65536;state<=STORE;end
                else begin
                    numerator<={3'b0,distance,16'b0};denominator<={19'b0,span};
                    div_valid<=1;state<=DIVIDE;
                end
            end
            DIVIDE:if(div_ready)begin answer<=quotient[16:0];div_valid<=0;state<=STORE;end
            STORE:begin
                result[channel]<=answer;
                if(channel==1)result_negative<=negative;
                if(channel==2)begin result_ready<=1;state<=IDLE;end
                else begin channel<=channel+1'b1;gap_count<=0;state<=GAP;end
            end
            GAP:if(gap_count==2)state<=PREPARE;else gap_count<=gap_count+1'b1;
            default:state<=IDLE;
        endcase
    end
endmodule
