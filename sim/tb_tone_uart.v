`timescale 1ns/1ps
// Exercises the actual bridge UART parser with optional tone commands, without
// a hardware board. The command must not modify mode before sample_ce.
module tb_tone_uart;
    reg clk=0,rst=1,ce=0,rx=1;
    wire tx;
    wire [31:0] held,physical_mask,frame_counter;
    wire [16:0] volume,bend;
    wire [1:0] preset,tone;
    wire [7:0] faults;
    reg [15:0] crc;
    integer i;
    synth_app_bridge #(.TONE_CONTROL_ENABLED(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),
        .raw_keys(8'hff),.physical_keys(8'h00),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'd0),.audio_fault(1'b0),
        .held_keys(held),.volume(volume),.bend(bend),.preset(preset),
        .faults(faults),.physical_mask(physical_mask),
        .frame_counter(frame_counter),.tone_mode(tone),
        .performance_play_keys(8'b0),.ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    task uart_byte; input [7:0] x; integer b;
        begin
            rx=0;repeat(427) @(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=x[b];repeat(427) @(negedge clk);end
            rx=1;repeat(427) @(negedge clk);
        end
    endtask
    task data_byte; input [7:0] x;integer b;
        begin
            uart_byte(x);
            crc=crc ^ {x,8'h00};
            for(b=0;b<8;b=b+1) crc=crc[15]?(crc<<1)^16'h1021:(crc<<1);
        end
    endtask
    task tone_packet;input [7:0] x;input bad_crc;
        begin
            crc=16'hffff;
            uart_byte(8'ha5);uart_byte(8'h5a);
            data_byte(1);data_byte(8'h14);data_byte(8'h34);data_byte(8'h12);
            data_byte(1);data_byte(x);
            uart_byte(bad_crc ? (crc[7:0]^8'h01) : crc[7:0]);
            uart_byte(crc[15:8]);
            repeat(10) @(negedge clk);
        end
    endtask
    task commit;begin
        @(negedge clk);ce=1;
        @(negedge clk);ce=0;
        repeat(10) @(negedge clk);
    end endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;
        if(tone!==0) begin $display("FAIL tone reset");$finish;end
        tone_packet(3,0);
        if(tone!==0) begin $display("FAIL non-boundary tone update");$finish;end
        commit;
        if(tone!==3 || faults!=0) begin $display("FAIL tone change");$finish;end
        tone_packet(2,1);commit;
        if(tone!==3) begin $display("FAIL CRC rejection");$finish;end
        tone_packet(4,0);commit;
        if(tone!==3) begin $display("FAIL range rejection");$finish;end
        tone_packet(0,0);commit;
        if(tone!==0) begin $display("FAIL return to dry");$finish;end
        $display("PASS tone UART CRC, range, sample boundary and reset");$finish;
    end
    initial begin #50000000;$display("FAIL tone UART timeout");$finish;end
endmodule
