`timescale 1ns/1ps
module control_surface #(
    parameter DEBOUNCE_CYCLES=98304, parameter ENCODER_FILTER_CYCLES=1024,
    parameter ENCODER_EDGES=4
)(input clk, input rst, input [7:0] keys_n,
  input [1:0] volume_ab, input volume_sw_n, input [1:0] bend_ab, input bend_sw_n,
  input test_button, output [7:0] held,
  output reg [16:0] volume, output [16:0] bend,
  output reg [1:0] preset, output reg [1:0] test_mode,
  output vol_up, output vol_down, output bend_up, output bend_down,
  output bend_reset, output preset_next,
  output volume_button_down, output bend_button_down);
    wire [7:0] keys_stable;
    wire vol_push,bend_push,test_push;
    reg previous_vol,previous_bend,previous_test;
    reg [6:0] bend_index;
    `include "bend_table.vh"
    assign held=~keys_stable;
    assign bend=bend_factor(bend_index);
    assign bend_reset=!rst && previous_bend && !bend_push;
    assign preset_next=!rst && previous_vol && !vol_push;
    // Export the debounced held levels separately from legacy press events.
    assign volume_button_down=!rst && !vol_push;
    assign bend_button_down=!rst && !bend_push;
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: keys
        debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) db(clk,rst,keys_n[g],keys_stable[g]);
    end endgenerate
    debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) vp(clk,rst,volume_sw_n,vol_push);
    debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) bp(clk,rst,bend_sw_n,bend_push);
    debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES),.INITIAL_LEVEL(0)) tp(clk,rst,test_button,test_push);
    quadrature #(.FILTER_CYCLES(ENCODER_FILTER_CYCLES),.EDGES_PER_STEP(ENCODER_EDGES)) vq(clk,rst,volume_ab,vol_up,vol_down);
    quadrature #(.FILTER_CYCLES(ENCODER_FILTER_CYCLES),.EDGES_PER_STEP(ENCODER_EDGES)) bq(clk,rst,bend_ab,bend_up,bend_down);
    always @(posedge clk) begin
        if(rst) begin
            volume<=16384; bend_index<=32; preset<=0; test_mode<=0;
            previous_vol<=1; previous_bend<=1; previous_test<=0;
        end else begin
            previous_vol<=vol_push; previous_bend<=bend_push; previous_test<=test_push;
            if(vol_up) volume<=(volume>=63488)?65536:volume+17'd2048;
            else if(vol_down) volume<=(volume<=2048)?0:volume-17'd2048;
            if(previous_vol && !vol_push) preset<=(preset==2)?0:preset+1'b1;
            if(previous_bend && !bend_push) bend_index<=32;
            else if(bend_up && bend_index<64) bend_index<=bend_index+1'b1;
            else if(bend_down && bend_index>0) bend_index<=bend_index-1'b1;
            if(!previous_test && test_push) test_mode<=(test_mode==2)?0:test_mode+1'b1;
        end
    end
endmodule
