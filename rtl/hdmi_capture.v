`timescale 1ns/1ps
// Capture 512 post-effects samples, or 256 for a single active voice.
// The bank tagged by ack is immutable until video publishes it and requests
// the opposite bank. State travels as a bundled, held bus behind the ack.
module hdmi_capture #(parameter STATE_WIDTH=64)(input audio_clk,input audio_rst,input [STATE_WIDTH-1:0] state_in,
    input signed [15:0] pcm,input pcm_valid,input pixel_clk,input video_rst,
    input frame_tick,input [8:0] read_address,output reg [STATE_WIDTH-1:0] state_out,
    output [7:0] wave_out,output reg valid_out,output reg [1:0] visible_stride);
    reg request,ack,pending,visible_bank;
    (* ASYNC_REG="TRUE",syn_preserve=1 *) reg req_meta,req_sync,ack_meta,ack_sync;
    reg [STATE_WIDTH-1:0] held_state;
    reg busy,capture_bank;
    reg waiting,previous_negative,crossing_seen;
    reg [9:0] period_ticks;
    reg [1:0] measured_stride,held_stride,skip;
    wire rising_crossing=previous_negative && !pcm[15];
    // Leave some margin beyond a complete period in each 256-point view.
    wire [1:0] interval_stride=period_ticks>=10'd479 ? 2'd2 :
        period_ticks>=10'd239 ? 2'd1 : 2'd0;
    reg [8:0] write_address;
    wire single_voice=held_state[52:47]==6'd1;
    // Preserve quiet PCM until the range for this exact buffer is known.
    // 1024 x 16 still fits one 18-kbit block RAM on GW2AR.
    (* syn_ramstyle="block_ram" *) reg [15:0] samples[0:1023];
    reg [15:0] raw_wave;
    reg [7:0] peak_mask;
    reg [3:0] visible_shift;
    // Invert negative PCM instead of taking abs: -32768 then has extent
    // 32767, and the chosen signed range includes both -128 and +127.
    wire [14:0] extent=pcm[15] ? ~pcm[14:0] : pcm[14:0];
    // Only the highest occupied bit is needed, so an OR accumulator avoids
    // a per-sample magnitude comparator. Like held_state, the completed
    // mask is held behind ack until the video domain publishes its bank.
    wire [3:0] held_shift=peak_mask[7] ? 4'd8 : peak_mask[6] ? 4'd7 :
        peak_mask[5] ? 4'd6 : peak_mask[4] ? 4'd5 : peak_mask[3] ? 4'd4 :
        peak_mask[2] ? 4'd3 : peak_mask[1] ? 4'd2 : peak_mask[0] ? 4'd1 : 4'd0;
    wire signed [15:0] ranged_wave=$signed(raw_wave) >>> visible_shift;
    assign wave_out=ranged_wave[7:0];
    // Asynchronous assertion, audio-domain release. A lost video PLL only
    // resets this passive consumer; it never resets or stalls the synth.
    reg [1:0] reset_audio;
    always @(posedge audio_clk or posedge video_rst or posedge audio_rst)
        if(video_rst || audio_rst)reset_audio<=2'b11;
        else reset_audio<={reset_audio[0],1'b0};
    always @(posedge audio_clk)begin
        if(reset_audio[1] || state_in[52:47]!=6'd1)begin
            previous_negative<=0;crossing_seen<=0;period_ticks<=0;measured_stride<=2'd2;
        end else if(pcm_valid)begin
            previous_negative<=pcm[15];
            if(rising_crossing)begin
                if(crossing_seen)measured_stride<=interval_stride;
                crossing_seen<=1;period_ticks<=0;
            end else if(!(&period_ticks))period_ticks<=period_ticks+1'b1;
        end
    end
    always @(posedge audio_clk) begin
        if(reset_audio[1])begin
            req_meta<=0;req_sync<=0;ack<=0;busy<=0;write_address<=0;held_state<=0;capture_bank<=0;
            peak_mask<=0;
            waiting<=0;held_stride<=0;skip<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;
            if(!busy && req_sync!=ack)begin
                busy<=1;capture_bank<=req_sync;write_address<=0;held_state<=state_in;peak_mask<=0;
                waiting<=state_in[52:47]==6'd1;
                held_stride<=0;skip<=0;
            end else if(busy && pcm_valid)begin
                if(waiting)begin
                    // Bound the search even when the signal has no crossing.
                    if(rising_crossing || write_address==9'd383)begin
                        waiting<=0;write_address<=0;
                        held_stride<=(rising_crossing && crossing_seen) ? interval_stride : measured_stride;
                    end else write_address<=write_address+1'b1;
                end else if(skip!=0)skip<=skip-1'b1;
                else begin
                    skip<=held_stride[1] ? 2'd3 : {1'b0,held_stride[0]};
                    peak_mask<=peak_mask | extent[14:7];
                    if((&write_address[7:0]) && (single_voice || write_address[8]))begin
                        busy<=0;ack<=capture_bank;
                    end else write_address<=write_address+1'b1;
                end
            end
        end
    end
    // No reset on the RAM ports: old contents are masked until a full capture.
    always @(posedge audio_clk)
        if(!reset_audio[1] && busy && !waiting && skip==0 && pcm_valid)
            samples[{capture_bank,write_address}]<=pcm;
    always @(posedge pixel_clk)raw_wave<=samples[{visible_bank,read_address}];
    always @(posedge pixel_clk)begin
        if(video_rst)begin
            request<=0;ack_meta<=0;ack_sync<=0;pending<=0;visible_bank<=0;state_out<=0;valid_out<=0;visible_shift<=0;visible_stride<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(frame_tick && (!pending || ack_sync==request))begin
                if(pending)begin
                    state_out<=held_state;visible_bank<=request;visible_shift<=held_shift;
                    visible_stride<=held_stride;valid_out<=1;
                end
                request<=~request;pending<=1;
            end
        end
    end
endmodule
