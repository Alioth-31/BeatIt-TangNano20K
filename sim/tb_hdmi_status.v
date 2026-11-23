`timescale 1ns/1ps
module tb_hdmi_status;
    reg clk=0,rst=1;wire [9:0] x,y;wire hs,vs,de,frame;
    wire [8:0] address;wire [7:0] r,g,b;wire ohs,ovs,ode;
    reg [7:0] wave=0;reg [63:0] state=0;integer pixels=0,f,wave_pixels=0,expected_sample,expected_y;
    reg [1:0] stride=0;
    reg xy_seen=0;
    reg spectrum_seen=0;
    reg [9:0] px0,px1,px2,py0,py1,py2;reg [2:0] de_expected;
    video_timing timing(clk,rst,x,y,hs,vs,de,frame);
    hdmi_status dut(clk,rst,x,y,hs,vs,de,state,1'b1,wave,address,r,g,b,ohs,ovs,ode,64'd0,stride);
    always #5 clk=~clk;
    always @(posedge clk) wave<=address[7:0];
    always @(posedge clk)begin px0<=x;px1<=px0;px2<=px1;py0<=y;py1<=py0;py2<=py1;de_expected<={de_expected[1:0],de};end
    always @(negedge clk)if(!rst && pixels>0)begin
        if(ode!==de_expected[2])$fatal(1,"pixel/sync latency mismatch");
        if(ode && py2>=224 && py2<240 && r==225 && g==235 && b==245)
            $fatal(1,"spectrum scale repeated above the plots");
        if(ode && r==40 && g==225 && b==190)begin
            expected_sample=(state[52:47]==1) ? px2/2 : px2%256;
            if(expected_sample>=128)expected_sample=expected_sample-256;
            expected_y=280-(expected_sample>>>2);
            if(px2>=512 || py2!=expected_y)$fatal(1,"wave RAM/pixel coordinate misalignment x=%d y=%d expected=%d",px2,py2,expected_y);
            wave_pixels=wave_pixels+1;
        end
        // The first PCM pair (0,16) maps to XY cell (32,27).
        if(ode && px2==576 && py2==310 && r==255 && g==176 && b==80)xy_seen=1;
        if(ode && px2==7 && py2==445 && r==100 && g==170 && b==255)spectrum_seen=1;
    end
    initial begin
        state[61]=1;state[19:17]=4;state[38:22]=6554;state[52:47]=12;state[46:39]=8'h55;
        repeat(3)@(negedge clk);rst=0;
        // Skip the initial pipeline; dump complete next frames from actual RTL.
        wait(frame);@(negedge clk);
        f=$fopen("build/hdmi/perform.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");
        while(pixels<640*480)begin @(negedge clk);if(ode)begin $fwrite(f,"%c%c%c",r,g,b);pixels=pixels+1;end end
        $fclose(f);if(wave_pixels!=512)$fatal(1,"wave pixel count %d",wave_pixels);
        if(!xy_seen)$fatal(1,"PCM pair was not plotted in the XY panel");
        if(!spectrum_seen)$fatal(1,"wave RAM did not drive the first spectral bar");
        if(dut.display_mode!=0 || dut.percent!=10)$fatal(1,"actual mode/volume");
        state[38:22]=65536;#1;if(dut.percent!=100)$fatal(1,"100 percent endpoint");state[38:22]=6554;
        state[0]=1;state[2:1]=1;state[10:3]=14;state[14:11]=2;state[16:15]=1;state[21:20]=3;
        #1;if(dut.display_mode!=1 || dut.preview_root!=2)$fatal(1,"settings preview decode");
        wait(frame);@(negedge clk);pixels=0;wave_pixels=0;state[52:47]=1;stride=2;
        #1;
        if(dut.dynamic_glyph(9'd393,8'd0)!==dut.digit(1) ||
           dut.dynamic_glyph(9'd394,8'd0)!==dut.digit(2))$fatal(1,"12 kHz plot label");
        f=$fopen("build/hdmi/settings.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");
        while(pixels<640*480)begin @(negedge clk);if(ode)begin
            if((^r)===1'bx || (^g)===1'bx || (^b)===1'bx)$fatal(1,"unknown output pixel");
            $fwrite(f,"%c%c%c",r,g,b);pixels=pixels+1;end end
        $fclose(f);if(wave_pixels!=512)$fatal(1,"short waveform did not fill the display");
        $display("PASS actual RTL rendered perform/settings frames");$finish;
    end
endmodule
