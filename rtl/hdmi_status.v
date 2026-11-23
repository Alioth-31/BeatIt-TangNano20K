`timescale 1ns/1ps
// Scan renderer: fixed text + one actual post-effects PCM waveform.
// Font lookup, wave RAM and syncs share a two-clock pixel pipeline.
module hdmi_status #(parameter GUIDE_ENABLED=0,parameter MONO_ENABLED=0)(input clk,input rst,input [9:0] x,input [9:0] y,
    input hs,input vs,input de,input [63:0] state,input valid,input [7:0] wave,
    output [8:0] wave_address,output reg [7:0] red,green,blue,
    output reg out_hs,out_vs,out_de,input [63:0] guide_state,input [1:0] wave_stride);
    wire settings=state[0];wire [2:0] field={GUIDE_ENABLED && state[63],state[2:1]};
    // All current menu values fit7 bits. Mono-enabled builds use the spare
    // high preview bit for timbre[2], keeping the atomic64-bit instrument bus.
    wire [7:0] preview={(MONO_ENABLED?1'b0:state[10]),state[9:3]};
    wire [3:0] root=state[14:11];wire [1:0] scale=state[16:15];wire [2:0] octave=state[19:17];
    wire [2:0] timbre={MONO_ENABLED && state[10],state[21:20]};wire [16:0] volume=state[38:22];
    wire [7:0] keys=state[46:39];wire [5:0] active=state[52:47];
    wire short_window=active==6'd1;
    wire fault=|state[60:53];
    wire guide_mode=GUIDE_ENABLED && guide_state[0];
    wire [2:0] guide_reason=guide_state[7:5];
    wire [7:0] guide_target=guide_state[23:16];
    wire [7:0] guide_missed=guide_state[31:24],guide_wrong=guide_state[39:32];
    wire [7:0] guide_bpm=(guide_state[13:12]==0) ? 60 : (guide_state[13:12]==1) ? 90 : (guide_state[13:12]==2) ? 120 : 150;
    wire [7:0] preview_bpm=(preview==0) ? 60 : (preview==1) ? 90 : (preview==2) ? 120 : 150;
    wire [2:0] display_mode=(!valid || !state[61]) ? 3 : (state[62] ? 2 : (settings ? 1 :
        (guide_mode ? (guide_state[4] ? 6 : (guide_state[1] ? 4 : 5)) : 0)));
    wire [23:0] percent_product=volume*7'd100;
    wire [6:0] percent=percent_product[22:16];
    wire [3:0] preview_root=(preview>=12)?preview-8'd12:preview;
    `include "display_font_config.vh"
    `include "display_values.vh"
    (* syn_romstyle="block_rom" *) reg [15:0] font[0:FONT_DEPTH-1];
    (* syn_romstyle="block_rom" *) reg [7:0] text[0:1023];
    initial begin $readmemh("rtl/display_font.hex",font);$readmemh("rtl/display_text.hex",text);end
    wire [9:0] tx=x-64,ty=y-16;
    wire axis_text=!x[9] && y>=10'd448 && y<10'd464;
    wire [3:0] axis_row=wave_stride[1] ? 4'd15 : wave_stride[0] ? 4'd14 : 4'd13;
    wire in_text=(x>=64 && x<576 && y>=16 && y<224) || axis_text;
    wire [8:0] cell_now=axis_text ? {axis_row,x[8:4]} : {ty[7:4],tx[8:4]};
    // Reuse the wave RAM read port during vertical blank. The two reads of
    // each pair form a delayed XY plot of the same displayed PCM window.
    wire [8:0] xy_index={y[0],x[8:1]};
    wire xy_fetch=valid && !x[9] &&
        (y==10'd488 || (y==10'd489 && !short_window)) &&
        ((!short_window && !y[0]) || x[8:1]<8'd240);
    wire spectrum_fetch,spectrum_hit;
    hdmi_spectrum spectrum(clk,x,y,valid,wave,spectrum_fetch,spectrum_hit);
    assign wave_address=spectrum_fetch ? {1'b0,x[7:0]} :
        xy_fetch ? xy_index+(x[0] ? 9'd16 : 9'd0) :
        (short_window ? {1'b0,x[8:1]} : x[8:0]);
    wire xy_clear=y[9:3]==7'd60 && !x[9];
    wire xy_area=x[9] && y[9:7]==3'd2;
    wire xy_axis=x[6:1]==6'd32 || y[6:1]==6'd32;
    reg xy_first_d,xy_second_d;
    reg [5:0] xy_x;
    wire [5:0] xy_wave=wave[7:2]^6'b100000;
    wire [11:0] xy_address=xy_clear ? {y[2:0],x[8:0]} :
        (xy_second_d ? {~xy_wave,xy_x} : {y[6:1],x[6:1]});
    (* syn_ramstyle="block_ram" *) reg xy_bits[0:4095];
    reg xy_hit,xy_hit_d,xy_area_d,xy_area_2,xy_axis_d,xy_axis_2;
    reg spectrum_area_d,spectrum_area_2,spectrum_grid_d,spectrum_grid_2;
    always @(posedge clk)begin
        xy_first_d<=xy_fetch && !x[0];
        xy_second_d<=xy_fetch && x[0];
        if(xy_first_d)xy_x<=xy_wave;
        if(xy_clear || xy_second_d)xy_bits[xy_address]<=!xy_clear;
        else xy_hit<=xy_bits[xy_address];
        xy_hit_d<=xy_hit;
        xy_area_d<=xy_area;xy_area_2<=xy_area_d;
        xy_axis_d<=xy_axis;xy_axis_2<=xy_axis_d;
        spectrum_area_d<=!x[9] && y>=10'd320 && y<10'd448;
        spectrum_area_2<=spectrum_area_d;
        spectrum_grid_d<=x[6:0]==0 || y[4:0]==0 || y==10'd447;
        spectrum_grid_2<=spectrum_grid_d;
    end
    reg [7:0] text_char;reg [8:0] cell_d;
    reg [3:0] fx_d,fy_d,fx_2;
    reg text_d,text_2,wave_d,wave_2,key_d,key_2,title_d,title_2;
    reg [9:0] y_d,y_2;reg [7:0] sample_d;
    reg [15:0] font_row;reg [1:0] hs_pipe,vs_pipe,de_pipe;
    // Wave RAM's registered output corresponds to the previous x.
    always @(posedge clk)begin
        text_char<=text[{settings,cell_now}];cell_d<=cell_now;
        fx_d<=tx[3:0];fy_d<=ty[3:0];text_d<=in_text;
        y_d<=y;wave_d<=!x[9] && y>=240 && y<320;
        title_d<=in_text && ty[7:4]==0;
        key_d<=in_text && tx[8:4]>=3 && tx[8:4]<=17 && tx[4] &&
            ((ty[7:4]==6 && keys[(tx[8:4]-3)>>1]) ||
             (!settings && guide_mode && ty[7:4]==9 && guide_target[(tx[8:4]-3)>>1]));
        font_row<=font[{dynamic_glyph(cell_d,text_char),fy_d}];
        fx_2<=fx_d;text_2<=text_d;wave_2<=wave_d;y_2<=y_d;sample_d<=wave;
        title_2<=title_d;key_2<=key_d;
        hs_pipe<={hs_pipe[0],hs};vs_pipe<={vs_pipe[0],vs};de_pipe<={de_pipe[0],de};
        out_hs<=hs_pipe[1];out_vs<=vs_pipe[1];out_de<=de_pipe[1];
        red<=8'd10;green<=8'd18;blue<=8'd30;
        if(text_2 && title_2)begin red<=20;green<=48;blue<=80;end
        if(text_2 && font_row[15-fx_2])begin
            red<=key_2?8'd60:8'd225;green<=key_2?8'd240:8'd235;blue<=key_2?8'd150:8'd245;
            if(fault)begin red<=255;green<=100;blue<=100;end
        end
        if(wave_2)begin
            if(y_2==280 || y_2==240 || y_2==319)begin red<=35;green<=55;blue<=75;end
            if(valid && $signed({1'b0,y_2})==11'sd280-($signed(sample_d)>>>2))begin
                red<=40;green<=225;blue<=190;
            end
        end
        if(xy_area_2)begin
            red<=16;green<=27;blue<=43;
            if(xy_axis_2)begin red<=35;green<=55;blue<=75;end
            if(valid && xy_hit_d)begin red<=255;green<=176;blue<=80;end
        end
        if(spectrum_area_2)begin
            red<=14;green<=24;blue<=39;
            if(spectrum_grid_2)begin red<=35;green<=55;blue<=75;end
            if(spectrum_hit)begin red<=100;green<=170;blue<=255;end
        end
        if(rst)begin hs_pipe<=3;vs_pipe<=3;de_pipe<=0;out_hs<=1;out_vs<=1;out_de<=0;red<=0;green<=0;blue<=0;end
    end
endmodule
