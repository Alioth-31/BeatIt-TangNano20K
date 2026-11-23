`timescale 1ns/1ps
module tb_performance_volume;
    reg clk=0,rst=1,ce=0;
    wire [16:0] performance_volume,legacy_volume;
    synth_app_bridge #(.PERFORMANCE_ENABLED(1)) performance(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(1'b1),.physical_keys(8'b0),.raw_keys(8'hff),
        .performance_play_keys(8'b0),.vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),.active_voice_count(6'b0),.audio_fault(1'b0),.volume(performance_volume),
        .ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    synth_app_bridge #(.PERFORMANCE_ENABLED(0)) legacy(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(1'b1),.physical_keys(8'b0),.raw_keys(8'hff),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'b0),.audio_fault(1'b0),.volume(legacy_volume),
        .performance_play_keys(8'b0),.ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    initial begin
        repeat(4)@(negedge clk);rst=0;
        if(performance_volume!==39321 || legacy_volume!==16384 ||
            performance.last_event_volume!==39321 || legacy.last_event_volume!==16384) begin
            $display("FAIL profile volume reset defaults");$finish;
        end
        performance.cmd_type[0]=2;performance.cmd_length[0]=0;performance.cmd_payload[0]=0;
        performance.cmd_seq[0]=1;performance.cmd_count=1;performance.cmd_write=1;
        legacy.cmd_type[0]=2;legacy.cmd_length[0]=0;legacy.cmd_payload[0]=0;
        legacy.cmd_seq[0]=1;legacy.cmd_count=1;legacy.cmd_write=1;
        @(negedge clk);ce=1;@(negedge clk);ce=0;@(negedge clk);
        if(performance.resp_type[0]!==8'h82 || performance.resp_payload[0][95:80]!==39321 ||
            legacy.resp_type[0]!==8'h82 || legacy.resp_payload[0][95:80]!==16384) begin
            $display("FAIL profile volume GET_STATUS readback");$finish;
        end
        $display("PASS performance reset/readback defaults to 10 percent; legacy profile unchanged");$finish;
    end
endmodule
