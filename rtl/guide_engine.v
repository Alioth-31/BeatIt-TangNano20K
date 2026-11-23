`timescale 1ns/1ps
// Offline fixed-tempo practice. This module never emits note-on/audio events.
// mapped_midi is the authoritative current eight-key layout (unique pitches);
// played_midi is each physical source's latched pitch, including held old notes.
module guide_engine #(parameter integer SAMPLE_HZ=48000,parameter CONTROL_ENABLED=0)(
    input clk,input rst,input sample_ce,input enable,input settings_active,
    input toggle,input rewind,input song_select,input [1:0] tempo,
    input [55:0] mapped_midi,input [55:0] played_midi,input [7:0] play_keys,
    input monophonic,input led_available,input [2:0] selected_field,
    output reg [7:0] led_target,output [7:0] target_keys,
    output reg running,output reg ready,output reg compatible,output reg done,
    output reg [3:0] step,output reg [7:0] missed,output reg [7:0] wrong,
    output reg [2:0] blocked_reason,input run_set,input run_value
);
    function integer clog2;input integer n;integer v;begin v=n-1;clog2=0;while(v>0)begin v=v>>1;clog2=clog2+1;end if(clog2<1)clog2=1;end endfunction
    localparam COUNT_W=clog2(SAMPLE_HZ/4+1);
    reg initialized,cfg_song,cfg_mono;
    reg [1:0] cfg_tempo;reg [55:0] cfg_map;
    reg validating,bad;reg [2:0] bad_reason;
    reg [3:0] check_index;
    reg [7:0] masks[0:15];
    reg [5:0] event_tick;
    reg [COUNT_W-1:0] sample_count,blink_count;
    reg blink,good_seen,wrong_seen,pending_toggle,pending_rewind;
    reg [7:0] previous_keys,pending_on,event_on;
    wire [7:0] new_on=play_keys&~previous_keys;
    wire [7:0] frame_on=pending_on|new_on;
    wire config_changed=!initialized || song_select!=cfg_song || mapped_midi!=cfg_map || monophonic!=cfg_mono;
    wire [3:0] rom_address=validating ? check_index : step;
    wire [34:0] event_word;wire [4:0] song_length;
    guide_song_rom table_rom(cfg_song,rom_address,event_word,song_length);
    wire [5:0] duration=event_word[34:29],gate_ticks=event_word[28:23];
    wire [1:0] note_count=event_word[22:21];
    reg [7:0] mapped_target;reg [2:0] found;
    wire [7:0] boundary_on,judged_keys;
    reg pitch_wrong;integer k;
    always @* begin
        mapped_target=0;found=0;pitch_wrong=0;
        for(k=0;k<8;k=k+1)begin
            if(note_count>0&&cfg_map[k*7+:7]==event_word[6:0])begin mapped_target[k]=1;found[0]=1;end
            if(note_count>1&&cfg_map[k*7+:7]==event_word[13:7])begin mapped_target[k]=1;found[1]=1;end
            if(note_count>2&&cfg_map[k*7+:7]==event_word[20:14])begin mapped_target[k]=1;found[2]=1;end
            if(judged_keys[k]&&target_keys[k]&&played_midi[k*7+:7]!=cfg_map[k*7+:7])pitch_wrong=1;
        end
    end
    wire unmapped=(note_count>0&&!found[0])||(note_count>1&&!found[1])||(note_count>2&&!found[2]);
    wire mono_conflict=cfg_mono&&note_count>1;
    wire perfect=judged_keys==target_keys&&!pitch_wrong &&
        (((event_on|(frame_on&~boundary_on))&target_keys)==target_keys);
    wire wrong_now=|(judged_keys&~target_keys)||pitch_wrong;
    reg [COUNT_W-1:0] tick_period;
    always @* case(cfg_tempo)
        0:tick_period=SAMPLE_HZ/4; // 60 BPM, four subdivisions/quarter
        1:tick_period=SAMPLE_HZ/6; // 90 BPM
        2:tick_period=SAMPLE_HZ/8; // 120 BPM
        3:tick_period=SAMPLE_HZ/10; // 150 BPM
    endcase
    wire tick_end=sample_count==tick_period-1'b1;
    wire step_end=tick_end&&event_tick==duration-1'b1;
    wire gate_end=tick_end&&gate_ticks!=0&&event_tick==gate_ticks-1'b1;
    wire toggle_now=pending_toggle^toggle;
    wire absolute_run=CONTROL_ENABLED&&run_set;
    wire run_change=absolute_run ? (run_value!=running || (done&&run_value)) : toggle_now;
    wire rewind_now=pending_rewind|rewind;
    wire [7:0] current_mask=masks[step];
    wire [7:0] next_mask=(step+5'd1<song_length) ? masks[step+4'd1] : 8'd0;
    // The exact transition sample may contain the next note's onset. Give it
    // to that event once; do not also penalize the preceding rest/held note.
    assign boundary_on=step_end ? frame_on&next_mask : 8'd0;
    assign judged_keys=play_keys&~boundary_on;
    wire preview=event_tick==duration-1'b1 &&
        (sample_count<tick_period/4 || (sample_count>=tick_period/2&&sample_count<(tick_period*3)/4));
    assign target_keys=(enable&&ready&&compatible&&!done&&event_tick<gate_ticks) ? current_mask : 8'd0;
    always @* begin
        blocked_reason=0;led_target=0;
        if(!ready)blocked_reason=1;
        else if(!compatible)blocked_reason=bad_reason;
        else if(!led_available)blocked_reason=4;
        else if(settings_active)blocked_reason=5;
        if(settings_active)led_target=8'b1<<selected_field;
        else if(!enable)led_target=play_keys;
        else if(ready&&compatible&&led_available&&!done)begin
            if(running)led_target=target_keys | (preview ? next_mask&~current_mask : 8'd0);
            else led_target=blink ? (current_mask==0 ? 8'hff : current_mask) : 8'd0;
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            initialized<=0;cfg_song<=0;cfg_mono<=0;cfg_tempo<=2;cfg_map<=0;
            validating<=0;bad<=0;bad_reason<=0;check_index<=0;
            running<=0;ready<=0;compatible<=0;done<=0;step<=0;event_tick<=0;sample_count<=0;
            missed<=0;wrong<=0;good_seen<=0;wrong_seen<=0;
            blink_count<=0;blink<=1;pending_toggle<=0;pending_rewind<=0;
            previous_keys<=0;pending_on<=0;event_on<=0;
        end else begin
            previous_keys<=play_keys;pending_on<=pending_on|new_on;
            if(!running||!enable||settings_active||!led_available)pending_on<=0;
            pending_toggle<=pending_toggle^toggle;pending_rewind<=pending_rewind|rewind;
            if(!enable||settings_active||!led_available)begin running<=0;pending_toggle<=0;end
            if(sample_ce)begin
                if(blink_count>=SAMPLE_HZ/4-1)begin blink_count<=0;blink<=!blink;end
                else blink_count<=blink_count+1'b1;
            end
            if(config_changed)begin
                initialized<=1;cfg_song<=song_select;cfg_map<=mapped_midi;cfg_mono<=monophonic;cfg_tempo<=tempo;
                validating<=1;check_index<=0;bad<=0;bad_reason<=0;ready<=0;compatible<=0;
                running<=0;done<=0;step<=0;event_tick<=0;sample_count<=0;
                missed<=0;wrong<=0;good_seen<=0;wrong_seen<=0;pending_toggle<=0;pending_rewind<=0;
                pending_on<=0;event_on<=0;
            end else if(validating)begin
                masks[check_index]<=mapped_target;
                if(unmapped)begin bad<=1;bad_reason<=2;end
                else if(mono_conflict)begin bad<=1;if(bad_reason!=2)bad_reason<=3;end
                if(check_index+5'd1==song_length)begin
                    validating<=0;ready<=1;compatible<=!bad&&!unmapped&&!mono_conflict;
                end else check_index<=check_index+1'b1;
            end else if(tempo!=cfg_tempo)begin
                // Tempo edits preserve the score position but require resume.
                cfg_tempo<=tempo;sample_count<=0;running<=0;pending_toggle<=0;
            end else if(sample_ce)begin
                pending_toggle<=0;pending_rewind<=0;pending_on<=0;
                if(rewind_now)begin
                    running<=0;done<=0;step<=0;event_tick<=0;sample_count<=0;
                    missed<=0;wrong<=0;good_seen<=0;wrong_seen<=0;event_on<=0;
                end else if(enable&&!settings_active&&led_available&&ready&&compatible)begin
                    if(run_change)begin
                        // Absolute host requests are idempotent and win over
                        // a local toggle at the same sample boundary.
                        running<=absolute_run ? run_value : !running;
                        if(done&&(!absolute_run||run_value))begin
                            done<=0;step<=0;event_tick<=0;sample_count<=0;missed<=0;wrong<=0;good_seen<=0;wrong_seen<=0;event_on<=0;
                        end
                    end else if(running)begin
                        event_on<=event_on|(frame_on&target_keys);
                        if(perfect&&target_keys!=0)good_seen<=1;
                        if(wrong_now)wrong_seen<=1;
                        if(gate_end&&current_mask!=0&&!good_seen&&!perfect&&missed!=255)missed<=missed+1'b1;
                        if(tick_end)begin
                            sample_count<=0;
                            if(step_end)begin
                                if((wrong_seen||wrong_now)&&wrong!=255)wrong<=wrong+1'b1;
                                good_seen<=0;wrong_seen<=0;event_tick<=0;
                                // A sampled onset exactly at the transition
                                // belongs to the next event, not a held repeat.
                                event_on<=frame_on&next_mask;
                                if(step+5'd1==song_length)begin done<=1;running<=0;end
                                else step<=step+1'b1;
                            end else event_tick<=event_tick+1'b1;
                        end else sample_count<=sample_count+1'b1;
                    end
                end
            end
        end
    end
endmodule
