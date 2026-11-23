`timescale 1ns/1ps
module tb_performance_entry_boundary;
    reg clk=0,rst=1,ce=0,settings=0;reg [7:0] keys=0;
    wire [7:0] play;wire active;wire [1:0] field;
    performance_surface #(.HOLD_SAMPLES(2)) dut(.clk(clk),.rst(rst),.sample_ce(ce),.physical_keys(keys),
        .settings_down(settings),.confirm_down(1'b0),.right_up(1'b0),.right_down(1'b0),
        .current_root(4'd0),.current_scale(2'd0),.current_octave(3'd4),.current_timbre(2'd0),
        .play_keys(play),.settings_active(active),.selected_field(field));
    always #5 clk=~clk;
    initial begin
        repeat(3)@(negedge clk);rst=0;settings=1;
        ce=1;@(negedge clk);ce=0;repeat(3)@(negedge clk);
        keys=8'h02;repeat(3)@(negedge clk);
        ce=1;@(negedge clk);ce=0;repeat(2)@(negedge clk);
        if(!active || play!=2 || field!=0)begin $display("FAIL key pressed before settings entry must retain perform ownership");$finish;end
        $display("PASS pre-entry key retains perform ownership");$finish;
    end
endmodule
