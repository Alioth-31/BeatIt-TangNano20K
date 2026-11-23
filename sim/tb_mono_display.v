`timescale 1ns/1ps
module tb_mono_display;
    reg clk=0,rst=1;wire[9:0]x,y;wire hs,vs,de,frame;reg[63:0]state=0;
    wire[8:0]address;wire[7:0]r,g,b;wire ohs,ovs,ode;integer f,pixels=0;
    video_timing timing(clk,rst,x,y,hs,vs,de,frame);
    hdmi_status #(.GUIDE_ENABLED(1),.MONO_ENABLED(1)) dut(clk,rst,x,y,hs,vs,de,state,1'b1,8'd0,address,r,g,b,ohs,ovs,ode,64'd0,2'd0);
    always #5 clk=~clk;
    initial begin
        state[61]=1;state[19:17]=4;state[38:22]=6554;state[10]=1;state[9:3]=4;state[0]=1;
        repeat(4)@(negedge clk);rst=0;#1;
        if(dut.timbre!=4 || dut.preview!=4)$fatal(1,"mono timbre/preview packing");
        // Glyph IDs from the font manifest: 单 簧 管.
        if(dut.dynamic_glyph(271,0)!=45 || dut.dynamic_glyph(272,0)!=93 ||
           dut.dynamic_glyph(273,0)!=92 || dut.dynamic_glyph(274,0)!=0)
            $fatal(1,"mono preview must label the monophonic patch");
        wait(frame);@(negedge clk);f=$fopen("build/mono/settings.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");
        while(pixels<640*480)begin @(negedge clk);if(ode)begin
            if((^r)===1'bx||(^g)===1'bx||(^b)===1'bx)$fatal(1,"unknown mono pixel");
            $fwrite(f,"%c%c%c",r,g,b);pixels=pixels+1;end end
        $fclose(f);$display("PASS mono current/preview label and packed state rendered");$finish;
    end
endmodule
