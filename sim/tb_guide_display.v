`timescale 1ns/1ps
module tb_guide_display;
    reg clk=0,rst=1;wire[9:0]x,y;wire hs,vs,de,frame;reg[63:0]state=0,guide=0;
    wire[8:0]address;wire[7:0]r,g,b;wire ohs,ovs,ode;integer f,pixels=0;
    video_timing timing(clk,rst,x,y,hs,vs,de,frame);
    hdmi_status #(.GUIDE_ENABLED(1)) dut(clk,rst,x,y,hs,vs,de,state,1'b1,8'd0,address,r,g,b,ohs,ovs,ode,guide,2'd0);
    always #5 clk=~clk;
    task draw;input[255:0]path;begin
        wait(frame);@(negedge clk);pixels=0;f=$fopen(path,"wb");$fwrite(f,"P6\n640 480\n255\n");
        while(pixels<640*480)begin @(negedge clk);if(ode)begin
            if((^r)===1'bx||(^g)===1'bx||(^b)===1'bx)$fatal(1,"unknown guide pixel");
            $fwrite(f,"%c%c%c",r,g,b);pixels=pixels+1;end end
        $fclose(f);
    end endtask
    initial begin
        state[61]=1;state[19:17]=4;state[38:22]=6554;guide[0]=1;guide[2]=1;guide[3]=1;guide[15]=1;
        guide[14]=1;guide[13:12]=2;guide[23:16]=8'h15;guide[47:40]=8'h80;
        repeat(4)@(negedge clk);rst=0;#1;
        if(dut.display_mode!=5)$fatal(1,"guide pause must not display free performance");
        draw("build/guide/paused.ppm");
        state[0]=1;state[63]=1;state[2:1]=1;state[10:3]=3;#1;
        if(dut.field!=5||dut.display_mode!=1)$fatal(1,"K6 settings field lost high bit");
        draw("build/guide/settings.ppm");
        state[0]=0;guide[1]=1;#1;if(dut.display_mode!=4)$fatal(1,"guide run display");
        guide[1]=0;guide[4]=1;#1;if(dut.display_mode!=6)$fatal(1,"guide completion display");
        $display("PASS guide pause/run/done and six-field settings rendered");$finish;
    end
endmodule
