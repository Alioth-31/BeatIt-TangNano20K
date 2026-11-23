`timescale 1ns/1ps
`include "sim/i2c_peripheral_model.vh"
`timescale 1ns/1ps
module tb_guide_system;
    reg clk=0,reset=1,rx=1,left_n=1;reg[7:0]keys=8'hff;
    tri1 scl,sda;wire release_sda;reg led_on=1;wire[7:0]latch,ledcfg;
    wire[31:0]starts,writes;wire tx,pa;wire[63:0]guide_state;
    integer checks=0,frames=0,nonzero=0;reg[15:0]crc;
    nano20k_app_top #(.NUM_VOICES(32),.PERFORMANCE_ENABLED(1),.PERIPHERALS_ENABLED(1),.GUIDE_ENABLED(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),
        .FX_REVERB_ENABLE(1),.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2),.SETTINGS_HOLD_SAMPLES(2)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(left_n),.bend_ab(2'b11),.bend_sw_n(1'b1),
        .uart_rx(rx),.uart_tx(tx),.PA_EN(pa),.peripheral_scl(scl),.peripheral_sda(sda),.guide_display_state(guide_state));
    // Poll the model sooner so the LED-disconnect check does not simulate
    // several million otherwise idle audio clocks.
    defparam dut.expression_enabled.controls.peripherals.HEALTH_CYCLES=131072;
    assign sda=release_sda ? 1'bz : 1'b0;
    i2c_peripheral_model model(clk,scl,sda,release_sda,1'b0,led_on,1'b0,1'b0,1'b0,1'b0,latch,ledcfg,starts,writes);
    always #5 clk=~clk;
    always @(posedge clk)if(!dut.rst)begin
        if(dut.tx_valid)begin frames=frames+1;if(dut.tx_pcm!=0)nonzero=nonzero+1;end
        if(dut.audio_fault)begin $display("FAIL guide system audio deadline/fault");$finish;end
    end
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide system %0s",msg);$finish;end end endtask
    task byte_out;input[7:0]v;integer b;begin rx=0;repeat(427)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=v[b];repeat(427)@(negedge clk);end rx=1;repeat(427)@(negedge clk);end endtask
    task crc_out;input[7:0]v;integer b;begin byte_out(v);crc=crc^{v,8'd0};for(b=0;b<8;b=b+1)crc=crc[15] ? (crc<<1)^16'h1021 : crc<<1;end endtask
    task start_guide;begin
        crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h28);crc_out(0);crc_out(0);crc_out(4);
        crc_out(1);crc_out(1);crc_out(2);crc_out(1);byte_out(crc[7:0]);byte_out(crc[15:8]);repeat(30000)@(negedge clk);
    end endtask
    task phone_target;input [7:0] mask;input [15:0] revision;begin
        crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h2a);crc_out(0);crc_out(0);crc_out(3);
        crc_out(mask);crc_out(revision[7:0]);crc_out(revision[15:8]);byte_out(crc[7:0]);byte_out(crc[15:8]);
        repeat(30000)@(negedge clk);
    end endtask
    initial begin
        repeat(10)@(negedge clk);reset=0;wait(dut.peripheral_led_available);repeat(5000)@(negedge clk);
        keys=8'h7f;repeat(60000)@(negedge clk);
        check(dut.peripheral_led_applied==8'h80&&latch==8'h7f,"free performance key LEDs delivered over I2C");
        phone_target(8'h05,0);
        check(dut.peripheral_led_applied==8'h05&&latch==8'hfa,"phone chord targets reach physical LED latch");
        phone_target(8'h02,1);
        check(latch==8'hfa,"outdated mapping does not replace phone targets");
        phone_target(0,1);
        check(latch==8'h7f,"clear restores physical-key feedback regardless of mapping");
        phone_target(8'h04,0);
        check(latch==8'hfb,"phone target replaces previous pattern");
        // Accelerate the existing 1024-sample lease tick in simulation only.
        force dut.bridge.frame_counter[9:0]=0;
        repeat(60000)@(negedge clk);
        release dut.bridge.frame_counter[9:0];
        check(latch==8'h7f,"unrenewed phone target expires and restores local feedback");
        start_guide();check(guide_state[1]&&guide_state[23:16]==8'h15,"chord exercise starts with C/E/G target");
        phone_target(8'h02,0);
        check(dut.peripheral_led_applied==8'h15&&latch==8'hea,"wrong played key cannot overwrite guide LEDs");
        check(dut.active_count==1&&nonzero>0&&pa,"guide never auto-plays chord and missing ADC preserves sound");
        left_n=0;repeat(60000)@(negedge clk);
        check(dut.ui_settings_active&&!guide_state[1]&&latch==8'hfe,"settings pauses and owns exactly one LED");
        check(dut.play_keys==8'h80,"held pre-menu note retains ownership");
        left_n=1;repeat(10000)@(negedge clk);check(!guide_state[1],"settings exit remains paused");
        start_guide();check(guide_state[1],"explicit remote resume");
        led_on=0;wait(!dut.peripheral_led_available);repeat(5000)@(negedge clk);
        check(!guide_state[1]&&guide_state[7:5]==4&&pa&&dut.active_count==1,"LED loss pauses guidance while audio continues");
        led_on=1;wait(dut.peripheral_led_available);repeat(10000)@(negedge clk);
        check(!guide_state[1],"LED reconnect cannot resume by itself");
        keys=8'hff;reset=1;repeat(20)@(negedge clk);check(!pa,"reset silence");
        $display("PASS guide+64DDS+reverb+I2C %0d checks, %0d PCM frames",checks,frames);$finish;
    end
    initial begin #60000000;$display("FAIL guide system timeout");$finish;end
endmodule
