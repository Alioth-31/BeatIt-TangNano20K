`timescale 1ns/1ps
// Reuses the UART stimulus/packet observation pattern from tb_expression_bridge.
module tb_guide_bridge #(parameter MONO=0);
    reg clk=0,rst=1,rx=1,ce=0;wire tx;reg[7:0]keys=0;
    reg[7:0]data[0:7];integer tick=0,seq=0,checks=0,i,j;
    reg[15:0]crc;wire[63:0]request;wire commit,valid,enabled,song;wire[1:0]tempo;
    wire[127:0]query;wire[55:0]map;wire[279:0]played;wire[63:0]state;wire[39:0]held;
    wire[2:0]timbre;
    reg packet_was=0;reg[7:0]reply_type;reg[143:0]reply;integer replies=0,old_replies,start_reply,max_responses=0;
    reg[7:0]reply_types[0:63];reg[143:0]reply_data[0:63];
    synth_app_bridge #(.CLOCK_HZ(1152000),.BAUD(115200),.PERFORMANCE_ENABLED(1),.GUIDE_ENABLED(1),.MONO_ENABLED(MONO)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),.raw_keys(8'hff),
        .physical_keys(keys),.performance_play_keys(keys),.vol_up(1'b0),.vol_down(1'b0),
        .bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .ui_commit_valid(1'b0),.ui_commit_field(3'd0),.ui_commit_value(8'd0),
        .ui_settings_active(1'b0),.ui_selected_field(3'd5),.ui_preview_value(8'd0),
        .active_voice_count(6'd0),.audio_fault(1'b0),.source_midi(played),.performance_held(held),.mapped_physical_midi(map),
        .peripheral_request(request),.guide_commit(commit),.guide_config_valid(valid),.guide_query(query),.performance_timbre(timbre));
    guide_control #(.SAMPLE_HZ(240)) control(clk,rst,ce,request,commit,valid,query,1'b0,3'd0,8'd0,
        1'b0,3'd0,1'b0,map,played[55:0],held[7:0],MONO && timbre==4,1'b1,8'h15,enabled,song,tempo,,state);
    always #5 clk=~clk;
    always @(negedge clk)begin
        tick=tick+1;ce=(tick%1024)==0;
        if(dut.packet_active&&!packet_was)begin reply_types[replies]=dut.out_type;reply_data[replies]=dut.out_payload;replies=replies+1;reply_type=dut.out_type;reply=dut.out_payload;end
        packet_was=dut.packet_active;if(dut.resp_count>max_responses)max_responses=dut.resp_count;
    end
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide bridge %0s",msg);$finish;end end endtask
    task byte_out;input[7:0]v;integer b;begin rx=0;repeat(10)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=v[b];repeat(10)@(negedge clk);end rx=1;repeat(10)@(negedge clk);end endtask
    task crc_out;input[7:0]v;integer b;begin byte_out(v);crc=crc^{v,8'd0};for(b=0;b<8;b=b+1)crc=crc[15] ? (crc<<1)^16'h1021 : crc<<1;end endtask
    task burst;input[7:0]kind;input integer length;begin
        old_replies=replies;crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(kind);crc_out(seq);crc_out(seq>>8);crc_out(length);
        for(i=0;i<length;i=i+1)crc_out(data[i]);byte_out(crc[7:0]);byte_out(crc[15:8]);seq=seq+1;
    end endtask
    task packet;input[7:0]kind;input integer length;begin burst(kind,length);repeat(5000)@(negedge clk);check(replies==old_replies+1,"one reply per command");end endtask
    initial begin
        for(i=0;i<8;i=i+1)data[i]=0;repeat(8)@(negedge clk);rst=0;repeat(1200)@(negedge clk);
        check(map=={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60},"authoritative C major mapping without held notes");
        data[0]=1;data[1]=0;data[2]=2;data[3]=1;packet(8'h28,4);
        check(reply_type==8'h80&&reply[15:0]==16'h0028&&state[1],"guide SET starts accepted exercise");
        // Initial source MIDI is zero until the first real note-on commit.
        // A raw key edge must never be judged against that previous MIDI word.
        keys=1;repeat(60000)@(negedge clk);keys=0;wait(state[11:8]==1);@(negedge clk);
        check(state[39:24]==0,"first correct key judged with matching committed MIDI, no false miss/wrong");
        packet(8'h29,0);check(reply_type==8'h8d&&reply[31:0]==32'h07020001&&reply[63:56]==8'h15,"readback actual run config and delivered LEDs");
        data[2]=4;packet(8'h28,4);check(reply[15:0]==16'h0128&&tempo==2&&state[1],"invalid SET rejected atomically");
        packet(8'h28,3);check(reply[15:0]==16'h0128,"SET length check");
        packet(8'h29,1);check(reply[15:0]==16'h0129,"GET length check");
        packet(8'h24,0);check(reply_type==8'h89&&reply[47:40]==5,"legacy performance state carries expanded field number");
        start_reply=replies;
        for(j=0;j<12;j=j+1)burst(8'h29,0);
        data[0]=1;data[1]=1;data[2]=1;data[3]=0;burst(8'h28,4);burst(8'h29,0);repeat(45000)@(negedge clk);
        check(replies==start_reply+14&&max_responses==4,"queued requests preserve order under response backpressure");
        for(j=0;j<12;j=j+1)check(reply_types[start_reply+j]==8'h8d&&reply_data[start_reply+j][23:0]==24'h020001,"queued GET retains original configuration snapshot");
        check(reply_types[start_reply+12]==8'h80&&reply_data[start_reply+12][15:0]==16'h0028,"queued SET ACK");
        check(reply_types[start_reply+13]==8'h8d&&reply_data[start_reply+13][31:0]==32'h06010101,"following GET sees new paused song/tempo");
        keys=1;repeat(2000)@(negedge clk);check(played[6:0]==60,"key stores original played MIDI");
        // Existing SET_PERFORMANCE root/scale/octave/timbre.
        data[0]=2;data[1]=0;data[2]=4;data[3]=0;packet(8'h20,4);
        check(map[6:0]==62&&map[55:49]==74&&played[6:0]==60,"new key map updates but held old pitch stays latched");
        packet(8'h29,0);check(reply[95:88]==2&&!reply[24],"unplayable mapped song is reported and paused");
        if(MONO)begin
            keys=0;repeat(4000)@(negedge clk); // Drain the independent key-up notification.
            data[0]=0;data[1]=0;data[2]=4;data[3]=4;packet(8'h20,4);
            check(reply[15:0]==16'h0020 && timbre==4,"explicit mono patch accepted");
            packet(8'h24,0);check(reply[31:24]==4 && reply[34],"mono ID and capability survive status readback");
            packet(8'h29,0);check(reply[95:88]==3 && !reply[26] && reply[111:104]==1,
                "chord exercise rejects mono patch instead of dropping required notes");
            data[3]=3;packet(8'h20,4);check(reply[15:0]==16'h0120 && timbre==4,"custom remains non-selectable and invalid SET is atomic");
            data[3]=0;packet(8'h20,4);packet(8'h29,0);
            check(reply[95:88]==0 && reply[26] && !reply[24],"poly patch restores compatibility without auto-start");
        end
        $display("PASS guide bridge %0d checks",checks);$finish;
    end
    initial begin #12000000;$display("FAIL guide bridge timeout");$finish;end
endmodule
