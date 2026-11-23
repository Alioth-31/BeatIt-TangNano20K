`timescale 1ns/1ps
// These checks catch state mutation without a valid packet, asynchronous
// parameter loss, source ownership loss, and wire-visible event loss.
module tb_app_bridge;
    localparam BIT_CYCLES=10;
    reg clk=0,rst=1,sample_ce=0,rx=1;
    reg auto_samples=1,manual_sample=0,allow_event_gaps=0;
    wire tx;
    reg [7:0] keys=0;
    reg [7:0] raw_keys=8'hff;
    reg vu=0,vd=0,bu=0,bd=0,br=0,pn=0;
    reg audio_fault=0;
    wire [31:0] held,physical,frame;
    wire [16:0] volume,bend;
    wire [1:0] preset;
    wire [7:0] faults;
    integer cycles=0,checks=0,ack_count=0,event_count=0,param_count=0;
    integer hello_count=0,status_count=0,expected_event_seq=0,event_gaps=0;
    integer inputs_count=0;
    integer sampled_param_count=0;
    reg [31:0] expected_frame=0,param_tick[0:255];
    reg [31:0] key_tick[0:31],observed_physical=0;
    integer key_tick_index;
    reg [16:0] observed_volume=16384,observed_bend=65536;
    reg [1:0] observed_preset=0;
    reg [7:0] last_raw_keys,last_held_keys;
    integer ack_status[0:255];
    reg [7:0] packet[0:72];
    reg [7:0] sent[0:63];
    reg [7:0] received_byte;
    reg [31:0] event_down=0,event_up=0;
    reg [31:0] last_status_remote,last_status_physical;
    reg [15:0] last_status_volume;
    reg [7:0] last_status_bend;
    integer packet_pos=0,packet_size=0,i,j,seq_id;
    reg [15:0] wire_crc,check_crc;
    synth_app_bridge #(.CLOCK_HZ(1152000),.BAUD(115200),.WATCHDOG_SAMPLES(500))
        dut(.clk(clk),.rst(rst),.sample_ce(sample_ce),.uart_rx(rx),.uart_tx(tx),
            .physical_keys(keys),.raw_keys(raw_keys),.vol_up(vu),.vol_down(vd),.bend_up(bu),
            .bend_down(bd),.bend_reset(br),.preset_next(pn),
            .active_voice_count(6'd3),.audio_fault(audio_fault),.held_keys(held),
            .volume(volume),.bend(bend),.preset(preset),.faults(faults),
            .physical_mask(physical),.frame_counter(frame),
        .performance_play_keys(8'b0),.ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    always @(negedge clk) begin
        cycles=cycles+1;
        sample_ce=manual_sample || (auto_samples && (cycles%64)==0);
    end
    always @(posedge clk) begin
        if(rst) begin
            expected_frame=0;sampled_param_count=0;
            observed_physical=0;
            observed_volume=16384;observed_bend=65536;observed_preset=0;
        end else if(sample_ce) begin
            expected_frame=expected_frame+1;
            #1;
            require(frame==expected_frame,"frame counter advances once per committed sample");
            for(key_tick_index=0;key_tick_index<32;key_tick_index=key_tick_index+1)
                if(physical[key_tick_index]!=observed_physical[key_tick_index]) key_tick[key_tick_index]=expected_frame;
            if(volume!=observed_volume || bend!=observed_bend || preset!=observed_preset) begin
                if(sampled_param_count<256) param_tick[sampled_param_count]=expected_frame;
                sampled_param_count=sampled_param_count+1;
            end
            observed_volume=volume;observed_bend=bend;observed_preset=preset;
            observed_physical=physical;
        end
    end
    function [15:0] crc_byte;
        input [15:0] initial_crc; input [7:0] value;
        integer b; reg [15:0] c;
        begin
            c=initial_crc ^ {value,8'b0};
            for(b=0;b<8;b=b+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction
    task require;
        input yes; input [8*100-1:0] name;
        begin
            if(yes!==1'b1) begin $display("FAIL app bridge: %0s",name); $finish; end
            checks=checks+1;
        end
    endtask
    task send_byte;
        input [7:0] value;
        integer bit_id;
        begin
            rx=0; repeat(BIT_CYCLES) @(negedge clk);
            for(bit_id=0;bit_id<8;bit_id=bit_id+1) begin
                rx=value[bit_id]; repeat(BIT_CYCLES) @(negedge clk);
            end
            rx=1; repeat(BIT_CYCLES) @(negedge clk);
        end
    endtask
    task send_packet;
        input [7:0] typ; input [15:0] sequence_id;
        input integer length; input corrupt;
        integer n; reg [15:0] c;
        begin
            send_byte(8'ha5);send_byte(8'h5a);c=16'hffff;
            send_byte(1);c=crc_byte(c,1);
            send_byte(typ);c=crc_byte(c,typ);
            send_byte(sequence_id[7:0]);c=crc_byte(c,sequence_id[7:0]);
            send_byte(sequence_id[15:8]);c=crc_byte(c,sequence_id[15:8]);
            send_byte(length);c=crc_byte(c,length);
            for(n=0;n<length;n=n+1) begin send_byte(sent[n]);c=crc_byte(c,sent[n]);end
            send_byte(c[7:0] ^ (corrupt?8'h01:8'h00));send_byte(c[15:8]);
        end
    endtask
    task settle;
        begin repeat(18000) @(negedge clk); end
    endtask
    task commit_sample;
        begin
            manual_sample=1;@(negedge clk);@(posedge clk);#1;manual_sample=0;
            @(negedge clk);@(posedge clk);#1;
        end
    endtask
    // Independent asynchronous TX receiver, not the production UART decoder.
    always @(negedge tx) begin
        repeat(BIT_CYCLES+BIT_CYCLES/2) @(negedge clk);
        for(j=0;j<8;j=j+1) begin
            received_byte[j]=tx; repeat(BIT_CYCLES) @(negedge clk);
        end
        require(tx==1,"TX stop bit must be high");
        if(packet_pos==0) begin
            require(received_byte==8'ha5,"TX sync A5");packet[0]=received_byte;packet_pos=1;
        end else begin
            packet[packet_pos]=received_byte;packet_pos=packet_pos+1;
            if(packet_pos==7) begin
                require(packet[1]==8'h5a && packet[2]==1 && packet[6]<=64,"TX header");
                packet_size=9+packet[6];
            end
            if(packet_size!=0 && packet_pos==packet_size) begin
                check_crc=16'hffff;
                for(i=2;i<packet_size-2;i=i+1) check_crc=crc_byte(check_crc,packet[i]);
                if(check_crc!=={packet[packet_size-1],packet[packet_size-2]}) begin
                    $write("TX packet:");for(i=0;i<packet_size;i=i+1)$write(" %02x",packet[i]);
                    $display(" expected CRC=%04x",check_crc);
                end
                require(check_crc=={packet[packet_size-1],packet[packet_size-2]},"TX CRC");
                seq_id={packet[5],packet[4]};
                case(packet[3])
                    8'h80: begin
                        require(packet[6]==2,"ACK length");
                        if(seq_id<256) ack_status[seq_id]=packet[8];
                        ack_count=ack_count+1;
                    end
                    8'h81: begin
                        require(packet[6]==13 && packet[7]==1 && packet[8]==4 && packet[9]==15,"HELLO capabilities");
                        require({packet[13],packet[12],packet[11],packet[10]}==48000,"HELLO sample rate");
                        require({packet[17],packet[16],packet[15],packet[14]}==32'hffffffff,"HELLO supported notes");
                        case(hello_count)
                            0:require(seq_id==1,"HELLO sequence echoes request");
                            1:require(seq_id==12,"timeout recovery HELLO sequence");
                            2:require(seq_id==17,"framing recovery HELLO sequence");
                            3:require(seq_id==20,"overlong recovery HELLO sequence");
                        endcase
                        hello_count=hello_count+1;
                    end
                    8'h82: begin
                        require(packet[6]==18 && packet[7]==3,"STATUS length and active count");
                        last_status_remote={packet[12],packet[11],packet[10],packet[9]};
                        last_status_physical={packet[16],packet[15],packet[14],packet[13]};
                        last_status_volume={packet[18],packet[17]};last_status_bend=packet[19];
                        status_count=status_count+1;
                    end
                    8'h85: begin
                        require(packet[6]==2,"INPUTS diagnostic length");
                        require(seq_id==22+inputs_count,"INPUTS sequence echoes request");
                        last_raw_keys=packet[7];last_held_keys=packet[8];
                        inputs_count=inputs_count+1;
                    end
                    8'h83,8'h84: begin
                        if(allow_event_gaps) begin
                            if(seq_id!=expected_event_seq) event_gaps=event_gaps+1;
                        end else require(seq_id==expected_event_seq,"events share continuous sequence");
                        expected_event_seq=(seq_id+1)%65536;
                        if(packet[3]==8'h83) begin
                            require(packet[6]==6 && packet[11]<32 && packet[12]<2,"key event format");
                            if(!allow_event_gaps) require({packet[10],packet[9],packet[8],packet[7]}==key_tick[packet[11]],"key event preserves original commit sample through pipeline");
                            if(packet[12]) event_down[packet[11]]=1; else event_up[packet[11]]=1;
                            event_count=event_count+1;
                        end else begin
                            require(packet[6]==8,"parameter event format");
                            if(!allow_event_gaps) require({packet[10],packet[9],packet[8],packet[7]}==param_tick[param_count],"parameter event preserves original commit sample through pipeline");
                            case(param_count)
                                0:require({packet[14],packet[13],packet[12],packet[11]}==32'h02e0ffff,"parameter event returns max volume and negative bend");
                                1:require({packet[14],packet[13],packet[12],packet[11]}==32'h02e02000,"parameter event returns selected field update");
                                2:require({packet[14],packet[13],packet[12],packet[11]}==32'h02e02800,"parameter event returns physical relative update");
                            endcase
                            param_count=param_count+1;
                        end
                    end
                    default: require(0,"unknown TX packet");
                endcase
                packet_pos=0;packet_size=0;
            end
        end
    end
    initial begin
        for(i=0;i<256;i=i+1) ack_status[i]=-1;
        for(i=0;i<64;i=i+1) sent[i]=0;
        repeat(6) @(negedge clk);rst=0;
        require(volume==16384 && bend==65536 && preset==0 && held==0,"defaults");
        send_packet(8'h01,1,0,0);send_packet(8'h02,2,0,0);settle;
        require(hello_count==1 && status_count==1,"HELLO and STATUS serial responses");
        send_packet(8'h03,22,0,0);settle;
        require(inputs_count==1 && last_raw_keys==8'hff && last_held_keys==0,"INPUTS reports synchronized raw and debounced inputs");
        raw_keys=8'hfd;send_packet(8'h03,23,0,0);settle;
        require(inputs_count==2 && last_raw_keys==8'hfd && last_held_keys==0 && physical==0,"INPUTS exposes raw change without inventing debounce state");
        keys=2;send_packet(8'h03,24,0,0);settle;
        require(inputs_count==3 && last_raw_keys==8'hfd && last_held_keys==2 && physical==2,"INPUTS exposes debounce state separately");
        send_packet(8'h03,25,1,0);settle;
        require(inputs_count==3 && ack_status[25]==1 && physical==2,"INPUTS rejects payload and preserves note ownership");
        raw_keys=8'hff;keys=0;settle;
        sent[0]=8'h05;send_packet(8'h12,3,4,0);settle;
        require(held==5 && ack_status[3]==0,"valid notes apply and ACK");
        sent[0]=8'h80;send_packet(8'h12,4,4,1);repeat(300) @(negedge clk);
        require(held==5 && ack_status[4]==-1,"bad CRC cannot mutate notes or ACK");
        sent[0]=7;sent[1]=8'hff;sent[2]=8'hff;sent[3]=8'he0;sent[4]=2;
        send_packet(8'h13,5,5,0);settle;
        require(volume==65536 && bend==58386 && preset==2 && ack_status[5]==0,"signed bend and max volume");
        sent[0]=2;sent[3]=33;send_packet(8'h13,6,5,0);settle;
        require(bend==58386 && ack_status[6]==1,"out of range selected parameter rejected");
        sent[0]=1;sent[1]=0;sent[2]=8'h20;sent[3]=8'hff;sent[4]=8'hff;
        send_packet(8'h13,7,5,0);settle;
        require(volume==8192 && bend==58386 && preset==2,"unselected invalid fields ignored");
        // Pulse occurs between sample boundaries; it must survive until commit.
        @(negedge clk);vu=1;repeat(1) @(negedge clk);vu=0;
        repeat(100) @(negedge clk);require(volume==10240,"encoder pulse accumulated between samples");
        keys=8'hff;settle;
        require(physical==255 && (held&255)==255 && event_down[7:0]==255,"same-frame eight key events retained");
        // Notes stay owned by physical source after remote watchdog expires.
        repeat(34000) @(negedge clk);
        require(held==255 && physical==255,"watchdog leaves physical notes held");
        send_packet(8'h02,21,0,0);settle;
        require(last_status_remote==0,"parameter edits never refresh remote-note watchdog");
        sent[0]=8;sent[1]=9;sent[2]=10;sent[3]=11;sent[4]=12;sent[5]=13;sent[6]=14;sent[7]=15;
        send_packet(8'h11,8,8,0);settle;require(ack_status[8]==2,"mapping rejected while held");
        keys=0;settle;require(event_up[7:0]==255,"same-frame releases retained");
        send_packet(8'h11,9,8,0);settle;require(ack_status[9]==0,"mapping applied while idle");
        keys=3;settle;require(held==32'h300 && physical==32'h300,"physical mapping changes logical notes");
        sent[0]=0;sent[1]=0;sent[2]=1;sent[3]=0;send_packet(8'h12,10,4,0);settle;
        require(held==32'h10300,"physical and remote masks combine");
        send_packet(8'h02,11,0,0);settle;
        require(last_status_physical==32'h300 && last_status_remote==32'h10000,"STATUS returns independent sources");
        require(last_status_volume==10240 && last_status_bend==8'he0,"STATUS returns authoritative parameters");
        // Incomplete packet times out; a later packet must recover.
        send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(8'h12);
        repeat(24000) @(negedge clk);send_packet(8'h01,12,0,0);settle;
        require(hello_count==2,"partial packet timeout resynchronizes");
        sent[0]=8;send_packet(8'h13,13,5,0);settle;require(ack_status[13]==1,"reserved parameter field rejected");
        send_packet(8'h77,14,0,0);settle;require(ack_status[14]==3,"unsupported command response");
        require(param_count>=3,"applied parameter updates emitted");
        require(faults==0,"valid load causes no queue fault");
        // A command can be received while the sample clock is stopped, but
        // parameters and ACK remain uncommitted until the next sample.
        auto_samples=0;repeat(2) @(negedge clk);
        sent[0]=7;sent[1]=0;sent[2]=8'h20;sent[3]=4;sent[4]=1;
        send_packet(8'h13,15,5,0);repeat(20) @(negedge clk);
        require(volume==10240 && ack_status[15]==-1,"no parameter commit or ACK between samples");
        vu=1;bu=1;pn=1;@(posedge clk);#1;vu=0;bu=0;pn=0;commit_sample;
        require(volume==10240 && bend>65536 && preset==2,"physical edits win simultaneous remote parameter update");
        // Physical bend reset takes priority over a simultaneous step.
        br=1;bd=1;@(posedge clk);#1;br=0;bd=0;commit_sample;
        require(bend==65536,"physical bend reset wins same-frame direction pulse");
        auto_samples=1;settle;
        require(ack_status[15]==0,"ACK issued after tie commit");
        // Legacy full-state remains explicit, not a heartbeat.
        sent[0]=0;sent[1]=0;sent[2]=0;sent[3]=0;
        sent[4]=0;sent[5]=8'h40;sent[6]=32;sent[7]=0;
        send_packet(8'h10,16,8,0);settle;
        require(volume==16384 && bend==73562 && preset==0 && ack_status[16]==0,"legacy full state controls all fields");
        // Signed intermediate widths must cover a complete burst of physical
        // steps before a sample, without wrapping before saturation.
        auto_samples=0;repeat(2) @(negedge clk);
        vu=1;repeat(100) @(posedge clk);#1;vu=0;commit_sample;
        require(volume==65536,"large positive physical volume burst saturates without wrap");
        vd=1;repeat(100) @(posedge clk);#1;vd=0;commit_sample;
        require(volume==0,"large negative physical volume burst saturates without wrap");
        bd=1;repeat(100) @(posedge clk);#1;bd=0;commit_sample;
        require(bend==58386,"large negative physical bend burst saturates without wrap");
        bu=1;repeat(100) @(posedge clk);#1;bu=0;commit_sample;
        require(bend==73562,"large positive physical bend burst saturates without wrap");
        auto_samples=1;settle;
        // Framing-error byte in the header cannot become a command.
        rx=0;repeat(BIT_CYCLES*10) @(negedge clk);rx=1;repeat(30) @(negedge clk);
        send_packet(8'h01,17,0,0);settle;require(hello_count==3,"framing error discards and parser recovers");
        // Legal maximum payload is bounded and rejected by command length;
        // a length above64 is rejected immediately and sync scanning resumes.
        send_packet(8'h12,18,64,0);settle;require(ack_status[18]==1,"64byte packet checked then rejected without mutation");
        send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(8'h12);
        send_byte(19);send_byte(0);send_byte(65);
        send_packet(8'h01,20,0,0);settle;require(hello_count==4,"overlong packet resynchronizes");
        require(faults==0,"CRC, framing and invalid commands do not masquerade as queue overflow");
        // Fill bounded command queue plus prefetched head with sample_ce
        // stopped. Excess commands must expose overflow, not overwrite.
        auto_samples=0;repeat(2) @(negedge clk);
        for(seq_id=100;seq_id<110;seq_id=seq_id+1) send_packet(8'h02,seq_id,0,0);
        repeat(30) @(negedge clk);require(faults[1],"command receive overflow latched");
        auto_samples=1;settle;settle;
        // Generate physical changes faster than the UART can return them.
        // Fault latch remains visible even after congestion has drained.
        allow_event_gaps=1;
        for(seq_id=0;seq_id<12;seq_id=seq_id+1) begin
            keys=seq_id[0]?8'hff:0;repeat(64) @(negedge clk);
        end
        require(faults[2],"event queue overflow latched");
        repeat(80000) @(negedge clk);
        keys=0;settle;require(faults[2] && event_gaps>0,"overflow visible as latched fault and event sequence gap");
        audio_fault=1;repeat(3) @(negedge clk);audio_fault=0;repeat(3) @(negedge clk);
        require(faults[0],"audio fault latched");
        $display("PASS app bridge serial protocol, ownership, mapping, watchdog, parameters and events (%0d checks)",checks);
        $finish;
    end
    initial begin repeat(1000000) @(negedge clk);$display("FAIL app bridge timeout");$finish;end
endmodule
