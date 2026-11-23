`timescale 1ns/1ps
// Sample-boundary authority for physical controls and one protocol transport.
// Bounded command/response queues and a separately bounded event queue ensure
// that output congestion cannot silently lose input ownership or event history.
module synth_app_bridge #(
    parameter NUM_VOICES=4,parameter CLOCK_HZ=49152000,parameter BAUD=115200,
    parameter WATCHDOG_SAMPLES=48000, parameter TONE_CONTROL_ENABLED=0, parameter WAVE_CONTROL_ENABLED=0, parameter WAVE_RESET_MODE=0,
    parameter INDEPENDENT_CONTROL_ENABLED=0, parameter PERFORMANCE_ENABLED=0,
    parameter PERIPHERALS_ENABLED=0, parameter GUIDE_ENABLED=0,parameter MONO_ENABLED=0
)(
    input clk,input rst,input sample_ce,input uart_rx,output uart_tx,
    input [7:0] physical_keys,input [7:0] raw_keys,
    input vol_up,input vol_down,input bend_up,input bend_down,
    input bend_reset,input preset_next,
    input [5:0] active_voice_count,input audio_fault,
    output [31:0] held_keys,output [16:0] volume,output [16:0] bend,
    output reg [1:0] preset,output reg [7:0] faults,
    output reg [31:0] physical_mask,output reg [31:0] frame_counter,
    output reg [1:0] tone_mode, output reg [1:0] waveform_mode,
    output [16:0] osc2_bend,output reg [1:0] osc2_preset,
    output reg [31:0] osc1_gate_mask,output reg [31:0] osc2_gate_mask,
    output reg osc_override_enable,output reg [5:0] osc_override_id,
    output reg [31:0] osc_override_increment,
    input [7:0] performance_play_keys,
    input ui_commit_valid,input [2:0] ui_commit_field,input [7:0] ui_commit_value,
    input ui_settings_active,input [2:0] ui_selected_field,input [7:0] ui_preview_value,
    output reg [3:0] performance_root,output reg [1:0] performance_scale,
    output reg [2:0] performance_octave,output reg [2:0] performance_timbre,
    output reg [15:0] config_revision,output reg [39:0] performance_held,
    output reg [279:0] source_midi,output reg [639:0] source_instance,
    output [63:0] peripheral_request,output reg peripheral_commit,
    input peripheral_config_valid,input [111:0] peripheral_query,
    output reg [55:0] mapped_physical_midi,
    output reg guide_commit,input guide_config_valid,input [127:0] guide_query,
    output reg [7:0] phone_led_mask
);
    localparam PHONE_LED_ENABLED=GUIDE_ENABLED && PERIPHERALS_ENABLED && PERFORMANCE_ENABLED;
    localparam [15:0] START_VOLUME=PERFORMANCE_ENABLED ? 16'd39321 : 16'd16384;
    reg [5:0] phone_led_lease;
    wire phone_led_blocked=ui_settings_active || guide_query[0] || !guide_query[96];
    function integer timer_width;
        input integer value;integer v;
        begin v=value-1;timer_width=0;while(v>0) begin v=v>>1;timer_width=timer_width+1;end end
    endfunction
    localparam CMD_DEPTH=8,RESP_DEPTH=4,EVENT_DEPTH=32;
    localparam PACKET_TIMEOUT=CLOCK_HZ/50;
    wire [7:0] rx_byte;
    wire rx_valid,rx_error,tx_busy;
    reg [7:0] tx_byte;
    reg tx_send;
    synth_uart #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) uart(
        .clk(clk),.rst(rst),.rx(uart_rx),.tx(uart_tx),.rx_data(rx_byte),
        .rx_valid(rx_valid),.rx_error(rx_error),.tx_data(tx_byte),
        .tx_send(tx_send),.tx_busy(tx_busy));
    reg [31:0] remote_mask;
    reg [15:0] wire_volume;
    reg signed [7:0] wire_bend;
    reg signed [7:0] wire_bend_b;
    reg [4:0] key_map[0:7];
    wire [6:0] bend_index=wire_bend+8'd32;
    `include "bend_table.vh"
    assign held_keys=physical_mask|remote_mask;
    assign volume=(wire_volume==16'hffff)?17'd65536:{1'b0,wire_volume};
    assign bend=bend_factor(bend_index);
    wire [6:0] bend_b_index=wire_bend_b+8'd32;
    assign osc2_bend=bend_factor(bend_b_index);

    function [6:0] legacy_midi;
        input [4:0] key;
        begin case(key)
            0:legacy_midi=60;1:legacy_midi=62;2:legacy_midi=64;3:legacy_midi=65;
            4:legacy_midi=67;5:legacy_midi=69;6:legacy_midi=71;7:legacy_midi=72;
            default:legacy_midi=28+key;
        endcase end
    endfunction
    function [6:0] mapped_midi;
        input [2:0] key;input [3:0] tonic;input [1:0] scale_id;input [2:0] oct;
        reg [3:0] interval;
        begin
            if(scale_id==2) interval={1'b0,key};
            else case(key)
                0:interval=0;1:interval=2;2:interval=(scale_id==1)?3:4;3:interval=5;
                4:interval=7;5:interval=(scale_id==1)?8:9;6:interval=(scale_id==1)?10:11;
                default:interval=12;
            endcase
            mapped_midi=12*({1'b0,oct}+4'd1)+tonic+interval;
        end
    endfunction
    reg [2:0] panel_pending;
    reg [7:0] panel_value[0:2];
    reg [3:0] next_root;
    reg [1:0] next_scale;
    reg [2:0] next_timbre;
    reg [2:0] next_octave,panel_ready;
    reg [7:0] panel_selected_value;
    reg patch_commit,config_changed,manual_patch,native_on,legacy_remote_commit;
    reg [31:0] native_sources;
    reg [4:0] native_source;
    reg [6:0] native_pitch;
    reg [15:0] native_token;
    reg [39:0] next_sources;

    // Response payload size is immutable metadata of the wire type.
    // Decode after the response queue, away from sample-boundary validation.
    function [7:0] response_size;
        input [7:0] kind;
        begin case(kind)
            8'h81:response_size=13;
            8'h82,8'h89:response_size=18;
            8'h86,8'h87:response_size=1;
            8'h8a:response_size=5;
            8'h8b:response_size=10;
            8'h8c:response_size=14;
            8'h8d:response_size=16;
            default:response_size=2; // ACK, INPUTS, OSC2.
        endcase end
    endfunction

    function [15:0] crc_byte;
        input [15:0] initial_crc;input [7:0] value;
        integer b;reg [15:0] c;
        begin
            c=initial_crc^{value,8'b0};
            for(b=0;b<8;b=b+1) c=c[15]?(c<<1)^16'h1021:c<<1;
            crc_byte=c;
        end
    endfunction

    // Parser stores only the first eight payload bytes: every implemented
    // request fits there; longer legal packets are CRC checked then rejected.
    reg [3:0] parser_state;
    reg [7:0] parser_type,parser_length;
    reg [15:0] parser_seq,parser_crc;
    reg [7:0] parser_crc_low;
    reg [6:0] parser_index;
    reg [63:0] parser_payload;
    // Preserve the original full-width behavior for degenerate parameters.
    localparam PARSER_TIMER_WIDTH=(PACKET_TIMEOUT<2 || PACKET_TIMEOUT>=32'h80000000)?32:timer_width(PACKET_TIMEOUT);
    reg [PARSER_TIMER_WIDTH-1:0] parser_timer;
    reg [7:0] cmd_type[0:CMD_DEPTH-1],cmd_length[0:CMD_DEPTH-1];
    reg [15:0] cmd_seq[0:CMD_DEPTH-1];
    reg [63:0] cmd_payload[0:CMD_DEPTH-1];
    reg [2:0] cmd_read,cmd_write;
    reg [3:0] cmd_count;
    // Prefetch decouples the distributed-RAM read mux from parameter decode,
    // physical arithmetic and event detection at the audio sample boundary.
    reg head_valid;
    reg [7:0] head_type,head_length;
    reg [15:0] head_seq;
    reg [63:0] head_payload;
    assign peripheral_request=head_payload;
    // Native-source data is stable while this head waits: only this command
    // can write a remote token/MIDI word. Watchdog expiry changes held only.
    reg head_native_ready;
    reg [15:0] head_native_current,head_native_next;
    reg [6:0] head_native_midi;

    reg [7:0] resp_type[0:RESP_DEPTH-1];
    reg [15:0] resp_seq[0:RESP_DEPTH-1];
    reg [143:0] resp_payload[0:RESP_DEPTH-1];
    reg [1:0] resp_read,resp_write;
    reg [2:0] resp_count;
    reg [7:0] event_type[0:EVENT_DEPTH-1],event_length[0:EVENT_DEPTH-1];
    reg [15:0] event_seq[0:EVENT_DEPTH-1];
    reg [63:0] event_payload[0:EVENT_DEPTH-1];
    reg [4:0] event_read,event_write;
    reg [5:0] event_count;
    reg [15:0] next_event_seq;

    // At most eight mapped key transitions plus one parameter change are
    // staged in a sample. Drain one event per system clock, not eight memory
    // write ports. All events keep the original audio sample counter.
    reg [31:0] pending_key_events,pending_key_levels,event_frame;
    reg pending_param_event;
    reg [31:0] pending_params;
    reg signed [7:0] pending_volume_steps,pending_bend_steps;
    reg pending_bend_reset;
    reg [1:0] pending_preset_steps;
    localparam WATCHDOG_WIDTH=(WATCHDOG_SAMPLES<2 || WATCHDOG_SAMPLES>=32'h80000000)?32:timer_width(WATCHDOG_SAMPLES);
    reg [WATCHDOG_WIDTH-1:0] watchdog;
    // Event comparison happens one clock after the sample commit. This keeps
    // physical pulse arithmetic out of the high-fanout event-stage enables,
    // while the captured sample number keeps notification timing unchanged.
    reg capture_sample_pending;
    reg [31:0] capture_frame,last_event_physical;
    reg [15:0] last_event_volume;
    reg signed [7:0] last_event_bend;
    reg [1:0] last_event_preset;

    // Complete packet is serialized from a stable snapshot.
    reg packet_active;
    reg [7:0] out_type,out_length;
    reg [15:0] out_seq,out_crc;
    reg [143:0] out_payload;
    reg [6:0] out_index;

    // Working values make simultaneous enqueue/dequeue explicit; the queue
    // state registers have exactly one writer.
    integer cc,rc,ec,cr,cw,rr,rw,er,ew;
    integer k,chosen;
    // Bounds: +/-127 pending steps plus one pulse, volume0..65535 plus
    // +/-127*2048, bend+/-32 plus +/-127 steps, preset0..2 plus0..2.
    reg signed [8:0] vs,bs,new_bend;
    reg [2:0] ps,new_preset;
    reg signed [19:0] new_vol;
    reg [31:0] mapped,new_remote;
    reg [7:0] request,status,field_mask,response_type;
    reg [15:0] sequence_id;
    reg [63:0] payload;
    reg [143:0] response_data;
    reg refresh,reset_bend;
    reg [7:0] next_byte;

    always @(posedge clk) begin
        if(rst) begin
            peripheral_commit<=0;
            guide_commit<=0;
            phone_led_mask<=0;phone_led_lease<=0;
            mapped_physical_midi<={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
            performance_root<=0;performance_scale<=0;performance_octave<=4;
            performance_timbre<=(PERFORMANCE_ENABLED && WAVE_RESET_MODE!=0)?3:0;
            config_revision<=0;performance_held<=0;source_midi<=0;source_instance<=0;
            panel_pending<=0;panel_value[0]<=0;panel_value[1]<=0;panel_value[2]<=4;
            native_sources<=0;
            remote_mask<=0;wire_volume<=START_VOLUME;wire_bend<=0;preset<=0;tone_mode<=0;waveform_mode<=WAVE_RESET_MODE[1:0];
            wire_bend_b<=PERFORMANCE_ENABLED?0:2;osc2_preset<=PERFORMANCE_ENABLED?2:1;osc1_gate_mask<=32'hffffffff;osc2_gate_mask<=32'hffffffff;
            if(PERFORMANCE_ENABLED) preset<=2;
            osc_override_enable<=0;osc_override_id<=0;osc_override_increment<=0;
            physical_mask<=0;frame_counter<=0;faults<=0;watchdog<=0;
            parser_state<=0;parser_type<=0;parser_length<=0;parser_seq<=0;
            parser_crc<=16'hffff;parser_crc_low<=0;parser_index<=0;
            parser_payload<=0;parser_timer<=0;
            cmd_read<=0;cmd_write<=0;cmd_count<=0;
            head_valid<=0;head_type<=0;head_length<=0;head_seq<=0;head_payload<=0;
            head_native_ready<=0;head_native_current<=0;head_native_next<=0;head_native_midi<=0;
            resp_read<=0;resp_write<=0;resp_count<=0;
            event_read<=0;event_write<=0;event_count<=0;next_event_seq<=0;
            pending_key_events<=0;pending_key_levels<=0;event_frame<=0;
            pending_param_event<=0;pending_params<=0;
            pending_volume_steps<=0;pending_bend_steps<=0;
            pending_bend_reset<=0;pending_preset_steps<=0;
            capture_sample_pending<=0;capture_frame<=0;last_event_physical<=0;
            last_event_volume<=START_VOLUME;last_event_bend<=0;last_event_preset<=0;
            packet_active<=0;out_type<=0;out_length<=0;out_seq<=0;
            out_crc<=16'hffff;out_payload<=0;out_index<=0;tx_byte<=0;tx_send<=0;
            for(k=0;k<8;k=k+1) key_map[k]<=k;
        end else begin
            peripheral_commit<=0;
            guide_commit<=0;
            if(PHONE_LED_ENABLED)begin
                if(phone_led_blocked)begin phone_led_mask<=0;phone_led_lease<=0;end
                else if(sample_ce && frame_counter[9:0]==0 && phone_led_lease!=0)begin
                    phone_led_lease<=phone_led_lease-1'b1;
                    if(phone_led_lease==1)phone_led_mask<=0;
                end
            end
            cc=cmd_count;cr=cmd_read;cw=cmd_write;
            rc=resp_count;rr=resp_read;rw=resp_write;
            ec=event_count;er=event_read;ew=event_write;
            tx_send<=0;
            capture_sample_pending<=sample_ce;
            if(PERFORMANCE_ENABLED && ui_commit_valid && ui_commit_field<3) begin
                panel_pending[ui_commit_field]<=1;
                panel_value[ui_commit_field]<=ui_commit_value;
            end
            if(audio_fault) faults[0]<=1;
            if(!head_valid && cmd_count!=0) begin
                head_type<=cmd_type[cr];head_length<=cmd_length[cr];
                head_seq<=cmd_seq[cr];head_payload<=cmd_payload[cr];
                head_valid<=1;head_native_ready<=0;cr=(cr+1)%CMD_DEPTH;cc=cc-1;
            end
            if(PERFORMANCE_ENABLED && head_valid && head_type==8'h21 && !head_native_ready) begin
                // Compute both words from the same committed source state,
                // never from a current-value register being assigned by NBA.
                head_native_current<=source_instance[(head_payload[4:0]+8)*16+:16];
                head_native_next<=source_instance[(head_payload[4:0]+8)*16+:16]+16'd1;
                head_native_midi<=source_midi[(head_payload[4:0]+8)*7+:7];
                head_native_ready<=1;
            end

            // Physical pulses can arrive on any system clock. Reset has
            // priority over bend steps in the same sample, matching the knob.
            vs=$signed(pending_volume_steps)+(vol_up?9'sd1:9'sd0)-(vol_down?9'sd1:9'sd0);
            bs=$signed(pending_bend_steps)+(bend_up?9'sd1:9'sd0)-(bend_down?9'sd1:9'sd0);
            ps={1'b0,pending_preset_steps}+(preset_next?3'd1:3'd0);
            if(ps>=3'd3) ps=ps-3'd3;
            reset_bend=pending_bend_reset|bend_reset;
            if(vs>9'sd127) begin vs=9'sd127;faults[1]<=1;end
            if(vs< -9'sd127) begin vs=-9'sd127;faults[1]<=1;end
            if(bs>9'sd127) begin bs=9'sd127;faults[1]<=1;end
            if(bs< -9'sd127) begin bs=-9'sd127;faults[1]<=1;end
            pending_volume_steps<=vs;pending_bend_steps<=bs;
            pending_bend_reset<=reset_bend;pending_preset_steps<=ps;

            if(parser_state!=0) begin
                if(parser_timer>=PACKET_TIMEOUT-1) begin parser_state<=0;parser_timer<=0;end
                else parser_timer<=parser_timer+1'b1;
            end else parser_timer<=0;
            if(rx_error) begin parser_state<=0;parser_timer<=0;end
            if(rx_valid) begin
                parser_timer<=0;
                case(parser_state)
                    0: if(rx_byte==8'ha5) parser_state<=1;
                    1: if(rx_byte==8'h5a) begin parser_state<=2;parser_payload<=0;end
                       else if(rx_byte!=8'ha5) parser_state<=0;
                    2: if(rx_byte==1) begin parser_crc<=crc_byte(16'hffff,rx_byte);parser_state<=3;end
                       else parser_state<=(rx_byte==8'ha5)?1:0;
                    3: begin parser_type<=rx_byte;parser_crc<=crc_byte(parser_crc,rx_byte);parser_state<=4;end
                    4: begin parser_seq[7:0]<=rx_byte;parser_crc<=crc_byte(parser_crc,rx_byte);parser_state<=5;end
                    5: begin parser_seq[15:8]<=rx_byte;parser_crc<=crc_byte(parser_crc,rx_byte);parser_state<=6;end
                    6: begin
                        parser_length<=rx_byte;parser_index<=0;
                        parser_crc<=crc_byte(parser_crc,rx_byte);
                        if(rx_byte>64) parser_state<=0;
                        else parser_state<=(rx_byte==0)?8:7;
                    end
                    7: begin
                        if(parser_index<8) parser_payload[parser_index*8+:8]<=rx_byte;
                        parser_crc<=crc_byte(parser_crc,rx_byte);
                        if(parser_index+1==parser_length) parser_state<=8;
                        else parser_index<=parser_index+1'b1;
                    end
                    8: begin parser_crc_low<=rx_byte;parser_state<=9;end
                    9: begin
                        parser_state<=0;
                        if({rx_byte,parser_crc_low}==parser_crc) begin
                            if(cc<CMD_DEPTH) begin
                                cmd_type[cw]<=parser_type;cmd_length[cw]<=parser_length;
                                cmd_seq[cw]<=parser_seq;cmd_payload[cw]<=parser_payload;
                                cw=(cw+1)%CMD_DEPTH;cc=cc+1;
                            end else faults[1]<=1;
                        end
                    end
                    default: parser_state<=0;
                endcase
            end

            // Snapshot response has priority whenever the serializer becomes
            // idle. Once a frame starts, it is never interleaved with another.
            if(!packet_active) begin
                if(rc!=0) begin
                    packet_active<=1;out_type<=resp_type[rr];out_length<=response_size(resp_type[rr]);
                    out_seq<=resp_seq[rr];out_payload<=resp_payload[rr];
                    out_crc<=16'hffff;out_index<=0;rr=(rr+1)%RESP_DEPTH;rc=rc-1;
                end else if(ec!=0) begin
                    packet_active<=1;out_type<=event_type[er];out_length<=event_length[er];
                    out_seq<=event_seq[er];out_payload<={80'b0,event_payload[er]};
                    out_crc<=16'hffff;out_index<=0;er=(er+1)%EVENT_DEPTH;ec=ec-1;
                end
            end else if(!tx_busy && !tx_send) begin
                case(out_index)
                    0: next_byte=8'ha5;
                    1: next_byte=8'h5a;
                    2: next_byte=1;
                    3: next_byte=out_type;
                    4: next_byte=out_seq[7:0];
                    5: next_byte=out_seq[15:8];
                    6: next_byte=out_length;
                    default: begin
                        if(out_index<7+out_length) next_byte=out_payload[(out_index-7)*8+:8];
                        else if(out_index==7+out_length) next_byte=out_crc[7:0];
                        else next_byte=out_crc[15:8];
                    end
                endcase
                tx_byte<=next_byte;tx_send<=1;
                if(out_index>=2 && out_index<7+out_length) out_crc<=crc_byte(out_crc,next_byte);
                if(out_index==8+out_length) packet_active<=0;
                else out_index<=out_index+1'b1;
            end

            // Drain staged physical or parameter events, with one sequence
            // allocation even when dropping a full queue (gap plus fault).
            if(pending_key_events!=0 || pending_param_event) begin
                if(ec<EVENT_DEPTH) begin
                    event_seq[ew]<=next_event_seq;
                    if(pending_key_events!=0) begin
                        chosen=0;
                        for(k=31;k>=0;k=k-1) if(pending_key_events[k]) chosen=k;
                        event_type[ew]<=8'h83;event_length[ew]<=6;
                        event_payload[ew]<={16'b0,7'b0,pending_key_levels[chosen],3'b0,chosen[4:0],event_frame};
                        pending_key_events[chosen]<=0;
                    end else begin
                        event_type[ew]<=8'h84;event_length[ew]<=8;
                        event_payload[ew]<={pending_params,event_frame};pending_param_event<=0;
                    end
                    ew=(ew+1)%EVENT_DEPTH;ec=ec+1;
                end else begin
                    faults[2]<=1;
                    if(pending_key_events!=0) begin
                        chosen=0;for(k=31;k>=0;k=k-1) if(pending_key_events[k]) chosen=k;
                        pending_key_events[chosen]<=0;
                    end else pending_param_event<=0;
                end
                next_event_seq<=next_event_seq+1'b1;
            end

            if(capture_sample_pending) begin
                if(physical_mask!=last_event_physical || wire_volume!=last_event_volume ||
                   wire_bend!=last_event_bend || preset!=last_event_preset) begin
                    if(pending_key_events!=0 || pending_param_event) faults[2]<=1;
                    else begin
                        pending_key_events<=physical_mask^last_event_physical;
                        pending_key_levels<=physical_mask;event_frame<=capture_frame;
                        if(wire_volume!=last_event_volume || wire_bend!=last_event_bend || preset!=last_event_preset) begin
                            pending_params<={6'b0,preset,wire_bend,wire_volume};pending_param_event<=1;
                        end
                    end
                end
                last_event_physical<=physical_mask;last_event_volume<=wire_volume;
                last_event_bend<=wire_bend;last_event_preset<=preset;
            end

            if(sample_ce) begin
                frame_counter<=frame_counter+1'b1;
                capture_frame<=frame_counter+1'b1;
                mapped=0;
                for(k=0;k<8;k=k+1) if(physical_keys[k]) mapped[key_map[k]]=1;
                new_remote=remote_mask;refresh=0;
                new_vol=wire_volume;new_bend=$signed(wire_bend);new_preset=preset;
                next_root=performance_root;next_scale=performance_scale;
                next_octave=performance_octave;next_timbre=performance_timbre;
                patch_commit=0;config_changed=0;manual_patch=0;native_on=0;legacy_remote_commit=0;
                native_source=0;native_pitch=0;native_token=0;
                if(PERFORMANCE_ENABLED) mapped={24'b0,performance_play_keys};
                if(remote_mask!=0) begin
                    if(watchdog>=WATCHDOG_SAMPLES-1) begin new_remote=0;watchdog<=0;end
                    else watchdog<=watchdog+1'b1;
                end else watchdog<=0;

                // Reserve a response before applying a command: ACK is never
                // lost after a mutation. RX may continue filling its own queue.
                if(head_valid && rc<RESP_DEPTH &&
                    (!PERFORMANCE_ENABLED || head_type!=8'h21 || head_native_ready)) begin
                    request=head_type;sequence_id=head_seq;payload=head_payload;
                    status=0;response_type=8'h80;response_data=0;
                    case(request)
                        8'h01: begin
                            if(head_length!=0) status=1;
                            else begin
                                response_type=8'h81;
                                response_data[7:0]=1;response_data[15:8]=NUM_VOICES;
                                response_data[23:16]=8'h0f | (WAVE_CONTROL_ENABLED?8'h10:8'h00) |
                                    (TONE_CONTROL_ENABLED?8'h20:8'h00) | (INDEPENDENT_CONTROL_ENABLED?8'h40:8'h00) |
                                    (PERFORMANCE_ENABLED?8'h80:8'h00);
                                response_data[55:24]=48000;
                                response_data[87:56]=32'hffffffff;
                                response_data[103:88]=PHONE_LED_ENABLED ? 16'h0102 : 16'h0101;
                            end
                        end
                        8'h02: begin
                            if(head_length!=0) status=1;
                            else begin response_type=8'h82;end
                        end
                        8'h06: begin
                            if(!INDEPENDENT_CONTROL_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin
                                response_type=8'h88;
                                response_data[15:0]={6'b0,osc2_preset,wire_bend_b};
                            end
                        end
                        // Independent tone query; v1 STATUS remains unchanged.
                        8'h05: begin
                            if(!WAVE_CONTROL_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin
                                response_type=8'h87;
                                response_data[7:0]={6'b0,waveform_mode};
                            end
                        end
                        8'h04: begin
                            if(!TONE_CONTROL_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin
                                response_type=8'h86;
                                response_data[7:0]={6'b0,tone_mode};
                            end
                        end
                        8'h03: begin
                            if(head_length!=0) status=1;
                            else begin
                                response_type=8'h85;
                                response_data[15:0]={physical_keys,raw_keys};
                            end
                        end
                        8'h10: begin
                            if(head_length!=8 || $signed(payload[55:48])< -32 || $signed(payload[55:48])>32 || payload[63:56]>2) status=1;
                            else begin
                                new_remote=payload[31:0];new_vol=payload[47:32];
                                new_bend=$signed(payload[55:48]);new_preset=payload[63:56];refresh=1;
                                manual_patch=1;
                                legacy_remote_commit=1;
                            end
                        end
                        8'h12: begin
                            if(head_length!=4) status=1;
                            else begin new_remote=payload[31:0];refresh=1;legacy_remote_commit=1;end
                        end
                        8'h13: begin
                            field_mask=payload[7:0];
                            if(head_length!=5 || field_mask==0 || field_mask>7 ||
                               (field_mask[1] && ($signed(payload[31:24])< -32 || $signed(payload[31:24])>32)) ||
                               (field_mask[2] && payload[39:32]>2)) status=1;
                            else begin
                                if(field_mask[0]) new_vol=payload[23:8];
                                if(field_mask[1]) new_bend=$signed(payload[31:24]);
                                if(field_mask[2]) begin new_preset=payload[39:32];manual_patch=1;end
                            end
                        end
                        8'h16: begin
                            if(!INDEPENDENT_CONTROL_ENABLED) status=3;
                            else if(head_length!=2 || $signed(payload[7:0])< -32 ||
                                    $signed(payload[7:0])>32 || payload[15:8]>2) status=1;
                            else begin wire_bend_b<=payload[7:0];osc2_preset<=payload[9:8];manual_patch=1;end
                        end
                        8'h17: begin
                            if(!INDEPENDENT_CONTROL_ENABLED) status=3;
                            else if(head_length!=6 || payload[7:0]>63 || payload[4:0]>=NUM_VOICES || payload[15:8]>3 ||
                                (payload[15:8]==1 && (payload[47:16]==0 || payload[47:16]>=32'h80000000))) status=1;
                            else case(payload[15:8])
                                0: begin osc_override_enable<=0;osc1_gate_mask<=32'hffffffff;osc2_gate_mask<=32'hffffffff;end
                                1: begin osc_override_enable<=1;osc_override_id<=payload[5:0];osc_override_increment<=payload[47:16];end
                                2: if(payload[5]) osc2_gate_mask[payload[4:0]]<=0;else osc1_gate_mask[payload[4:0]]<=0;
                                3: if(payload[5]) osc2_gate_mask[payload[4:0]]<=1;else osc1_gate_mask[payload[4:0]]<=1;
                            endcase
                        end
                        // Tone update is CRC checked, ACKed and applied only at sample_ce.
                        8'h15: begin
                            if(!WAVE_CONTROL_ENABLED) status=3;
                            else if(head_length!=1 || payload[7:0]>3) status=1;
                            else begin waveform_mode<=payload[1:0];manual_patch=1;end
                        end
                        8'h14: begin
                            if(!TONE_CONTROL_ENABLED) status=3;
                            else if(head_length!=1 || payload[7:0]>3) status=1;
                            else begin tone_mode<=payload[1:0];manual_patch=1;end
                        end
                        8'h11: begin
                            if(PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=8) status=1;
                            else begin
                                for(k=0;k<8;k=k+1) if(payload[k*8+:8]>31) status=1;
                                if(status==0) begin
                                    if(physical_keys!=0 || remote_mask!=0) status=2;
                                    else for(k=0;k<8;k=k+1) key_map[k]<=payload[k*8+:5];
                                end
                            end
                        end
                        8'h20: begin
                            if(!PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=4 || payload[7:0]>11 || payload[15:8]>2 ||
                                payload[23:16]<2 || payload[23:16]>6 ||
                                (payload[31:24]>2 && !(MONO_ENABLED && payload[31:24]==4))) status=1;
                            else begin
                                next_root=payload[3:0];next_scale=payload[9:8];
                                next_octave=payload[18:16];next_timbre=payload[26:24];
                                patch_commit=1;config_changed=1;
                            end
                        end
                        8'h21: begin
                            if(!PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=6 || payload[7:0]>31 || payload[15:8]>2 ||
                                payload[23:16]>127 || payload[31:24]!=0) status=1;
                            else begin
                                native_source=payload[4:0];native_pitch=payload[22:16];native_token=payload[47:32];
                                if(payload[15:8]==1) begin
                                    if(native_token != head_native_next) status=2;
                                    else begin new_remote[native_source]=1;native_on=1;refresh=1;end
                                end else if(payload[15:8]==0) begin
                                    if(native_token!=head_native_current) status=2;
                                    else begin new_remote[native_source]=0;refresh=1;end
                                end
                                if(status==0) begin response_type=8'h8a;end
                            end
                        end
                        8'h24: begin
                            if(!PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin response_type=8'h89;end
                        end
                        8'h22: begin
                            if(!PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else refresh=1;
                        end
                        8'h25: begin
                            if(!PERFORMANCE_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin response_type=8'h8b;end
                        end
                        8'h26: begin
                            if(!PERIPHERALS_ENABLED) status=3;
                            else if(head_length!=8 || !peripheral_config_valid) status=1;
                            else peripheral_commit<=1;
                        end
                        8'h27: begin
                            if(!PERIPHERALS_ENABLED) status=3;
                            else if(head_length!=1 || payload[7:0]>2) status=1;
                            else begin response_type=8'h8c;response_data[111:0]=peripheral_query;end
                        end
                        8'h28: begin
                            if(!GUIDE_ENABLED) status=3;
                            else if(head_length!=4 || !guide_config_valid) status=1;
                            else guide_commit<=1;
                        end
                        8'h29: begin
                            if(!GUIDE_ENABLED) status=3;
                            else if(head_length!=0) status=1;
                            else begin response_type=8'h8d;response_data[127:0]=guide_query;end
                        end
                        8'h2a: begin
                            if(!PHONE_LED_ENABLED) status=3;
                            else if(head_length!=3) status=1;
                            else if(payload[7:0]!=0 && (phone_led_blocked || payload[23:8]!=config_revision)) status=2;
                            else begin
                                phone_led_mask<=payload[7:0];
                                phone_led_lease<=payload[7:0]==0 ? 6'd0 : 6'd48;
                            end
                        end
                        default: status=3;
                    endcase
                    head_valid<=0;head_native_ready<=0;
                    // Save response after the authoritative physical edits below.
                end else begin request=0;response_type=0;end

                if(PERFORMANCE_ENABLED) begin
                    // Keep independent pending fields: a menu confirmation must
                    // not erase an earlier timbre proposal awaiting its frame.
                    panel_ready=panel_pending;
                    if(ui_commit_valid && ui_commit_field<3) panel_ready[ui_commit_field]=1;
                    for(k=0;k<3;k=k+1) if(panel_ready[k]) begin
                        panel_selected_value=(ui_commit_valid && ui_commit_field==k)?ui_commit_value:panel_value[k];
                        case(k)
                            0: if(panel_selected_value<3 || (MONO_ENABLED && panel_selected_value==4)) begin next_timbre=panel_selected_value[2:0];patch_commit=1;config_changed=1;end
                            1: if(panel_selected_value<24) begin
                                next_scale=(panel_selected_value>=12)?1:0;
                                next_root=(panel_selected_value>=12)?panel_selected_value-12:panel_selected_value;
                                config_changed=1;
                            end
                            2: if(panel_selected_value>=2 && panel_selected_value<=6) begin next_octave=panel_selected_value[2:0];config_changed=1;end
                        endcase
                    end
                    panel_pending<=0;
                    if(patch_commit) begin
                        case(next_timbre)
                            0: begin waveform_mode<=0;tone_mode<=0;new_preset=2;osc2_preset<=2;wire_bend_b<=0;end
                            1: begin waveform_mode<=1;tone_mode<=1;new_preset=1;osc2_preset<=1;wire_bend_b<=2;end
                            2: begin waveform_mode<=3;tone_mode<=2;new_preset=0;osc2_preset<=2;wire_bend_b<=-8'sd2;end
                            4: begin waveform_mode<=3;tone_mode<=1;new_preset=2;osc2_preset<=2;wire_bend_b<=0;end
                        endcase
                        osc_override_enable<=0;osc1_gate_mask<=32'hffffffff;osc2_gate_mask<=32'hffffffff;
                    end else if(manual_patch) begin next_timbre=3;config_changed=1;end
                    performance_root<=next_root;performance_scale<=next_scale;
                    performance_octave<=next_octave;performance_timbre<=next_timbre;
                    if(config_changed)begin
                        config_revision<=config_revision+16'd1;
                        phone_led_mask<=0;phone_led_lease<=0;
                        if(request==8'h2a && status==0 && payload[7:0]!=0)status=2;
                    end
                    next_sources={new_remote,performance_play_keys};
                    performance_held<=next_sources;
                    if(legacy_remote_commit) native_sources<=0;
                    else if(native_on) native_sources<=(native_sources & new_remote) | (32'b1<<native_source);
                    else native_sources<=native_sources & new_remote;
                    for(k=0;k<40;k=k+1) begin
                        if(k<8) begin
                            mapped_physical_midi[k*7+:7]<=mapped_midi(k,next_root,next_scale,next_octave);
                            if(next_sources[k] && !performance_held[k]) begin
                                source_midi[k*7+:7]<=mapped_midi(k,next_root,next_scale,next_octave);
                                source_instance[k*16+:16]<=source_instance[k*16+:16]+16'd1;
                            end
                        end else if(native_on && k==native_source+8) begin
                            source_midi[k*7+:7]<=native_pitch;source_instance[k*16+:16]<=native_token;
                        end else if(next_sources[k] && (!performance_held[k] || (legacy_remote_commit && native_sources[k-8]))) begin
                            source_midi[k*7+:7]<=legacy_midi(k-8);
                            source_instance[k*16+:16]<=source_instance[k*16+:16]+16'd1;
                        end
                    end
                end

                new_vol=new_vol+$signed({vs,11'b0});
                if(new_vol>20'sd65535) new_vol=20'sd65535;
                if(new_vol<20'sd0) new_vol=20'sd0;
                if(reset_bend) new_bend=0;
                else new_bend=new_bend+bs;
                if(new_bend>9'sd32) new_bend=9'sd32;
                if(new_bend< -9'sd32) new_bend=-9'sd32;
                new_preset=new_preset+ps;
                if(new_preset>=3'd3) new_preset=new_preset-3'd3;
                wire_volume<=new_vol;wire_bend<=new_bend;preset<=new_preset;
                remote_mask<=new_remote;physical_mask<=mapped;
                if(refresh) watchdog<=0;
                pending_volume_steps<=0;pending_bend_steps<=0;pending_bend_reset<=0;pending_preset_steps<=0;

                if(response_type!=0) begin
                    if(response_type==8'h80) response_data[15:0]={status,request};
                    if(response_type==8'h82) begin
                        response_data[7:0]={2'b0,active_voice_count};response_data[15:8]=faults;
                        response_data[47:16]=new_remote;response_data[79:48]=mapped;
                        response_data[95:80]=new_vol;response_data[103:96]=new_bend;
                        response_data[111:104]=new_preset;response_data[143:112]=frame_counter+1'b1;
                    end
                    if(response_type==8'h89) begin
                        response_data[7:0]={4'b0,next_root};response_data[15:8]={6'b0,next_scale};
                        response_data[23:16]={5'b0,next_octave};response_data[31:24]={5'b0,next_timbre};
                        response_data[39:32]={5'b0,(MONO_ENABLED!=0),(patch_commit?1'b0:osc_override_enable),ui_settings_active};
                        response_data[47:40]={5'b0,ui_selected_field};response_data[55:48]=ui_preview_value;
                        response_data[63:56]=performance_play_keys;response_data[71:64]=physical_keys;
                        response_data[79:72]={2'b0,active_voice_count};
                        response_data[95:80]=config_revision+(config_changed?16'd1:16'd0);
                        response_data[127:96]=frame_counter+1'b1;
                        response_data[143:128]=0; // No ADC/LED/HDMI is advertised before implementation.
                    end
                    if(response_type==8'h8b) begin
                        response_data[15:0]=config_revision+(config_changed?16'd1:16'd0);
                        for(k=0;k<8;k=k+1) response_data[16+k*8+:8]={1'b0,mapped_midi(k,next_root,next_scale,next_octave)};
                    end
                    if(response_type==8'h8a) begin
                        response_data[7:0]={3'b0,native_source};response_data[15:8]={7'b0,new_remote[native_source]};
                        response_data[23:16]={1'b0,native_on?native_pitch:head_native_midi};
                        response_data[39:24]=native_on?native_token:head_native_current;
                    end
                    resp_type[rw]<=response_type;
                    resp_seq[rw]<=sequence_id;resp_payload[rw]<=response_data;
                    rw=(rw+1)%RESP_DEPTH;rc=rc+1;
                end
            end
            cmd_count<=cc;cmd_read<=cr;cmd_write<=cw;
            resp_count<=rc;resp_read<=rr;resp_write<=rw;
            event_count<=ec;event_read<=er;event_write<=ew;
        end
    end
endmodule
