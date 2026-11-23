`timescale 1ns/1ps
// Real UART -> authority -> physical mapping -> priority/glide ->64DDS ->I2S.
// Baseline fails because the explicit fourth instrument patch is absent.
module tb_mono_system;
    reg clk=0,reset=1,rx=1;reg [7:0] keys=8'hff;
    wire tx,bck,ws,sd,pa;wire [5:0] leds;wire [63:0] display;
    reg [15:0] crc;integer i,checks=0,slot=-1,old_remaining;
    reg [31:0] previous_increment;
    nano20k_app_top #(.NUM_VOICES(32),.PERFORMANCE_ENABLED(1),.INDEPENDENT_OSC_ENABLE(1),.DUAL_OSC_ENABLE(1),
`ifndef LEGACY_MONO_RED
        .MONO_ENABLED(1),
`endif
        .FX_WAVE_LIVE(1),.FX_TONE_ENABLE(1),.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),
        .uart_rx(rx),.uart_tx(tx),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(leds),.display_state(display));
    always #5 clk=~clk;
    task require;input ok;input [767:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",label);$finish;end end
    endtask
    task byte_out;input [7:0] value;integer b;
        begin rx=0;repeat(427)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=value[b];repeat(427)@(negedge clk);end rx=1;repeat(427)@(negedge clk);end
    endtask
    task crc_out;input [7:0] value;integer b;
        begin byte_out(value);crc=crc^{value,8'd0};for(b=0;b<8;b=b+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;end
    endtask
    task patch;input [7:0] timbre;
        begin crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(8'h20);crc_out(2);crc_out(0);crc_out(4);
            crc_out(0);crc_out(0);crc_out(4);crc_out(timbre);byte_out(crc[7:0]);byte_out(crc[15:8]);repeat(4000)@(negedge clk);end
    endtask
    task frames;input integer count;begin repeat(count)begin @(negedge clk);wait(dut.pcm_valid);@(negedge clk);require(!dut.audio_fault,"audio/route deadlines remain healthy");end end endtask
    initial begin
        repeat(10)@(negedge clk);reset=0;repeat(4000)@(negedge clk);
        patch(4);require(dut.performance_timbre==4,"UART accepts explicitly labeled mono-legato patch");
        require(display[10] && display[21:20]==0,"coherent display carries the extended timbre bit");
        keys=8'hfe;frames(45);
        for(i=0;i<32;i=i+1)if(dut.active[i])slot=i;
        require(slot>=0 && dut.active==(32'b1<<slot),"one physical note owns one mono A/B voice");
        require(dut.core.increment[slot]==32'd23409859,"first C4 note reaches both DDS without stale glide");
        old_remaining=dut.core.remaining[slot];keys=8'hfc;frames(4);
        require(dut.active==(32'b1<<slot) && dut.core.owner[slot]==1,"new overlapping key transfers the same voice");
        require(dut.core.remaining[slot]<old_remaining && dut.core.increment[slot]>32'd23409859 &&
            dut.core.increment[slot]<32'd26276679,"A/B attack continues while pitch glides toward D4");
        previous_increment=dut.core.increment[slot];keys=8'hfe;frames(4);
        require(dut.core.owner[slot]==0 && dut.active==(32'b1<<slot),"releasing newest key resumes the still-held C4");
        keys=8'hff;frames(4);
        require(dut.core.env_state[slot]==4 && dut.core.env_state_b[slot]==4,"last key releases both envelopes");
        patch(0);keys=8'hfc;frames(4);
        require(dut.performance_timbre==0 && !display[10] && dut.active_count>=2,"ordinary patch still plays a chord");
        require(pa && !dut.audio_fault,"final audio link healthy");
        $display("PASS mono full UART/physical/glide/64DDS/I2S integration (%0d checks)",checks);$finish;
    end
    initial begin #100000000;$display("FAIL mono integration timeout");$finish;end
endmodule
