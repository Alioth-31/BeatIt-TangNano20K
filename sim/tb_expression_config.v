`timescale 1ns/1ps
module tb_expression_config;
    reg clk=0,rst=1,commit=0;reg [63:0] request=0;
    wire valid,cal_commit,invert;wire [95:0] calibration;wire [2:0] mask,enables;
    wire [111:0] reply;integer checks=0;reg [95:0] saved;
    expression_config dut(clk,rst,request,commit,valid,cal_commit,calibration,mask,invert,enables,
        48'h123fff456789,4'b0111,1'b1,3'b010,1'b1,8'h55,2'd2,1'b0,reply);
    always #5 clk=~clk;
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",msg);$finish;end end endtask
    task set_request;input[7:0] channel,flags;input signed[15:0] low,centre,high;
        begin @(negedge clk);request={high,centre,low,flags,channel};#1;end
    endtask
    task apply;
        begin commit=1;@(negedge clk);commit=0;#1;check(cal_commit,"accepted calibration pulse");@(negedge clk);#1;check(!cal_commit,"one-cycle calibration commit");end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;#1;check(mask==0&&enables==0,"reset must not calibrate or enable");
        set_request(0,1,100,0,1600);check(valid,"pressure range accepted");apply();
        check(calibration[23:0]=={12'd1600,12'd100}&&mask==1&&enables==1,"pressure stored without automatic axes");
        set_request(1,3,-100,700,1600);check(valid,"signed asymmetric axis range");apply();
        check(calibration[59:24]=={12'd1600,12'd700,12'hf9c}&&mask==3&&enables==3&&invert,"X calibration and inversion");
        check(reply[7:0]==1&&reply[15:8]==8'h3f&&reply[31:16]==16'h0456&&reply[47:32]==16'hff9c&&reply[63:48]==700&&reply[79:64]==1600,
            "query reports signed calibration, actual ADC, availability and activity");
        set_request(2,1,-1800,-1000,0);check(valid,"negative Y calibration");apply();
        check(reply[31:16]==16'hffff,"signed ADC readback");saved=calibration;
        set_request(3,1,0,0,500);check(!valid,"invalid channel");commit=1;@(negedge clk);commit=0;#1;check(calibration==saved&&!cal_commit,"invalid write cannot mutate");
        set_request(0,1,0,1,500);check(!valid,"pressure centre reserved zero");
        set_request(0,3,0,0,500);check(!valid,"pressure has no inversion");
        set_request(1,4,0,500,1000);check(!valid,"reserved flag rejected");
        set_request(1,1,-2049,0,2047);check(!valid,"12-bit signed underflow rejected");
        set_request(1,1,-2048,0,2048);check(!valid,"12-bit signed overflow rejected");
        set_request(1,1,0,79,1600);check(!valid,"deadband requires sufficient negative range");
        set_request(1,1,0,1521,1600);check(!valid,"deadband requires sufficient positive range");
        set_request(0,1,100,0,163);check(!valid,"minimum pressure span");
        set_request(1,2,-100,700,1600);check(valid,"explicit disable retains calibration");apply();
        check(enables==5&&mask==7&&invert,"disabling X leaves pressure and Y unchanged");
        $display("PASS expression configuration %0d checks",checks);$finish;
    end
endmodule
