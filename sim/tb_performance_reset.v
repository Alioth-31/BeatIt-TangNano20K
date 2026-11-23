`timescale 1ns/1ps
module tb_performance_reset;
    reg clk=0,rst=1;wire [1:0] wave,timbre;
    synth_app_bridge #(.PERFORMANCE_ENABLED(1),.WAVE_RESET_MODE(3),.WAVE_CONTROL_ENABLED(1),
        .TONE_CONTROL_ENABLED(1),.INDEPENDENT_CONTROL_ENABLED(1)) dut(.clk(clk),.rst(rst),.sample_ce(1'b0),.uart_rx(1'b1),
        .physical_keys(8'd0),.raw_keys(8'hff),.vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),.active_voice_count(6'd0),.audio_fault(1'b0),.performance_play_keys(8'd0),
        .ui_commit_valid(1'b0),.ui_commit_field(2'd0),.ui_commit_value(8'd0),.ui_settings_active(1'b0),
        .ui_selected_field(2'd0),.ui_preview_value(8'd0),.waveform_mode(wave),.performance_timbre(timbre));
    always #5 clk=~clk;
    initial begin
        repeat(3)@(negedge clk);rst=0;repeat(3)@(negedge clk);
        if(wave!=3 || timbre!=3)begin $display("FAIL nondefault reset waveform must report custom timbre");$finish;end
        $display("PASS custom initial waveform matches reported timbre");$finish;
    end
endmodule
