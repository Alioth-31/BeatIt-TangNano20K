`timescale 1ns/1ps
// Runtime waveform selection: phase continuity, deferred switch, bounded
// 32-frame crossfade, deadline and reset. Run with -g2001.
module tb_live_wave;
    parameter N=4;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0;
    reg [1:0] wave=0;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [N-1:0] active;
    integer cycles,frames;
    reg [31:0] phase_before;
    synth_core #(.NUM_VOICES(N),.LIVE_WAVE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .preset(2'd0),.volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(pcm),.pcm_valid(valid),.fault(fault),.busy(busy),
        .active(active),.waveform_select(wave),.source_midi(224'd0),.source_instance(512'd0));
    always #5 clk=~clk;
    task sample_frame;
        begin
            @(negedge clk);ce=1;
            @(negedge clk);ce=0;
            cycles=0;
            while(!valid && cycles<800) begin
                @(negedge clk);cycles=cycles+1;
            end
            if(!valid || fault || cycles>=800) begin
                $display("FAIL frame deadline N=%0d, cycles=%0d",N,cycles);
                $finish;
            end
            frames=frames+1;
            repeat(2) @(negedge clk);
        end
    endtask
    integer i;
    initial begin
        frames=0;
        repeat(5) @(negedge clk);rst=0;
        held[5]=1;
        for(i=0;i<320;i=i+1) sample_frame;
        if(active==0 || dut.wave_current!==2'd0 || dut.wave_fade!==0)
        begin $display("FAIL initial state");$finish;end
        phase_before=dut.phase[0];
        wave=1;
        sample_frame;
        if(dut.wave_current!==1 || dut.wave_previous!==0 || dut.wave_fade!==31)
        begin $display("FAIL start crossfade");$finish;end
        if(dut.phase[0]-phase_before!==dut.increment[0])
        begin $display("FAIL DDS phase discontinuity");$finish;end
        // A rapid control change waits until the current transition is done.
        wave=2;
        for(i=0;i<30;i=i+1) begin
            sample_frame;
            if(dut.wave_current!==1) begin
                $display("FAIL switch interrupted previous fade");$finish;
            end
        end
        sample_frame;
        if(dut.wave_fade!==0 || dut.wave_current!==1)
        begin $display("FAIL fade count");$finish;end
        sample_frame;
        if(dut.wave_current!==2 || dut.wave_previous!==1 || dut.wave_fade!==31)
        begin $display("FAIL deferred switch");$finish;end
        for(i=0;i<32;i=i+1) sample_frame;
        if(dut.wave_fade!==0 || dut.wave_current!==2)
        begin $display("FAIL second fade");$finish;end
        wave=3;sample_frame;
        if(dut.wave_current!==3 || dut.wave_fade!==31)
        begin $display("FAIL triangle transition");$finish;end
        rst=1;repeat(4) @(negedge clk);
        if(dut.wave_current!==0 || dut.wave_fade!==0 || fault)
        begin $display("FAIL reset state");$finish;end
        $display("PASS live wave transitions N=%0d, frames=%0d",N,frames);
        $finish;
    end
    initial begin #200000000; $display("FAIL timeout");$finish;end
endmodule
