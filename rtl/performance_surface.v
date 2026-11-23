`timescale 1ns/1ps
// Panel routing only. Accepted configuration remains owned by the bridge.
module performance_surface #(
    parameter HOLD_SAMPLES=16800, parameter GUIDE_ENABLED=0,parameter MONO_ENABLED=0
)(input clk,input rst,input sample_ce,input [7:0] physical_keys,
  input settings_down,input confirm_down,input right_up,input right_down,
  input [3:0] current_root,input [1:0] current_scale,
  input [2:0] current_octave,input [2:0] current_timbre,
  input current_guide,input current_song,input [1:0] current_tempo,
  output reg guide_toggle,
  output [7:0] play_keys,output reg settings_active,
  output reg [2:0] selected_field,output reg [7:0] preview_value,
  output reg commit_valid,output reg [2:0] commit_field,
  output reg [7:0] commit_value);
    function integer clog2;
        input integer value;integer v;
        begin v=value-1;clog2=0;while(v>0) begin v=v>>1;clog2=clog2+1;end end
    endfunction
    localparam HOLD_WIDTH=(HOLD_SAMPLES<2)?1:clog2(HOLD_SAMPLES);
    reg [HOLD_WIDTH-1:0] hold_count;
    reg [7:0] play_owner,menu_owner,previous_keys;
    reg previous_confirm,guide_press_owner;
    wire in_guide=GUIDE_ENABLED && current_guide;
    // Modulo-three deltas retain every detent without an unbounded counter.
    // Wait for authority to echo a proposal before using it as the next base.
    reg [1:0] perform_delta;
    reg [2:0] sent_timbre;
    reg timbre_waiting;
    reg pending_confirm;
    reg [2:0] pending_field;
    reg [7:0] pending_value;
    wire entering=sample_ce && settings_down && !settings_active &&
        ((HOLD_SAMPLES<=1) || hold_count==HOLD_SAMPLES-1);
    wire menu_now=settings_active || entering;
    wire [7:0] new_keys=physical_keys & ~previous_keys & ~play_owner;
    wire confirming=menu_now && settings_down && previous_confirm && !confirm_down;
    // Only this target is its acknowledgement: an older proposal can echo
    // after a new menu confirmation has already been issued.
    wire timbre_ready=!timbre_waiting || current_timbre==sent_timbre;
    reg [2:0] next_field;
    reg [1:0] next_delta;
    reg [7:0] next_preview;
    reg [2:0] proposed_timbre;
    reg [1:0] timbre_index;
    assign play_keys=rst?8'b0:(physical_keys & play_owner);

    function [7:0] field_value;
        input [2:0] field;
        begin
            case(field)
                1:field_value={4'b0,current_root}+((current_scale==1)?8'd12:8'd0);
                2:field_value={5'b0,current_octave};
                3:field_value={7'b0,current_guide};
                4:field_value={7'b0,current_song};
                5:field_value={6'b0,current_tempo};
                default:field_value={5'b0,current_timbre};
            endcase
        end
    endfunction
    function [7:0] stepped;
        input [2:0] field;input [7:0] value;input up,down;
        reg [7:0] lower,upper;
        begin
            lower=(field==2)?8'd2:8'd0;
            case(field)
                0:upper=2;1:upper=23;2:upper=6;3,4:upper=1;default:upper=3;
            endcase
            stepped=value;
            if(up && !down) stepped=(value>=upper)?lower:value+1'b1;
            else if(down && !up) stepped=(value<=lower)?upper:value-1'b1;
            if(MONO_ENABLED && field==0)begin
                if(up && !down)stepped=(value==2)?4:(value>=3)?0:value+1'b1;
                else if(down && !up)stepped=(value==4 || value==3)?2:(value==0)?4:value-1'b1;
            end
        end
    endfunction
    always @* begin
        next_field=selected_field;
        next_preview=preview_value;
        if(entering) begin next_field=0;next_preview=field_value(0);end
        // Menu selection and a detent on the entry edge both belong to menu.
        if(sample_ce && menu_now) begin
            if(new_keys[0]) begin next_field=0;next_preview=field_value(0);end
            else if(new_keys[1]) begin next_field=1;next_preview=field_value(1);end
            else if(new_keys[2]) begin next_field=2;next_preview=field_value(2);end
            else if(GUIDE_ENABLED && new_keys[3]) begin next_field=3;next_preview=field_value(3);end
            else if(in_guide && new_keys[4]) begin next_field=4;next_preview=field_value(4);end
            else if(in_guide && new_keys[5]) begin next_field=5;next_preview=field_value(5);end
        end
        if(menu_now && settings_down)
            next_preview=stepped(next_field,next_preview,right_up,right_down);
        next_delta=perform_delta;
        if(in_guide) next_delta=0;
        else if(!menu_now)begin
            if(MONO_ENABLED)begin
                if(right_up && !right_down)next_delta=perform_delta+1'b1;
                else if(right_down && !right_up)next_delta=perform_delta-1'b1;
            end else next_delta=stepped(0,{6'b0,perform_delta},right_up,right_down);
        end
        timbre_index=0;
        case(next_delta)
            1:proposed_timbre=(current_timbre>=2)?0:current_timbre+1'b1;
            2:proposed_timbre=(current_timbre==0)?2:current_timbre-1'b1;
            default:proposed_timbre=current_timbre;
        endcase
        if(MONO_ENABLED)begin
            timbre_index=((current_timbre>=3)?2'd3:current_timbre[1:0])+next_delta;
            proposed_timbre=(timbre_index==3)?3'd4:{1'b0,timbre_index};
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            hold_count<=0;play_owner<=0;menu_owner<=0;previous_keys<=0;previous_confirm<=0;
            settings_active<=0;selected_field<=0;preview_value<=0;
            commit_valid<=0;commit_field<=0;commit_value<=0;
            perform_delta<=0;timbre_waiting<=0;sent_timbre<=0;
            pending_confirm<=0;pending_field<=0;pending_value<=0;
            guide_press_owner<=0;guide_toggle<=0;
        end else begin
            commit_valid<=0;
            guide_toggle<=0;
            // A right-button click belongs to GUIDE only if its press and
            // release stay outside settings. Menu exit cannot auto-resume.
            if(confirm_down && !previous_confirm)
                guide_press_owner<=in_guide && !menu_now && !settings_down;
            if(!in_guide || menu_now || settings_down) guide_press_owner<=0;
            if(previous_confirm && !confirm_down)begin
                guide_toggle<=guide_press_owner && in_guide && !menu_now && !settings_down;
                guide_press_owner<=0;
            end
            previous_confirm<=confirm_down;
            // Release is effective every system clock, including in menus.
            play_owner<=play_owner & physical_keys;
            menu_owner<=menu_owner & physical_keys;
            if(menu_now) menu_owner<=(menu_owner | (physical_keys & ~play_owner)) & physical_keys;
            // Ownership follows the debounced edge, not the next audio frame:
            // a press just before menu entry is already a playing key.
            if(!menu_now) play_owner<=physical_keys & ~menu_owner;
            if(sample_ce) begin
                previous_keys<=physical_keys;
            end
            if(!settings_down) begin
                hold_count<=0;settings_active<=0;
                selected_field<=0;preview_value<=field_value(0);
            end else begin
                if(sample_ce && !settings_active) begin
                    if(entering) begin settings_active<=1;hold_count<=0;end
                    else hold_count<=hold_count+1'b1;
                end
                if(menu_now) begin selected_field<=next_field;preview_value<=next_preview;end
            end
            perform_delta<=next_delta;
            if(timbre_ready) timbre_waiting<=0;
            // Keep individual proposals separated by a low system-clock cycle.
            // A release immediately after a rotary proposal is retained here.
            if(pending_confirm && !commit_valid) begin
                commit_valid<=1;commit_field<=pending_field;commit_value<=pending_value;
                pending_confirm<=0;
                if(pending_field==0) begin
                    timbre_waiting<=pending_value[2:0]!=current_timbre;
                    sent_timbre<=pending_value[2:0];
                end
            end
            // Releasing left cancels first, so simultaneous releases cannot
            // confirm. Rotary input from the release edge stays in that menu.
            if(confirming) begin
                if(commit_valid || pending_confirm) begin
                    pending_confirm<=1;pending_field<=next_field;pending_value<=next_preview;
                end else begin
                    commit_valid<=1;commit_field<=next_field;commit_value<=next_preview;
                    if(next_field==0) begin
                        timbre_waiting<=next_preview[2:0]!=current_timbre;
                        sent_timbre<=next_preview[2:0];
                    end
                end
            end else if(sample_ce && timbre_ready && next_delta!=0 && !commit_valid && !pending_confirm) begin
                commit_valid<=1;commit_field<=0;commit_value<={5'b0,proposed_timbre};
                sent_timbre<=proposed_timbre;
                timbre_waiting<=proposed_timbre!=current_timbre;
                perform_delta<=0;
            end
        end
    end
endmodule
