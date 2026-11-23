`timescale 1ns/1ps
// Guide configuration authority, shared by local panel and existing UART.
// SET: enable, song, tempo, action (0 pause, 1 start/resume, 2 rewind/pause).
// ACK accepts the request; queried state reports actual readiness/running.
module guide_control #(parameter integer SAMPLE_HZ=48000)(
    input clk,input rst,input sample_ce,input [63:0] config_request,input config_commit,
    output config_valid,output [127:0] query,
    input ui_commit,input [2:0] ui_field,input [7:0] ui_value,
    input settings_active,input [2:0] selected_field,input panel_toggle,
    input [55:0] mapped_midi,input [55:0] played_midi,input [7:0] play_keys,
    input monophonic,input led_available,input [7:0] led_applied,
    output reg enabled,output reg song,output reg [1:0] tempo,
    output [7:0] led_target,output [63:0] display_state
);
    assign config_valid=config_request[7:0]<2 && config_request[15:8]<2 &&
        config_request[23:16]<4 && config_request[31:24]<3;
    reg [2:0] pending_fields;reg [7:0] pending_value[0:2];
    reg [1:0] action;reg action_pending;
    reg [15:0] revision;
    wire running,ready,compatible,done;wire [3:0] step;
    wire [7:0] target,missed,wrong;wire [2:0] reason;
    wire panel_valid=ui_commit&&ui_field>=3&&ui_field<=5&&
        ((ui_field==5&&ui_value<4)||(ui_field!=5&&ui_value<2));
    wire [1:0] panel_index=ui_field-3'd3;
    wire action_fire=sample_ce&&action_pending&&ready&&!settings_active&&!config_commit&&
        pending_fields==0&&!panel_valid;
    guide_engine #(.SAMPLE_HZ(SAMPLE_HZ),.CONTROL_ENABLED(1)) engine(clk,rst,sample_ce,enabled,settings_active,
        panel_toggle,action_fire&&action==2,song,tempo,mapped_midi,played_midi,play_keys,
        monophonic,led_available,selected_field,led_target,target,running,ready,compatible,done,step,missed,wrong,reason,
        action_fire&&action!=2,action==1);
    assign query={revision,{7'b0,monophonic},{7'b0,led_available},{5'b0,reason},wrong,missed,
        play_keys,led_applied,led_target,target,{4'b0,step},{4'b0,done,compatible,ready,running},
        {6'b0,tempo},{7'b0,song},{7'b0,enabled}};
    assign display_state={led_applied,led_target,play_keys,wrong,missed,target,
        led_available,song,tempo,step,reason,done,ready,compatible,running,enabled};
    reg [2:0] ready_fields;reg [7:0] next_value;integer k;
    always @(posedge clk)begin
        if(rst)begin
            enabled<=0;song<=0;tempo<=2;revision<=0;
            pending_fields<=0;for(k=0;k<3;k=k+1)pending_value[k]<=0;
            action<=0;action_pending<=0;
        end else begin
            if(panel_valid)begin pending_fields[panel_index]<=1;pending_value[panel_index]<=ui_value;end
            if(action_fire)action_pending<=0;
            if(config_commit&&config_valid)begin
                enabled<=config_request[0];song<=config_request[8];tempo<=config_request[17:16];
                action<=config_request[25:24];action_pending<=!settings_active;revision<=revision+1'b1;
            end
            if(sample_ce)begin
                ready_fields=pending_fields;
                if(panel_valid)ready_fields[panel_index]=1;
                for(k=0;k<3;k=k+1)if(ready_fields[k])begin
                    next_value=(panel_valid&&panel_index==k) ? ui_value : pending_value[k];
                    case(k)0:enabled<=next_value[0];1:song<=next_value[0];2:tempo<=next_value[1:0];endcase
                end
                if(ready_fields!=0)begin revision<=revision+1'b1;action_pending<=0;end
                pending_fields<=0;
            end
            // A remote start during settings is not a request to auto-resume
            // after leaving settings. The next local/remote start must be explicit.
            if(settings_active)action_pending<=0;
        end
    end
endmodule
