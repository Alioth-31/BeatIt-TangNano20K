`timescale 1ns/1ps
// Final app datapath: all 64 DDS, live crossfade and all post-mix effects.
module tb_full64_audio #(parameter PERF=0,parameter REV=0,parameter MONO=0);
    reg clk=0,rst=1;
    wire bck,ws,sd,pa,uart_tx;
    wire [5:0] led;
    tri1 scl,sda;
    integer samples=0,output_samples=0,frames=0,core_cycle=0,max_cycles=0;
    integer last_output=-1,cycle=0,nonzero=0,max_output_cycles=0;
    integer note_index;
    reg [279:0] performance_notes=0;
    nano20k_app_top #(.NUM_VOICES(32),.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1),
      .PERFORMANCE_ENABLED(PERF),.FX_REVERB_ENABLE(REV),.MONO_ENABLED(MONO),
      .GUIDE_ENABLED(MONO),.PERIPHERALS_ENABLED(MONO),
      .FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),.FX_ENABLE(1),.FX_DC_ENABLE(1),.FX_DELAY_ENABLE(1)) dut(
      .clk_audio(clk),.reset_button(rst),.test_button(1'b0),.keys_n(8'hff),
      .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1),
      .peripheral_scl(scl),.peripheral_sda(sda),.uart_tx(uart_tx),
      .HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(led));
    always #5 clk=~clk;
    always @(posedge clk) if(!dut.rst)begin
      cycle=cycle+1;
      if(dut.core_ce)begin frames=frames+1;core_cycle=cycle;end
      if(dut.pcm_valid)begin
        samples=samples+1;
        if(cycle-core_cycle>max_cycles)max_cycles=cycle-core_cycle;
        if(cycle-core_cycle>=1000)begin $display("FAIL full64 core deadline");$finish;end
      end
      if(dut.tx_valid)begin
        if(cycle-core_cycle>max_output_cycles)max_output_cycles=cycle-core_cycle;
        if(cycle-core_cycle>=1000)begin $display("FAIL full64 effects deadline");$finish;end
        output_samples=output_samples+1;
        if(last_output>=0 && frames-last_output!=1)begin $display("FAIL full64 missing/duplicate frame sample");$finish;end
        last_output=frames;
        if((^dut.tx_pcm)===1'bx)begin $display("FAIL full64 unknown PCM");$finish;end
        if(dut.tx_pcm!=0)nonzero=nonzero+1;
      end
      if(dut.audio_fault)begin $display("FAIL full64 audio fault");$finish;end
    end
    initial begin
      repeat(8)@(negedge clk);rst=0;
      if(PERF)begin
        for(note_index=0;note_index<40;note_index=note_index+1)
          performance_notes[note_index*7+:7]=36+note_index;
        force dut.source_midi=performance_notes;
        force dut.performance_held=40'hffffffff00;
        if(MONO)force dut.performance_held=40'hffffffffff;
      end else force dut.held_keys=32'hffffffff;
      repeat(800*1024)@(negedge clk);
      force dut.waveform_mode=2'd1;force dut.tone_mode=2'd1;
      if(REV)force dut.performance_timbre=3'd1;
      repeat(800*1024)@(negedge clk);
      if(REV && (dut.reverb_wet!==16'd2048 || dut.reverb_room!==2'd0))$fatal(1,"bright reverb preset");
      force dut.waveform_mode=2'd3;force dut.tone_mode=2'd2;
      if(REV)force dut.performance_timbre=3'd2;
      repeat(3600*1024)@(negedge clk);
      if(REV)begin
        if(dut.reverb_wet!==16'd8192 || dut.reverb_room!==2'd2)$fatal(1,"pad reverb preset");
        force dut.performance_timbre=3'd3;
        repeat(2*1024)@(negedge clk);
        if(dut.reverb_wet!==16'd8192 || dut.reverb_room!==2'd2)$fatal(1,"custom patch lost reverb preset");
      end
      if(samples<5190 || output_samples!=samples || nonzero<500 || !pa || dut.active!==32'hffffffff)begin
        $display("FAIL full64 output samples=%0d/%0d nonzero=%0d active=%h",samples,output_samples,nonzero,dut.active);$finish;
      end
      if(MONO)begin
        force dut.performance_timbre=3'd4;
        repeat(150*1024)@(negedge clk);
        if(!dut.engine_mono || dut.engine_keys!==40'h8000000000 || !dut.core.mono_pitch_active)
          $fatal(1,"full40 to mono route/pitch activation");
        force dut.performance_held=40'h7fffffffff;
        repeat(80*1024)@(negedge clk);
        if(dut.engine_keys!==40'h4000000000 || dut.core.owner[dut.core.mono_slot]!=38)
          $fatal(1,"mono fallback with all effects enabled");
        force dut.performance_timbre=3'd0;
        repeat(80*1024)@(negedge clk);
        if(dut.engine_mono || dut.engine_keys!==40'h7fffffffff || dut.active!==32'hffffffff)
          $fatal(1,"mono to full polyphony with all effects enabled");
        if(output_samples!=samples || !pa)$fatal(1,"mono transition supply/PA");
      end
      $display("PASS full64 waveform/fx/I2S path frames=%0d max_core_cycles=%0d max_output_cycles=%0d reverb=%0d mono=%0d",frames,max_cycles,max_output_cycles,REV,MONO);$finish;
    end
    initial begin #60000000;$display("FAIL full64 timeout");$finish;end
endmodule
