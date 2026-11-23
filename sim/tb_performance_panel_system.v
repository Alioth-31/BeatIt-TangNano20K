`timescale 1ns/1ps
module tb_performance_panel_system;
    reg clk=0,reset=1;reg [7:0] keys=8'hff;
    reg [1:0] right_ab=3;reg left_sw=1,right_sw=1;
    wire tx,bck,ws,sd,pa;wire [5:0] leds;integer checks=0;
    nano20k_app_top #(.PERFORMANCE_ENABLED(1),.INDEPENDENT_OSC_ENABLE(1),.DUAL_OSC_ENABLE(1),
        .FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2),.SETTINGS_HOLD_SAMPLES(3)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(left_sw),.bend_ab(right_ab),.bend_sw_n(right_sw),
        .uart_rx(1'b1),.uart_tx(tx),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(leds));
    always #5 clk=~clk;
    task require;input yes;input [8*100-1:0] text;
        begin if(yes!==1'b1)begin $display("FAIL panel integration: %0s",text);$finish;end checks=checks+1;end
    endtask
    task turn;integer e;
        begin for(e=0;e<4;e=e+1)begin case(e)0:right_ab=2;1:right_ab=0;2:right_ab=1;3:right_ab=3;endcase repeat(15)@(negedge clk);end end
    endtask
    initial begin
        repeat(10)@(negedge clk);reset=0;repeat(3000)@(negedge clk);
        keys=8'hfe;repeat(2200)@(negedge clk);
        require(dut.performance_held[0] && dut.source_midi[0+:7]==60,"physical C4 reaches independent source");
        left_sw=0;repeat(5000)@(negedge clk);
        require(dut.ui_settings_active && dut.performance_held[0],"held original note survives menu entry");
        keys=8'hfc;repeat(2200)@(negedge clk);turn;turn;repeat(100)@(negedge clk);
        require(dut.ui_selected_field==1 && dut.ui_preview_value==2,"menu key selects tonality and detents preview D");
        require(dut.performance_root==0,"preview does not commit");
        right_sw=0;repeat(40)@(negedge clk);right_sw=1;repeat(2300)@(negedge clk);
        require(dut.performance_root==2 && dut.performance_scale==0,"release confirms D major via bridge");
        require(dut.source_midi[0+:7]==60 && dut.source_instance[0+:16]==1,"old held pitch stays C4");
        left_sw=1;repeat(2200)@(negedge clk);
        require(!dut.ui_settings_active && dut.performance_held[7:0]==1,"held menu key stays suppressed on exit");
        keys=8'hff;repeat(2200)@(negedge clk);keys=8'hfe;repeat(2200)@(negedge clk);
        require(dut.source_midi[0+:7]==62 && dut.source_instance[0+:16]==2,"new press uses D4 and fresh instance");
        turn;repeat(2300)@(negedge clk);
        require(dut.performance_timbre==1 && dut.waveform_mode==1 && dut.preset==1,"perform detent selects complete patch");
        require(dut.bend==65536 && !dut.audio_fault && dut.faults==0,"old knob bend/reset actions are disabled");
        $display("PASS panel-to-bridge-to-MIDI-core %0d checks",checks);$finish;
    end
    initial begin #1000000;$display("FAIL panel integration timeout");$finish;end
endmodule
