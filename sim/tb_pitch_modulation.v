`timescale 1ns/1ps
module tb_pitch_modulation;
`ifdef GOWIN_PRIMITIVES
    GSR GSR(1'b1);
`endif
    reg clk=0,rst=1,ce=0;reg signed [17:0] x=0;reg [16:0] y=0;
    wire [16:0] factor;wire busy,fault;
    integer i,phase=0,ramp,lfo_value,expect_now=65536,expect_next,difference,checks=0,old_factor;
    real semitones,depth;
    pitch_modulation dut(clk,rst,ce,x,y,factor,busy,fault);
    always #5 clk=~clk;
    initial begin
        repeat(5)@(negedge clk);rst=0;
        for(i=0;i<22000;i=i+1)begin
            // More than two full LFO periods, neutral centre, both end stops,
            // invalid input clamping and abrupt depth reversals.
            if(i<100)x=0;
            else if(i<9700)x=32768;
            else if(i<19400)x=-65536;
            else x=($random & 262143);
            y=i<100?0:(i<19400?65536:($random & 131071));
            ramp=(phase>>7)&32767;
            lfo_value=((phase>>22)&1)?32767-ramp:ramp;
            if(phase&8388608)lfo_value=-lfo_value;
            depth=y>65536?1.0:y/65536.0;
            semitones=(x>65536?2.0:(x < -65536 ? -2.0 : x/32768.0))+lfo_value/32768.0*depth*0.5;
            expect_next=$rtoi(65536.0*(2.0**(semitones/12.0)));
            @(negedge clk);ce=1;@(negedge clk);ce=0;
            difference=$signed({1'b0,factor})-expect_now;
            if(difference>5 || difference < -5 || fault)$fatal(1,"pitch ratio i=%0d got=%0d expected=%0d",i,factor,expect_now);
            old_factor=factor;
            repeat(24)begin @(negedge clk);if(factor!==old_factor)$fatal(1,"pitch changed outside frame");end
            if(busy)$fatal(1,"pitch missed frame");
            phase=(phase+1748)&16777215;expect_now=expect_next;checks=checks+1;
        end
        @(negedge clk);ce=1;@(negedge clk);ce=0;@(negedge clk);ce=1;@(negedge clk);ce=0;
        if(!fault || factor!==65536)$fatal(1,"pitch overrun not neutral");
        rst=1;repeat(4)@(negedge clk);rst=0;
        if(fault || factor!==65536)$fatal(1,"pitch reset");
        $display("PASS pitch_modulation float_oracle_frames=%0d",checks);$finish;
    end
endmodule

