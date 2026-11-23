`timescale 1ns/1ps
module tb_performance_bridge;
    reg clk=0,rst=1,rx=1,ce=0;
    reg [7:0] keys=0,play=0;
    reg ui_valid=0;reg [1:0] ui_field=0;reg [7:0] ui_value=0;
    wire tx;wire [39:0] sources;wire [279:0] midi;wire [639:0] instances;
    wire [3:0] root;wire [1:0] scale,timbre,wave,tone,pa,pb;
    wire [2:0] octave;wire [15:0] revision;
    wire [7:0] faults;wire [31:0] held,physical,frame;
    wire [16:0] volume,bend;
    reg [7:0] data[0:7];integer tick=0,seq=0,checks=0,i;
    reg [15:0] crc;
    reg [639:0] previous_tokens=0;
    integer source_check;
    synth_app_bridge #(.CLOCK_HZ(1152000),.BAUD(115200),.WATCHDOG_SAMPLES(1000),
        .PERFORMANCE_ENABLED(1),.WAVE_CONTROL_ENABLED(1),.TONE_CONTROL_ENABLED(1),.INDEPENDENT_CONTROL_ENABLED(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),
        .raw_keys(~keys),.physical_keys(keys),.vol_up(1'b0),.vol_down(1'b0),
        .bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'd0),.audio_fault(1'b0),.held_keys(held),
        .volume(volume),.bend(bend),.preset(pa),.faults(faults),
        .physical_mask(physical),.frame_counter(frame),.waveform_mode(wave),.tone_mode(tone),.osc2_preset(pb),
        .performance_play_keys(play),.ui_commit_valid(ui_valid),.ui_commit_field(ui_field),.ui_commit_value(ui_value),
        .ui_settings_active(1'b0),.ui_selected_field(2'd0),.ui_preview_value(8'd0),
        .performance_root(root),.performance_scale(scale),.performance_octave(octave),.performance_timbre(timbre),
        .config_revision(revision),.performance_held(sources),.source_midi(midi),.source_instance(instances));
    always #5 clk=~clk;
    always @(negedge clk) begin tick=tick+1;ce=(tick%1024)==0;end
    // The optimized top may observe the epoch toggle because this authority
    // accepts at most one strictly +1 instance update per source/audio frame.
    always @(posedge clk) begin
        if(rst) previous_tokens=0;
        else if(ce) begin
            #1;
            for(source_check=0;source_check<40;source_check=source_check+1)
                if(instances[source_check*16+:16]!=previous_tokens[source_check*16+:16] &&
                   instances[source_check*16+:16]!=(previous_tokens[source_check*16+:16]+16'd1)) begin
                    $display("FAIL source instance producer violated one increment per frame");$finish;
                end
            previous_tokens=instances;
        end
    end
    task require;input yes;input [8*110-1:0] text;
        begin if(yes!==1'b1) begin $display("FAIL performance bridge: %0s",text);$finish;end checks=checks+1;end
    endtask
    task byte_out;input [7:0] value;integer b;
        begin rx=0;repeat(10)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=value[b];repeat(10)@(negedge clk);end rx=1;repeat(10)@(negedge clk);end
    endtask
    task crc_out;input [7:0] value;integer b;
        begin byte_out(value);crc=crc^{value,8'd0};for(b=0;b<8;b=b+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;end
    endtask
    task packet;input [7:0] kind;input integer length;integer n;
        begin crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(kind);crc_out(seq);crc_out(seq>>8);crc_out(length);
            for(n=0;n<length;n=n+1)crc_out(data[n]);byte_out(crc[7:0]);byte_out(crc[15:8]);seq=seq+1;repeat(4000)@(negedge clk);end
    endtask
    task apply_config;input [7:0] r,s,o,t;
        begin data[0]=r;data[1]=s;data[2]=o;data[3]=t;packet(8'h20,4);end
    endtask
    task note;input [7:0] source,action,pitch;input [15:0] token;
        begin data[0]=source;data[1]=action;data[2]=pitch;data[3]=0;data[4]=token[7:0];data[5]=token[15:8];packet(8'h21,6);end
    endtask
    initial begin
        for(i=0;i<8;i=i+1)data[i]=0;
        repeat(8)@(negedge clk);rst=0;repeat(1100)@(negedge clk);
        apply_config(2,0,4,1);
        require(root==2 && scale==0 && octave==4 && timbre==1,"D major configuration must commit");
        require(wave==1 && pa==1 && pb==1 && tone==1,"patch commits all supported parameters together");
        keys=8'hff;play=8'hff;repeat(2200)@(negedge clk);
        require(sources[7:0]==8'hff,"all physical sources remain separate");
        require(midi[0+:7]==62 && midi[7+:7]==64 && midi[14+:7]==66 && midi[21+:7]==67 &&
            midi[28+:7]==69 && midi[35+:7]==71 && midi[42+:7]==73 && midi[49+:7]==74,"D major eight notes");
        apply_config(0,1,3,2);
        require(midi[0+:7]==62 && instances[0+:16]==1,"held pitch and instance survive configuration change");
        keys=0;play=0;repeat(2200)@(negedge clk);keys=8'hff;play=8'hff;repeat(2200)@(negedge clk);
        require(midi[0+:7]==48 && midi[14+:7]==51 && midi[35+:7]==56 && midi[42+:7]==58,"new notes use natural minor and octave");
        apply_config(12,0,4,0);
        require(root==0 && scale==1 && octave==3 && timbre==2,"invalid configuration must reject atomically");
        note(0,1,48,1);
        require(sources[8] && sources[0] && midi[56+:7]==48,"physical and remote unison have separate ownership");
        note(0,1,60,2);
        require(midi[56+:7]==60 && instances[128+:16]==2,"remote held retrigger changes instance");
        note(0,0,0,1);
        require(sources[8] && instances[128+:16]==2,"stale remote note-off cannot release replacement");
        note(0,0,0,2);
        require(!sources[8] && sources[0],"remote release preserves physical source");
        note(0,1,80,3);
        data[0]=1;data[1]=0;data[2]=0;data[3]=0;packet(8'h12,4);
        require(midi[56+:7]==60 && instances[128+:16]==4,"legacy key command restores its fixed pitch and a fresh instance");
        apply_config(0,2,4,0);keys=0;play=0;repeat(2200)@(negedge clk);keys=8'hff;play=8'hff;repeat(2200)@(negedge clk);
        require(midi[0+:7]==60 && midi[49+:7]==67,"chromatic layout");
        while(tick%1024!=100)@(negedge clk);
        ui_field=0;ui_value=1;ui_valid=1;@(negedge clk);ui_valid=0;@(negedge clk);
        ui_field=1;ui_value=14;ui_valid=1;@(negedge clk);ui_valid=0;repeat(2200)@(negedge clk);
        require(root==2 && scale==1 && timbre==1,"pending panel fields commit without erasing timbre proposal");
        require(faults==0,"normal commands do not fault");
        $display("PASS performance bridge %0d checks",checks);$finish;
    end
    initial begin #10000000;$display("FAIL performance bridge timeout");$finish;end
endmodule
