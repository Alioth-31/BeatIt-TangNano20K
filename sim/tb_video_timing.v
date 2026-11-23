`timescale 1ns/1ps
module tb_video_timing;
    reg clk=0,rst=1; wire [9:0] x,y; wire hs,vs,de,frame;
    integer k,pixels=0,hs_low=0,vs_low=0,starts=0;
    video_timing dut(clk,rst,x,y,hs,vs,de,frame);
    always #5 clk=~clk;
    initial begin
        repeat(3) @(negedge clk);rst=0;
        for(k=0;k<800*525;k=k+1) begin
            if(x!==k%800 || y!==k/800) $fatal(1,"coordinate sequence");
            if(de) pixels=pixels+1;
            if(!hs) hs_low=hs_low+1;
            if(!vs) vs_low=vs_low+1;
            if(frame) begin starts=starts+1;if(x!=0 || y!=480)$fatal(1,"frame boundary");end
            @(negedge clk);
        end
        if(pixels!=640*480 || hs_low!=96*525 || vs_low!=2*800 || starts!=1 || x!=0 || y!=0)
            $fatal(1,"frame geometry %d %d %d %d",pixels,hs_low,vs_low,starts);
        rst=1;@(negedge clk);if(x!=0 || y!=0)$fatal(1,"reset");
        $display("PASS 640x480 frame geometry and sync");$finish;
    end
endmodule
