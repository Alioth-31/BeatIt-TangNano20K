`timescale 1ns/1ps
// Keep an ordered list of held sources. Compact survivors into the other
// small bank, then append this frame's note-ons. Single read/write ports avoid
// forty parallel rank decrementers; no timestamps can wrap during a long hold.
// Source payloads must remain stable until frame_ready (the bridge already
// commits at sample boundaries). Same-frame ties follow ascending source order.
module mono_priority #(
    parameter NUM_SOURCES=40,parameter SEQUENTIAL_INSTANCE_ENABLE=0
)(input clk,input rst,input sample_ce,input enable,
  input [NUM_SOURCES-1:0] held_keys,input [NUM_SOURCES*16-1:0] source_instance,
  output reg frame_ready,output reg [NUM_SOURCES-1:0] routed_keys,
  output reg [5:0] selected_source,output reg mono_mode,output reg legato,
  output reg fault);
    reg [5:0] order_a[0:NUM_SOURCES-1],order_b[0:NUM_SOURCES-1];
    reg bank;
    reg [5:0] list_count,new_count,read_source;
    localparam IDLE=0,READ=1,FILTER=2,APPEND=3,EMIT=4;
    reg [NUM_SOURCES-1:0] previous_held,frame_held,frame_on;
    reg [NUM_SOURCES*16-1:0] previous_instance;
    wire [NUM_SOURCES-1:0] changed;
    genvar g;
    generate for(g=0;g<NUM_SOURCES;g=g+1)begin: tags
        assign changed[g]=SEQUENTIAL_INSTANCE_ENABLE?
            (source_instance[g*16]!=previous_instance[g*16]):
            (source_instance[g*16+:16]!=previous_instance[g*16+:16]);
    end endgenerate
    reg [2:0] state;
    reg [5:0] cursor,winner;
    reg frame_mode,previous_mode,frame_continuous;
    wire keep_old=state==FILTER && frame_held[read_source] && !frame_on[read_source];
    wire keep_new=state==APPEND && frame_on[cursor];
    wire [5:0] write_source=keep_new?cursor:read_source;
    integer i;
    // No reset on the tiny memories: list_count=0 makes unwritten data
    // unreachable. Each bank has one write port and one synchronous read.
    always @(posedge clk)begin
        if(state==READ)read_source<=bank?order_b[cursor]:order_a[cursor];
        if(!rst && !fault && !sample_ce && (keep_old || keep_new))begin
            if(bank)order_a[new_count]<=write_source;
            else order_b[new_count]<=write_source;
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;frame_ready<=0;routed_keys<=0;selected_source<=0;mono_mode<=0;legato<=0;fault<=0;
            previous_held<=0;frame_held<=0;frame_on<=0;previous_instance<=0;
            cursor<=0;winner<=0;bank<=0;list_count<=0;new_count<=0;
            frame_mode<=0;previous_mode<=0;frame_continuous<=0;
        end else begin
            frame_ready<=0;
            if(fault || (sample_ce && state!=IDLE))begin
                fault<=1;routed_keys<=0;legato<=0;state<=IDLE;frame_ready<=sample_ce;
            end else case(state)
                IDLE:if(sample_ce)begin
                    frame_held<=held_keys;frame_on<=held_keys & (~previous_held | changed);
                    frame_continuous<=|(held_keys & previous_held & ~changed);
                    previous_held<=held_keys;previous_instance<=source_instance;
                    frame_mode<=enable;winner<=0;new_count<=0;cursor<=0;
                    state<=(list_count==0)?APPEND:READ;
                end
                READ:state<=FILTER;
                FILTER:begin
                    if(keep_old)begin new_count<=new_count+1'b1;winner<=read_source;end
                    if(cursor==list_count-1)begin cursor<=0;state<=APPEND;end
                    else begin cursor<=cursor+1'b1;state<=READ;end
                end
                APPEND:begin
                    if(keep_new)begin new_count<=new_count+1'b1;winner<=cursor;end
                    if(cursor==NUM_SOURCES-1)state<=EMIT;
                    else cursor<=cursor+1'b1;
                end
                EMIT:begin
                    bank<=!bank;list_count<=new_count;
                    selected_source<=winner;mono_mode<=frame_mode;previous_mode<=frame_mode;
                    legato<=frame_mode && frame_mode==previous_mode && (|routed_keys) && frame_continuous;
                    if(frame_mode!=previous_mode)routed_keys<=0;
                    else if(!frame_mode)routed_keys<=frame_held;
                    else for(i=0;i<NUM_SOURCES;i=i+1)routed_keys[i]<=(winner==i) && (|frame_held);
                    frame_ready<=1;state<=IDLE;
                end
            endcase
        end
    end
endmodule
