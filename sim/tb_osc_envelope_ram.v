`timescale 1ns/1ps
// The existing tb_rom strategy is reused for writable packed ADSR state.
module tb_osc_envelope_ram;
  parameter W=72,A=5;
  reg clk=0,we=0;
  reg [A-1:0] read_addr=0,write_addr=0;
  reg [W-1:0] data=0;
  wire [W-1:0] q;
  integer i,bit_index,checks=0;
  reg [W-1:0] expected [0:(1<<A)-1];
  osc_envelope_ram #(.WIDTH(W),.ADDR_W(A),.DEPTH(1<<A)) dut(clk,read_addr,q,we,write_addr,data);
  always #5 clk=~clk;
  function [W-1:0] value;
    input integer n;
    begin value=72'h91fedcba9876543210 ^ (72'h102030405060708090*n);end
  endfunction
  initial begin
    for(i=0;i<(1<<A);i=i+1)begin
      @(negedge clk);we=1;write_addr=i;data=value(i);
    end
    @(negedge clk);we=0;
    for(i=0;i<(1<<A);i=i+1)begin
      @(negedge clk);read_addr=i;
      @(negedge clk);
      if(q!==value(i))begin $display("FAIL packed RAM addr=%0d got=%h expected=%h",i,q,value(i));$finish;end
      expected[i]=value(i);checks=checks+1;
    end
    // Cover every bit, especially the former 8-bit byte and new 9-bit lane
    // boundaries. Simultaneous read/write targets different addresses.
    for(bit_index=0;bit_index<W;bit_index=bit_index+1)begin
      @(negedge clk);we=1;write_addr=bit_index%((1<<A)-1);read_addr=(1<<A)-1;
      data={{(W-1){1'b0}},1'b1}<<bit_index;expected[write_addr]=data;
      @(negedge clk);we=0;
      if(q!==expected[(1<<A)-1])begin $display("FAIL independent-port read changed");$finish;end
      read_addr=write_addr;@(negedge clk);
      if(q!==expected[write_addr])begin $display("FAIL packed lane bit=%0d got=%h expected=%h",bit_index,q,expected[write_addr]);$finish;end
      checks=checks+1;
    end
    // A data/address change without a clock cannot change synchronous q.
    @(negedge clk);read_addr=(1<<A)-1;#1;
    if(q!==expected[write_addr])begin $display("FAIL RAM output is asynchronous");$finish;end
    @(negedge clk);
    if(q!==expected[(1<<A)-1])begin $display("FAIL RAM final-address/padding");$finish;end
    $display("PASS packed RAM width=%0d addresses=%0d checks=%0d",W,1<<A,checks);$finish;
  end
endmodule
