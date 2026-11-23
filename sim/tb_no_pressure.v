`timescale 1ns/1ps
module tb_no_pressure;
 reg clk=0,rst=1;reg [9:0] tick=0;wire ce=tick==0;
 reg [63:0] request=0;reg commit=0;
 wire valid,fault;wire [111:0] query;wire [16:0] volume,a,b;
 expression_controls dut(clk,rst,ce,17'd6554,17'd65536,17'd65536,8'd0,1'b1,1'b1,,,
     request,commit,valid,query,volume,a,b,fault,,);
 always #5 clk=~clk;
 always @(posedge clk)tick<=tick+1'b1;
 initial begin
  repeat(5)@(negedge clk);rst=0;
  request={16'd1600,16'd0,16'd0,8'd1,8'd0};#1;
  if(valid)$fatal(1,"removed pressure channel must reject calibration");
  commit=1;@(negedge clk);commit=0;
  if(dut.enables[0] || dut.cal_mask[0])$fatal(1,"pressure channel must remain disabled");
  force dut.gain=17'd0;
  repeat(4*1024)@(negedge clk);
  if(volume!==17'd6554 || a!==17'd65536 || b!==17'd65536 || fault)
    $fatal(1,"pressure cannot affect master volume or pitch");
  release dut.gain;
  request={16'd1600,16'd800,16'd0,8'd1,8'd1};#1;
  if(!valid)$fatal(1,"X calibration still required");
  $display("PASS pressure removed, volume knob authoritative, joystick calibration retained");$finish;
 end
endmodule
