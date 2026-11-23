`timescale 1ns/1ps
module tb_performance_system;
    reg clk=0,reset=1,rx=1;reg [7:0] keys=8'hff;
    wire tx,bck,ws,sd,pa;wire [5:0] leds;
    reg [15:0] crc;integer i,positive=0,negative=0,frames=0;
    nano20k_app_top #(.NUM_VOICES(32),.PERFORMANCE_ENABLED(1),.INDEPENDENT_OSC_ENABLE(1),.DUAL_OSC_ENABLE(1),
        .FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),
        .uart_rx(rx),.uart_tx(tx),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(leds));
    always #5 clk=~clk;
    always @(posedge clk) if(dut.pcm_valid) begin frames=frames+1;if(dut.pcm>0)positive=positive+1;if(dut.pcm<0)negative=negative+1;end
    task byte_out;input [7:0] value;integer b;
        begin rx=0;repeat(427)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=value[b];repeat(427)@(negedge clk);end rx=1;repeat(427)@(negedge clk);end
    endtask
    task crc_out;input [7:0] value;integer b;
        begin byte_out(value);crc=crc^{value,8'd0};for(b=0;b<8;b=b+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;end
    endtask
    task set_keys;input [31:0] mask;
        begin crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h12);crc_out(1);crc_out(0);crc_out(4);
            crc_out(mask[7:0]);crc_out(mask[15:8]);crc_out(mask[23:16]);crc_out(mask[31:24]);byte_out(crc[7:0]);byte_out(crc[15:8]);repeat(4000)@(negedge clk);end
    endtask
    task short_patch;
        begin crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h20);crc_out(2);crc_out(0);crc_out(4);
            crc_out(0);crc_out(0);crc_out(4);crc_out(1);byte_out(crc[7:0]);byte_out(crc[15:8]);repeat(4000)@(negedge clk);end
    endtask
    initial begin
        repeat(10)@(negedge clk);reset=0;repeat(4000)@(negedge clk);
        short_patch;keys=0;set_keys(32'hffffffff);repeat(500000)@(negedge clk);
        if(dut.performance_held!==40'hffffffffff || dut.active!==32'hffffffff || dut.audio_fault || !pa) begin
            $display("FAIL performance integration sources=%h active=%h fault=%b",dut.performance_held,dut.active,dut.audio_fault);$finish;end
        if(positive==0 || negative==0)begin $display("FAIL signed performance audio");$finish;end
        set_keys(0);repeat(400000)@(negedge clk);
        if(dut.performance_held!==40'hff || dut.audio_fault)begin $display("FAIL remote release source isolation");$finish;end
        keys=8'hff;repeat(3200000)@(negedge clk);
        if(dut.active!=0 || dut.pcm!=0 || dut.audio_fault)begin $display("FAIL performance release silence");$finish;end
        $display("PASS 40-source/32-voice performance top signed audio/release (%0d frames)",frames);$finish;
    end
    initial begin #250000000;$display("FAIL performance integration timeout");$finish;end
endmodule
