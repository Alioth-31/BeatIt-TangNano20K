`timescale 1ns/1ps
// Combined stress case: shared sine ROM for two DDS + live waveform fade.
module tb_dual_livewave;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0;
    reg [1:0] wave=0;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [3:0] active;
    integer frames,cycles;
    synth_core #(.NUM_VOICES(4),.DUAL_OSC_ENABLE(1),
                 .OSC2_WAVEFORM(0),.OSC2_SHARE_ROM(1),
                 .LIVE_WAVE_ENABLE(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),
        .preset(2'd0),.volume_target(17'd65536),.bend_target(17'd65536),
        .pcm(pcm),.pcm_valid(valid),.fault(fault),.busy(busy),
        .active(active),.waveform_select(wave),.source_midi(224'd0),.source_instance(512'd0));
    always #5 clk=~clk;
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;
            cycles=0;
            while(!valid && cycles<800) begin @(negedge clk);cycles=cycles+1;end
            if(!valid || fault) begin $display("FAIL dual livewave deadline/fault");$finish;end
            repeat(1024-cycles-2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;held=32'h0000000f;
        repeat(4) frame;
        wave=2'd3;frame;
        if(dut.wave_current!==2'd3 || dut.wave_fade!==6'd31) begin
            $display("FAIL waveform change not captured");$finish;
        end
        repeat(31) frame;
        if(dut.wave_fade!==0) begin $display("FAIL fade not completed");$finish;end
        wave=2'd1;repeat(33) frame;
        if(dut.wave_current!==2'd1 || dut.wave_fade!==0) begin
            $display("FAIL second wave change");$finish;
        end
        $display("PASS tb_dual_livewave");$finish;
    end
endmodule
