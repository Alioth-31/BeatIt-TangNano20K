`timescale 1ns/1ps
// GW2AR output boundary. Simulation exposes pixel-rate encoded TMDS symbols;
// hardware uses the vendor PLL, clock divider and ten-bit DDR serializers.
module hdmi_output(input clk_27,input reset,input [7:0] red,green,blue,
    input hs,input vs,input de,output pixel_clk,output video_rst,
    output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n);
    wire serial_clk,locked;
`ifdef GOWIN_VIDEO
    rPLL #(.FCLKIN("27"),.IDIV_SEL(2),.FBDIV_SEL(13),.ODIV_SEL(8),
        .DEVICE("GW2AR-18C")) pll(
        .CLKIN(clk_27),.CLKOUT(serial_clk),.LOCK(locked),.CLKFB(1'b0),
        .RESET(reset),.RESET_P(1'b0),.FBDSEL(6'b0),.IDSEL(6'b0),.ODSEL(6'b0),
        .PSDA(4'b0),.DUTYDA(4'b0),.FDLY(4'b0));
    CLKDIV #(.DIV_MODE("5"),.GSREN("false")) divider(
        .HCLKIN(serial_clk),.CLKOUT(pixel_clk),.RESETN(locked && !reset),.CALIB(1'b1));
`else
    assign pixel_clk=clk_27;assign serial_clk=clk_27;assign locked=!reset;
`endif
    reg [3:0] reset_pipe;
    always @(posedge pixel_clk or posedge reset or negedge locked)
        if(reset || !locked)reset_pipe<=4'hf;else reset_pipe<={reset_pipe[2:0],1'b0};
    assign video_rst=reset_pipe[3];
    // UG289: initialize all four IO lane counters from configuration GSR.
    // Local RESET is disabled; runtime reset flushes control symbols once
    // the video clocks restart. Vendor-model wire tests cover
    // startup, pixel/divider reset and PLL loss/restart.
    wire [9:0] symbols[0:2];
    tmds_encoder enc_blue(pixel_clk,video_rst,de,{vs,hs},blue,symbols[0]);
    tmds_encoder enc_green(pixel_clk,video_rst,de,2'b0,green,symbols[1]);
    tmds_encoder enc_red(pixel_clk,video_rst,de,2'b0,red,symbols[2]);
`ifdef GOWIN_VIDEO
    wire [3:0] lanes;
    genvar n;
    generate for(n=0;n<4;n=n+1)begin: serializers
        wire [9:0] word_data;
        if(n==3)assign word_data=10'b0000011111;
        else assign word_data=symbols[n];
        OSER10 #(.GSREN("true"),.LSREN("false")) serializer(.Q(lanes[n]),.D0(word_data[0]),.D1(word_data[1]),
            .D2(word_data[2]),.D3(word_data[3]),.D4(word_data[4]),.D5(word_data[5]),
            .D6(word_data[6]),.D7(word_data[7]),.D8(word_data[8]),.D9(word_data[9]),
            .PCLK(pixel_clk),.FCLK(serial_clk),.RESET(1'b0));
    end endgenerate
    TLVDS_OBUF clock_buffer(.I(lanes[3]),.O(tmds_clk_p),.OB(tmds_clk_n));
    TLVDS_OBUF blue_buffer(.I(lanes[0]),.O(tmds_data_p[0]),.OB(tmds_data_n[0]));
    TLVDS_OBUF green_buffer(.I(lanes[1]),.O(tmds_data_p[1]),.OB(tmds_data_n[1]));
    TLVDS_OBUF red_buffer(.I(lanes[2]),.O(tmds_data_p[2]),.OB(tmds_data_n[2]));
`else
    assign tmds_clk_p=pixel_clk;assign tmds_clk_n=~pixel_clk;
    assign tmds_data_p={symbols[2][0],symbols[1][0],symbols[0][0]};
    assign tmds_data_n=~tmds_data_p;
`endif
endmodule
