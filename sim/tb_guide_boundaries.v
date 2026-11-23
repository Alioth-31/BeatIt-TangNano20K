`timescale 1ns/1ps
module tb_guide_boundaries;
    reg clk=0,rst=1,ce=0,toggle=0,settings=0,led_ok=1;reg [1:0] tempo=0;
    localparam [55:0] MAP={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    reg [55:0] mapped=MAP;wire [7:0] leds,target;wire running,ready,compatible;wire [3:0] step;
    integer checks=0,t,p,n,flashes,darks;
    guide_engine #(.SAMPLE_HZ(240)) dut(clk,rst,ce,1'b1,settings,toggle,1'b0,1'b0,tempo,
        mapped,MAP,8'd0,1'b0,led_ok,3'd0,leds,target,running,ready,compatible,,step,,,,1'b0,1'b0);
    always #5 clk=~clk;
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide boundary %0s",msg);$finish;end end endtask
    task frame;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(3)@(negedge clk);end endtask
    task tap;begin @(negedge clk);toggle=1;@(negedge clk);toggle=0;frame();end endtask
    task restart;
        begin rst=1;settings=0;led_ok=1;mapped=MAP;toggle=0;repeat(4)@(negedge clk);rst=0;wait(ready);tap();end
    endtask
    initial begin
        for(t=0;t<4;t=t+1)begin
            tempo=t;case(t)0:p=60;1:p=40;2:p=30;3:p=24;endcase
            restart();repeat(4*p-1)frame();check(step==0&&running,"tempo full duration minus one");
            frame();check(step==1,"tempo exact event duration");
        end
        tempo=2;p=30;
        restart();repeat(119)frame();tap();check(!running&&step==0,"pause beats event-end transition");
        repeat(10)frame();tap();check(running&&step==0,"resume does not eat a sample");frame();check(step==1,"paused final sample resumes exactly");
        restart();repeat(119)frame();settings=1;frame();check(!running&&step==0,"settings beats event-end transition");settings=0;frame();check(!running,"settings exit stays paused");
        restart();repeat(119)frame();led_ok=0;frame();check(!running&&step==0,"LED loss beats event-end transition");led_ok=1;frame();check(!running,"LED return stays paused");
        restart();repeat(119)frame();mapped[55:49]=73;frame();wait(ready);check(!running&&!compatible&&step==0,"mapping change aborts old event at boundary");
        restart();repeat(20)frame();@(negedge clk);tempo=1;toggle=1;@(negedge clk);toggle=0;frame();
        check(!running&&step==0,"tempo change plus toggle cannot auto-resume");
        // Full-gate C remains on while the following D flashes in preview.
        tempo=2;restart();repeat(210)frame();flashes=0;darks=0;
        for(n=0;n<29;n=n+1)begin
            check(step==1&&target==1&&leds[0],"preview never erases sustained current note");
            if(leds[1])flashes=flashes+1;else darks=darks+1;frame();
        end
        check(flashes>0&&darks>0,"different next note actually flashes");
        settings=1;frame();check(leds==1&&!running,"settings replaces preview exclusively");
        $display("PASS guide boundaries %0d checks",checks);$finish;
    end
endmodule
