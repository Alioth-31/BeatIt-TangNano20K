`timescale 1ns/1ps
module tb_factory_expression;
 parameter [95:0] EXPECTED=0;
 reg clk=0,rst=1,commit=0;reg[63:0]request=0;
 reg [9:0] count=0;wire ce=count==0;
 reg [1:0] update_channel=1;
 reg [47:0] samples={12'd0,12'd810,12'd800,12'd0};
 wire [16:0] mapped_gain,mapped_depth;wire signed[17:0] mapped_position;
 wire [2:0] mapped_calibrated,mapped_active;wire mapped_fault;
 wire valid;wire[111:0]query;
 expression_controls dut(clk,rst,1'b0,17'd6554,17'd65536,17'd65536,8'd0,1'b1,1'b1,,,
    request,commit,valid,query,,,,,);
 always #5 clk=~clk;
 always @(posedge clk)begin
  if(rst)begin count<=0;update_channel<=1;end
  else begin count<=count+1'b1;update_channel<=update_channel==1?2:1;end
 end
 expression_mapper first_frame_mapper(clk,rst,ce,samples,4'b0110,1'b1,1'b1,update_channel,
  dut.cal_commit,dut.calibration,dut.cal_mask,dut.invert_x,dut.enables,
  mapped_gain,mapped_position,mapped_depth,mapped_calibrated,mapped_active,,mapped_fault);
 initial begin
  repeat(5)@(negedge clk);rst=0;repeat(5)@(negedge clk);
  if(dut.calibration!==EXPECTED || dut.cal_mask!==6 || dut.enables!==6 || dut.mapper.calibrated!==6)
    $fatal(1,"factory calibration must reach mapper after cold reset");
  request={16'd1700,16'd900,16'd50,8'd1,8'd1};commit=1;@(negedge clk);commit=0;
  repeat(3)@(negedge clk);
  if(dut.calibration===EXPECTED)$fatal(1,"runtime calibration must remain possible");
  rst=1;repeat(3)@(negedge clk);rst=0;repeat(5)@(negedge clk);
  if(dut.calibration!==EXPECTED || dut.mapper.cfg!==EXPECTED || dut.enables!==6)
    $fatal(1,"reset must restore embedded calibration without host");
  repeat(3*1024)@(negedge clk);
  if(mapped_calibrated!==6 || mapped_active!==6 || mapped_gain!==65536 || mapped_position!==0 || mapped_depth!==0 || mapped_fault)
    $fatal(1,"factory cold boot must map fresh centered ADC samples without a host SET");
  samples={12'd0,12'd810,12'd1500,12'd0};repeat(3*1024)@(negedge clk);
  if(mapped_position!==-18'sd65536 || mapped_gain!==65536 || mapped_fault)
    $fatal(1,"factory inverted X endpoint must reach full bend without pressure gain");
  request={16'd1600,16'd0,16'd0,8'd1,8'd0};#1;
  if(valid || dut.enables[0])$fatal(1,"factory image must not restore removed pressure control");
  $display("PASS factory XY calibration cold boot, runtime update, reset restore and pressure disabled");$finish;
 end
endmodule
