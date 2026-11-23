`timescale 1ns/1ps
module timer_unsigned_bridge_check #(
    parameter CLOCK_HZ=50,parameter WATCHDOG=32'h80000001,parameter PARSER=0
)(input clk,input rst,output reg done=0);
    reg ce=0;
    synth_app_bridge #(.CLOCK_HZ(CLOCK_HZ),.BAUD(10),.WATCHDOG_SAMPLES(WATCHDOG)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(1'b1),.raw_keys(8'hff),.physical_keys(8'b0),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'b0),.audio_fault(1'b0),.performance_play_keys(8'b0),.ui_commit_valid(1'b0),
        .ui_commit_field(2'b0),.ui_commit_value(8'b0),.ui_settings_active(1'b0),
        .ui_selected_field(2'b0),.ui_preview_value(8'b0));
    task tick;begin @(negedge clk);#1;end endtask
    initial begin
        wait(!rst);tick;
        if(PARSER) begin
            if(dut.PARSER_TIMER_WIDTH!=32) begin $display("FAIL unsigned parser timer width");$finish;end
            dut.parser_state=2;dut.parser_timer=32'h7fffffff;tick;
            if(dut.parser_timer!==32'h80000000 || dut.parser_state!==2) begin $display("FAIL unsigned parser high bit");$finish;end
            tick;
            if(dut.parser_state!==0 || dut.parser_timer!==0) begin $display("FAIL unsigned parser timeout");$finish;end
        end else begin
            if(dut.WATCHDOG_WIDTH!=32) begin $display("FAIL unsigned watchdog timer width");$finish;end
            dut.remote_mask=1;dut.watchdog=WATCHDOG-2;ce=1;tick;
            if(dut.remote_mask!==1 || dut.watchdog!==(WATCHDOG-1)) begin $display("FAIL unsigned watchdog high-bit count");$finish;end
            tick;ce=0;
            if(dut.remote_mask!==0 || dut.watchdog!==0) begin $display("FAIL unsigned watchdog deadline");$finish;end
        end
        done=1;
    end
endmodule

module tb_timer_unsigned;
    reg clk=0,rst=1,send=0;
    wire [3:0] done;
    timer_unsigned_bridge_check #(.WATCHDOG(32'h80000000)) boundary(clk,rst,done[0]);
    timer_unsigned_bridge_check #(.WATCHDOG(32'h80000001)) above_boundary(clk,rst,done[1]);
    timer_unsigned_bridge_check #(.WATCHDOG(32'hffffffff)) maximum(clk,rst,done[2]);
    timer_unsigned_bridge_check #(.CLOCK_HZ(64'd107374182450),.WATCHDOG(3),.PARSER(1)) parser(clk,rst,done[3]);
    synth_uart #(.CLOCK_HZ(32'h80000001),.BAUD(1)) uart(
        .clk(clk),.rst(rst),.rx(1'b1),.tx_data(8'ha5),.tx_send(send));
    always #5 clk=~clk;
    initial begin
        repeat(4)@(negedge clk);rst=0;@(negedge clk);#1;
        if(uart.TIMER_WIDTH!=32) begin $display("FAIL unsigned UART timer width");$finish;end
        send=1;@(negedge clk);#1;send=0;
        if(!uart.tx_busy || uart.tx_timer!==32'h80000000) begin $display("FAIL unsigned UART reload lost high bit");$finish;end
        @(negedge clk);#1;
        if(uart.tx_timer!==32'h7fffffff) begin $display("FAIL unsigned UART decrement");$finish;end
        wait(&done);
        $display("PASS unsigned timer widths, parser/watchdog expiry and UART high-bit reload/decrement");$finish;
    end
    initial begin #2000;$display("FAIL unsigned timer timeout");$finish;end
endmodule
