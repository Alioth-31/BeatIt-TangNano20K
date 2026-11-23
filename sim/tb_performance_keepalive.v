`timescale 1ns/1ps
module tb_performance_keepalive;
    reg clk=0,rst=1,ce=0,rx=1;integer tick=0,seq=0,n;
    reg [15:0] crc;reg [7:0] data[0:5];
    wire [39:0] held;wire [279:0] midi;wire [639:0] tokens;
    synth_app_bridge #(.PERFORMANCE_ENABLED(1),.CLOCK_HZ(1152000),.BAUD(115200),.WATCHDOG_SAMPLES(80)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.physical_keys(8'd1),.raw_keys(8'hfe),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'd0),.audio_fault(1'b0),.performance_play_keys(8'd1),
        .ui_commit_valid(1'b0),.ui_commit_field(2'd0),.ui_commit_value(8'd0),.ui_settings_active(1'b0),
        .ui_selected_field(2'd0),.ui_preview_value(8'd0),.performance_held(held),.source_midi(midi),.source_instance(tokens));
    always #5 clk=~clk;
    always @(negedge clk)begin tick=tick+1;ce=(tick%64)==0;end
    task byte_out;input [7:0] x;integer b;
        begin rx=0;repeat(10)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=x[b];repeat(10)@(negedge clk);end rx=1;repeat(10)@(negedge clk);end
    endtask
    task crc_out;input [7:0] x;integer b;
        begin byte_out(x);crc=crc^{x,8'd0};for(b=0;b<8;b=b+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;end
    endtask
    task packet;input [7:0] kind;input integer length;integer i;
        begin crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(kind);crc_out(seq);crc_out(0);crc_out(length);
            for(i=0;i<length;i=i+1)crc_out(data[i]);byte_out(crc[7:0]);byte_out(crc[15:8]);seq=seq+1;repeat(1500)@(negedge clk);end
    endtask
    initial begin
        data[0]=0;data[1]=1;data[2]=69;data[3]=0;data[4]=1;data[5]=0;
        repeat(4)@(negedge clk);rst=0;packet(8'h21,6);
        for(n=0;n<4;n=n+1)begin
            repeat(2000)@(negedge clk);packet(8'h22,0);
            if(!held[8] || midi[56+:7]!=69 || tokens[128+:16]!=1)begin
                $display("FAIL keepalive must preserve native held pitch and instance across watchdog periods");$finish;end
        end
        repeat(5300)@(negedge clk);
        if(held[8] || !held[0])begin $display("FAIL missing keepalive releases only remote source");$finish;end
        packet(8'h21,6);data[1]=2;packet(8'h21,6);packet(8'h21,6);
        if(held[8])begin $display("FAIL read-only native queries must not refresh watchdog");$finish;end
        $display("PASS native keepalive preserves pitch/token and watchdog isolates physical keys");$finish;
    end
    initial begin #1000000;$display("FAIL keepalive timeout");$finish;end
endmodule
