`timescale 1ns/1ps
// Identical audio/control stimuli with and without a passive video consumer.
module tb_hdmi_audio;
    reg ac=0,vc=0,run_video=1,rst=1;reg [7:0] keys=8'hff;
    wire tx0,b0,w0,d0,p0,tx1,b1,w1,d1,p1;wire [5:0] l0,l1;
    wire cp,cn;wire [2:0] dp,dn;integer cycles=0,samples=0,nonzero=0;
    nano20k_app_top #(.NUM_VOICES(4),.PERFORMANCE_ENABLED(1),.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),
        .FX_TONE_ENABLE(1),.FX_WAVE_LIVE(1),.FX_ENABLE(1),.FX_DC_ENABLE(1),.FX_DELAY_ENABLE(1),.DEBOUNCE_CYCLES(8)) baseline(
        .clk_audio(ac),.reset_button(rst),.test_button(1'b0),.keys_n(keys),.volume_ab(2'b11),.volume_sw_n(1'b1),
        .bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1),.uart_tx(tx0),.HP_BCK(b0),.HP_WS(w0),.HP_DIN(d0),.PA_EN(p0),.led_n(l0));
    nano20k_hdmi_top #(.NUM_VOICES(4),.PERFORMANCE_ENABLED(1),.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),
        .FX_TONE_ENABLE(1),.FX_WAVE_LIVE(1),.FX_ENABLE(1),.FX_DC_ENABLE(1),.FX_DELAY_ENABLE(1),.DEBOUNCE_CYCLES(8)) dut(
        .clk_audio(ac),.clk_video(vc),.reset_button(rst),.test_button(1'b0),.keys_n(keys),.volume_ab(2'b11),.volume_sw_n(1'b1),
        .bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1),.uart_tx(tx1),.HP_BCK(b1),.HP_WS(w1),.HP_DIN(d1),.PA_EN(p1),.led_n(l1),
        .tmds_clk_p(cp),.tmds_clk_n(cn),.tmds_data_p(dp),.tmds_data_n(dn));
    always #5 ac=~ac;
    always #10 if(run_video)vc=~vc;
    always @(negedge ac)if(!baseline.rst)begin
        cycles=cycles+1;
        if({tx0,b0,w0,d0,p0,l0}!=={tx1,b1,w1,d1,p1,l1})$fatal(1,"audio pins/control changed by video");
        if(baseline.display_valid!==dut.pcm_valid || baseline.display_pcm!==dut.output_pcm)$fatal(1,"post-effects mismatch");
        if(dut.pcm_valid)begin samples=samples+1;if(dut.output_pcm!=0)nonzero=nonzero+1;end
        if(dut.instrument.audio_fault)$fatal(1,"video induced audio fault");
    end
    initial begin
        repeat(12)@(negedge ac);rst=0;repeat(4000)@(negedge ac);keys=8'hf0;
        repeat(220000)@(negedge ac);run_video=0;
        repeat(100000)@(negedge ac);run_video=1;
        repeat(220000)@(negedge ac);keys=8'hff;repeat(100000)@(negedge ac);
        if(samples<500 || nonzero<200 || dut.instrument_state[63]!==1 || dut.instrument_state[61]!==p1)
            $fatal(1,"missing real PCM/authority %d %d",samples,nonzero);
        $display("PASS HDMI consumer audio/I2S equivalence including stopped video clock (%d samples)",samples);$finish;
    end
endmodule
