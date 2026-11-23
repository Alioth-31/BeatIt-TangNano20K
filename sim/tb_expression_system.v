`timescale 1ns/1ps
`include "sim/i2c_peripheral_model.vh"
`timescale 1ns/1ps
module tb_expression_system;
    reg clk=0,reset=1,rx=1;reg [7:0] keys=8'hff;
    tri1 scl,sda;wire slave_release;reg adc_on=1,led_on=1;
    wire tx,bck,ws,sd,pa;wire [5:0] leds;
    wire [7:0] latch,ledcfg;wire [31:0] starts,writes;
    integer checks=0,frames=0,nonzero=0,i;reg [15:0] crc;
    reg measure_disable=0;integer elapsed_disable=0,neutral_cycles=0;
    nano20k_app_top #(.NUM_VOICES(32),.PERFORMANCE_ENABLED(1),.PERIPHERALS_ENABLED(1),
        .DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),.FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),
        .FX_REVERB_ENABLE(1),.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),
        .uart_rx(rx),.uart_tx(tx),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(leds),
        .peripheral_scl(scl),.peripheral_sda(sda));
    assign sda=slave_release ? 1'bz : 1'b0;
    i2c_peripheral_model model(clk,scl,sda,slave_release,adc_on,led_on,1'b0,1'b0,1'b0,1'b0,latch,ledcfg,starts,writes);
    always #5 clk=~clk;
    always @(posedge clk)if(dut.tx_valid)begin frames=frames+1;if(dut.tx_pcm!=0)nonzero=nonzero+1;end
    always @(negedge clk)if(measure_disable&&dut.expression_enabled.controls.enables==0&&neutral_cycles==0)begin
        elapsed_disable=elapsed_disable+1;
        if(dut.effective_volume==39321&&dut.effective_bend==65536&&dut.effective_osc2_bend==65536)neutral_cycles=elapsed_disable;
    end
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL expression system %0s",msg);$finish;end end endtask
    task byte_out;input[7:0]value;integer b;
        begin rx=0;repeat(427)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=value[b];repeat(427)@(negedge clk);end rx=1;repeat(427)@(negedge clk);end
    endtask
    task crc_out;input[7:0]value;integer b;
        begin byte_out(value);crc=crc^{value,8'd0};for(b=0;b<8;b=b+1)crc=crc[15] ? (crc<<1)^16'h1021 : crc<<1;end
    endtask
    task set_cal;input[7:0]channel,flags;input[15:0]low,centre,high;
        begin
            crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h26);crc_out(channel);crc_out(0);crc_out(8);
            crc_out(channel);crc_out(flags);crc_out(low[7:0]);crc_out(low[15:8]);crc_out(centre[7:0]);crc_out(centre[15:8]);crc_out(high[7:0]);crc_out(high[15:8]);
            byte_out(crc[7:0]);byte_out(crc[15:8]);repeat(20000)@(negedge clk);
        end
    endtask
    initial begin
        repeat(10)@(negedge clk);reset=0;
        wait(dut.expression_enabled.controls.valid==15);repeat(10000)@(negedge clk);
        check(dut.effective_volume==39321&&dut.effective_bend==65536&&dut.effective_osc2_bend==65536,"uncalibrated hardware preserves unity");
        keys=8'hfa;repeat(100000)@(negedge clk);
        check(nonzero>0&&pa&&!dut.audio_fault,"keys and audio with raw ADC available");
        check(dut.expression_enabled.controls.led_applied==5&&latch==8'hfa,"normal key LEDs through real I2C");
        set_cal(0,1,100,0,1600);set_cal(1,1,-100,700,1600);set_cal(2,1,-1600,-800,800);
        check(dut.expression_enabled.controls.active==6,"explicit calibration activates only retained XY sensors");
        check(dut.effective_volume==39321&&!dut.expression_enabled.controls.enables[0],"removed pressure cannot affect master volume");
        check(dut.volume==39321&&dut.effective_bend>65536,"master volume separate and X/vibrato reach DDS");
        check(dut.core.volume_target==dut.effective_volume&&dut.core.bend_target==dut.effective_bend,"core receives effective controls");
        set_cal(0,0,100,0,1600);set_cal(1,0,-100,700,1600);measure_disable=1;set_cal(2,0,-1600,-800,800);
        check(neutral_cycles>0&&neutral_cycles<=6144,"all disabled control stages drain within six frames");
        check(dut.expression_enabled.controls.active==0&&pa&&!dut.audio_fault,"explicit disable keeps ordinary performance alive");
        set_cal(0,1,100,0,1600);set_cal(1,1,-100,700,1600);set_cal(2,1,-1600,-800,800);
        adc_on=0;wait(!dut.expression_enabled.controls.adc_available);repeat(10000)@(negedge clk);
        check(dut.effective_volume==39321&&dut.effective_bend==65536&&dut.effective_osc2_bend==65536,"ADC absence returns unity and neutral");
        check(pa&&!dut.audio_fault&&dut.active!=0,"ADC failure cannot stop notes or audio");
        adc_on=1;wait(dut.expression_enabled.controls.active==6);repeat(10000)@(negedge clk);
        check(dut.effective_volume==39321,"ADC reconnect restores XY only, with unchanged volume");
        // A stuck bus must remain independent from the frame deadline.
        force sda=0;repeat(600000)@(negedge clk);release sda;
        check(pa&&!dut.audio_fault&&dut.effective_volume==39321,"stuck bus bounded recovery and uninterrupted audio");
        keys=8'hff;reset=1;repeat(20)@(negedge clk);
        check(!pa&&!sd,"reset mutes output");
        $display("PASS 64DDS+reverb+expression/I2C %0d checks, %0d frames, disable-to-neutral %0d clocks",checks,frames,neutral_cycles);$finish;
    end
    initial begin #80000000;$display("FAIL expression system timeout");$finish;end
endmodule
