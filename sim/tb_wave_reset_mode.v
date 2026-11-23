`timescale 1ns/1ps
// UART uses the existing CRC-framed bridge; waveform changes occur at a
// sample boundary. Invalid CRC/range must never change the state.
module tb_wave_reset_mode;
    reg clk=0,rst=1,ce=0,rx=1;
    wire tx;
    wire [31:0] held,physical_mask,frame_counter;
    wire [16:0] volume,bend;
    wire [1:0] preset,tone,wave;
    wire [7:0] faults;
    reg [15:0] crc;
    synth_app_bridge #(.WAVE_CONTROL_ENABLED(1),.WAVE_RESET_MODE(3)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),
        .raw_keys(8'hff),.physical_keys(8'h00),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'd0),.audio_fault(1'b0),
        .held_keys(held),.volume(volume),.bend(bend),.preset(preset),
        .faults(faults),.physical_mask(physical_mask),
        .frame_counter(frame_counter),.tone_mode(tone),.waveform_mode(wave),
        .performance_play_keys(8'b0),.ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    task uart_byte;input [7:0] x;integer b;
        begin
            rx=0;repeat(427) @(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=x[b];repeat(427) @(negedge clk);end
            rx=1;repeat(427) @(negedge clk);
        end
    endtask
    task data_byte;input [7:0] x;integer b;
        begin
            uart_byte(x);
            crc=crc^{x,8'h00};
            for(b=0;b<8;b=b+1) crc=crc[15]?(crc<<1)^16'h1021:(crc<<1);
        end
    endtask
    task wave_packet;input [7:0] x;input bad_crc;
        begin
            crc=16'hffff;
            uart_byte(8'ha5);uart_byte(8'h5a);
            data_byte(1);data_byte(8'h15);data_byte(8'h55);data_byte(8'h33);
            data_byte(1);data_byte(x);
            uart_byte(bad_crc?(crc[7:0]^8'h01):crc[7:0]);uart_byte(crc[15:8]);
            repeat(10) @(negedge clk);
        end
    endtask
    task commit;
        begin
            @(negedge clk);ce=1;
            @(negedge clk);ce=0;
            repeat(10) @(negedge clk);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;
        if(wave!==3) begin $display("FAIL nonzero reset waveform");$finish;end
        wave_packet(2,0);
        if(wave!==3) begin $display("FAIL early commit");$finish;end
        commit;
        if(wave!==2 || faults!=0) begin $display("FAIL accepted command");$finish;end
        wave_packet(1,1);commit;
        if(wave!==2) begin $display("FAIL CRC validation");$finish;end
        wave_packet(4,0);commit;
        if(wave!==2) begin $display("FAIL range validation");$finish;end
        wave_packet(0,0);commit;
        if(wave!==0) begin $display("FAIL sine return");$finish;end
        $display("PASS nonzero waveform reset + UART changes and CRC");$finish;
    end
    initial begin #50000000;$display("FAIL timeout");$finish;end
endmodule
