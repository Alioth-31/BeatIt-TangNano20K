`timescale 1ns/1ps
// Top-level compilation via run_tests.py uses -Ptb_dual_osc_core.N=4/8/16/32.
// This is a dual-DDS correctness/deadline test, NOT a placement/timing result.
module tb_dual_osc_core;
    parameter N=4;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0;
    wire signed [15:0] pcm;
    wire pcm_valid,fault,busy;
    wire [N-1:0] active;
    integer i,cycles,active_count;
    reg [31:0] phase_a_prior,phase_b_prior;
    synth_core #(.NUM_VOICES(N),.DUAL_OSC_ENABLE(1),
                 .OSC2_WAVEFORM(0),.OSC2_DETUNE_SHIFT(7),
                 .OSC2_SHARE_ROM(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .preset(2'd0),.volume_target(17'd65536),
        .bend_target(17'd65536),.pcm(pcm),.pcm_valid(pcm_valid),
        .fault(fault),.busy(busy),.active(active),.waveform_select(2'd0),.source_midi(224'd0),.source_instance(512'd0));
    always #5 clk=~clk;
    task frame;
        begin
            @(negedge clk);ce=1;
            @(negedge clk);ce=0;
            cycles=0;
            while(!pcm_valid && cycles<1000) begin
                @(negedge clk);cycles=cycles+1;
            end
            if(!pcm_valid || fault || cycles>=1000) begin
                $display("FAIL dual deadline N=%0d cycles=%0d fault=%b",N,cycles,fault);$finish;
            end
            // Model a real 1024-clock sample interval, including idle time.
            repeat(1024-cycles-2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        held=(N==32)?32'hffffffff:((32'h1<<N)-1);
        // Fades/ADSR take hundreds of frames; state must advance immediately.
        repeat(4) frame;
        active_count=0;
        for(i=0;i<N;i=i+1) begin
            if(active[i]) active_count=active_count+1;
            if(dut.increment_b[i]<=dut.increment[i] || dut.increment[i]==0) begin
                $display("FAIL independent increment N=%0d voice=%0d A=%d B=%d",N,i,dut.increment[i],dut.increment_b[i]);$finish;
            end
            if(dut.phase[i]===dut.phase_b[i]) begin
                $display("FAIL phase B not independent N=%0d voice=%0d",N,i);$finish;
            end
        end
        if(active_count!=N) begin
            $display("FAIL active voice count N=%0d got=%0d",N,active_count);$finish;
        end
        phase_a_prior=dut.phase[0];phase_b_prior=dut.phase_b[0];
        frame;
        if(dut.phase[0]===phase_a_prior || dut.phase_b[0]===phase_b_prior) begin
            $display("FAIL phase accumulation stalled N=%0d",N);$finish;
        end
        held=0; repeat(3) frame;
        if(fault) begin $display("FAIL dual fault after release N=%0d",N);$finish;end
        $display("PASS tb_dual_osc_core N=%0d",N);$finish;
    end
endmodule
