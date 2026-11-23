`timescale 1ns/1ps
// Temporary SRAM diagnostic: independent audio generation and UART PCM capture.
// UART is 115200 8N1 on FPGA pin 69 (BL616 RX after firmware "choose uart").
module hardware_probe_top #(
    parameter PHASE_SAMPLES=96000,
    parameter RATE_REF_CYCLES=27000000,
    parameter UART_DIVISOR=427
)(input clk_audio, input clk_27m, input reset_button,
  output HP_BCK, output HP_WS, output HP_DIN, output PA_EN,
  output [5:0] led_n, output reg uart_tx);
    reg [7:0] reset_pipe=8'hff;
    always @(posedge clk_audio or posedge reset_button)
        if(reset_button) reset_pipe<=8'hff;
        else reset_pipe<={reset_pipe[6:0],1'b0};
    wire rst=reset_pipe[7];

    reg phase_a4;
    reg [16:0] phase_samples;
    wire [31:0] requested=phase_a4?32'h00000020:32'h00000055;
    wire sample_ce,pcm_valid,core_fault,tx_fault,ready,busy;
    wire [3:0] active;
    wire signed [15:0] pcm;
    synth_core #(.NUM_VOICES(4)) core(
        clk_audio,rst,sample_ce,requested,2'd0,17'd16384,17'd65536,
        pcm,pcm_valid,core_fault,busy,active,2'd0,17'd66048,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,224'd0,512'd0,1'b0,1'b0,32'd0);
    i2s_tx tx(clk_audio,rst,pcm,pcm_valid,sample_ce,
              HP_BCK,HP_WS,HP_DIN,tx_fault,ready);
    assign PA_EN=ready && !core_fault && !tx_fault && !rst;

    // A phase ends only after its final PCM word is available. Thus its
    // sample enters the FIFO before the marker for the following phase.
    wire phase_event=pcm_valid && phase_samples==PHASE_SAMPLES-1;
    reg [4:0] decimation;
    wire sample_event=pcm_valid && decimation==31;
    reg phase_pending;
    reg [1:0] phase_marker_kind;

    // Count audio frames against the board's independent 27 MHz oscillator.
    // Only the one-bit reference toggle crosses into clk_audio.
    reg [24:0] reference_count=0;
    reg reference_toggle=0;
    always @(posedge clk_27m or posedge reset_button)
        if(reset_button) begin
            reference_count<=0;
            reference_toggle<=0;
        end else if(reference_count==RATE_REF_CYCLES-1) begin
            reference_count<=0;
            reference_toggle<=~reference_toggle;
        end else reference_count<=reference_count+1'b1;
    reg ref_meta,ref_sync,ref_prev;
    wire rate_event=ref_sync^ref_prev;

    function [19:0] bcd_increment;
        input [19:0] old_value;
        integer digit;
        reg carry;
        begin
            bcd_increment=old_value;
            carry=1;
            for(digit=0;digit<5;digit=digit+1)
                if(carry) begin
                    if(old_value[digit*4 +: 4]==9) begin
                        bcd_increment[digit*4 +: 4]=0;
                        carry=1;
                    end else begin
                        bcd_increment[digit*4 +: 4]=old_value[digit*4 +: 4]+1'b1;
                        carry=0;
                    end
                end
        end
    endfunction
    reg [19:0] live_rate,reported_rate;
    reg rate_pending;

    // A complete-record FIFO absorbs marker bursts without interrupting the
    // 1-in-32 PCM stream. Kind 0 is PCM; 1/2 are phase; 3 is decimal rate.
    reg [21:0] events [0:7];
    reg [2:0] write_ptr,read_ptr;
    reg [3:0] event_count;
    reg uart_overflow;
    wire want_sample=sample_event;
    wire want_phase=!want_sample && phase_pending;
    wire want_rate=!want_sample && !want_phase && rate_pending;
    wire want_event=want_sample || want_phase || want_rate;
    wire [21:0] event_word=want_sample?{2'd0,4'b0,pcm}:
                           want_phase?{phase_marker_kind,20'b0}:
                                      {2'd3,reported_rate};
    reg line_active,uart_busy;
    reg [1:0] line_kind;
    reg [19:0] line_data;
    reg [3:0] line_pos;
    reg [9:0] uart_shift;
    reg [3:0] uart_bit;
    reg [8:0] baud_count;
    wire start_line=!uart_busy && !line_active && event_count!=0;
    wire fifo_room=event_count<8 || start_line;
    wire push_event=want_event && fifo_room;

    function [7:0] hex_ascii;
        input [3:0] nibble;
        begin hex_ascii=(nibble<10)?(8'h30+nibble):(8'h41+nibble-10); end
    endfunction
    function [7:0] line_character;
        input [1:0] kind;
        input [19:0] data;
        input [3:0] pos;
        begin
            line_character=8'h0a;
            case(kind)
                2'd0: case(pos)
                    0:line_character=hex_ascii(data[15:12]);
                    1:line_character=hex_ascii(data[11:8]);
                    2:line_character=hex_ascii(data[7:4]);
                    3:line_character=hex_ascii(data[3:0]);
                endcase
                2'd1: case(pos)
                    0:line_character="#";
                    1:line_character="A";
                    2:line_character="4";
                endcase
                2'd2: case(pos)
                    0:line_character="#";
                    1:line_character="C";
                    2:line_character="H";
                endcase
                2'd3: case(pos)
                    0:line_character="#";
                    1:line_character="R";
                    2:line_character="A";
                    3:line_character="T";
                    4:line_character="E";
                    5:line_character=" ";
                    6:line_character=8'h30+data[19:16];
                    7:line_character=8'h30+data[15:12];
                    8:line_character=8'h30+data[11:8];
                    9:line_character=8'h30+data[7:4];
                    10:line_character=8'h30+data[3:0];
                endcase
            endcase
        end
    endfunction
    wire last_character=(line_kind==2'd0)?(line_pos==4):
                        (line_kind==2'd3)?(line_pos==11):(line_pos==3);

    always @(posedge clk_audio) begin
        if(rst) begin
            phase_a4<=1; phase_samples<=0; decimation<=0;
            phase_pending<=1; phase_marker_kind<=2'd1;
            ref_meta<=0; ref_sync<=0; ref_prev<=0;
            live_rate<=0; reported_rate<=0; rate_pending<=0;
            write_ptr<=0; read_ptr<=0; event_count<=0;
            uart_overflow<=0; line_active<=0; uart_busy<=0;
            line_kind<=0; line_data<=0; line_pos<=0;
            uart_shift<=10'h3ff; uart_bit<=0; baud_count<=0;
            uart_tx<=1;
        end else begin
            ref_meta<=reference_toggle;
            ref_sync<=ref_meta;
            ref_prev<=ref_sync;
            if(pcm_valid) begin
                decimation<=decimation+1'b1;
                if(phase_event) begin
                    phase_samples<=0;
                    phase_a4<=~phase_a4;
                    if(phase_pending) uart_overflow<=1;
                    phase_pending<=1;
                    phase_marker_kind<=phase_a4?2'd2:2'd1;
                end else phase_samples<=phase_samples+1'b1;
            end
            if(rate_event) begin
                reported_rate<=live_rate;
                live_rate<=sample_ce?20'h00001:20'h00000;
                if(rate_pending) uart_overflow<=1;
                rate_pending<=1;
            end else if(sample_ce) live_rate<=bcd_increment(live_rate);

            if(push_event) begin
                events[write_ptr]<=event_word;
                write_ptr<=write_ptr+1'b1;
                if(want_phase) phase_pending<=0;
                if(want_rate) rate_pending<=0;
            end else if(want_sample) uart_overflow<=1;
            case({push_event,start_line})
                2'b10:event_count<=event_count+1'b1;
                2'b01:event_count<=event_count-1'b1;
            endcase
            if(start_line) begin
                {line_kind,line_data}<=events[read_ptr];
                read_ptr<=read_ptr+1'b1;
                line_pos<=0;
                line_active<=1;
            end
            if(!uart_busy) begin
                if(line_active) begin
                    uart_shift<={1'b1,line_character(line_kind,line_data,line_pos),1'b0};
                    uart_tx<=0;
                    baud_count<=UART_DIVISOR-1;
                    uart_bit<=0;
                    uart_busy<=1;
                    if(last_character) line_active<=0;
                    else line_pos<=line_pos+1'b1;
                end
            end else if(baud_count==0) begin
                baud_count<=UART_DIVISOR-1;
                if(uart_bit==9) begin
                    uart_tx<=1;
                    uart_busy<=0;
                end else begin
                    uart_tx<=uart_shift[1];
                    uart_shift<={1'b1,uart_shift[9:1]};
                    uart_bit<=uart_bit+1'b1;
                end
            end else baud_count<=baud_count-1'b1;
        end
    end

    // Low-active LEDs: ready, core/I2S fault, UART overflow, chord, spare,
    // independent 27 MHz reference heartbeat.
    assign led_n={~ref_sync,1'b1,phase_a4,~uart_overflow,
                  ~(core_fault|tx_fault),~PA_EN};
endmodule
