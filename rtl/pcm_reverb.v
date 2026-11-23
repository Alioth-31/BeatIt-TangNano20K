`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Adapted from the reverb in kazunori279/xls32-fpga-synth, Basys3 top.v,
// commit 39fbb1bd7627ca5450bce69ffb00a87b07d528d8. See THIRD_PARTY_NOTICES.md.
// BeatIt changes: 48 kHz mono Q2 tank, packed 18-bit RAM, exact all-pass
// recurrence, widened/truncated signed arithmetic, one pipelined multiplier,
// reset validity masking, wet smoothing and sticky overrun silence.
//
// wet_target: Q15, clamped to [0,32768]. Room 0..3 selects feedback gain.
// Parameters are captured with in_valid. Inputs must be spaced by >= 48 clocks.
// Normal wet=0 keeps the tank running. Explicit bypass flushes it and returns
// dry PCM immediately; this is a reset-style bypass, not a click-free crossfade.
module pcm_reverb(
    input clk, input rst,
    input signed [15:0] in_pcm, input in_valid,
    input bypass, input [15:0] wet_target, input [1:0] room_size,
    output reg signed [15:0] out_pcm, output reg out_valid,
    output reg fault, output busy
);
    localparam IDLE=4'd0, RAM_WAIT=4'd1, PREPARE=4'd2,
               COMB_MULT=4'd3, COMB_STORE=4'd4, AP_STORE=4'd5,
               OUT_PREPARE=4'd6, OUT_MULT=4'd7, OUT_STORE=4'd8;
    reg [3:0] state, line_index;
    reg [10:0] position [0:11];
    reg [10:0] filled [0:11];
    reg signed [17:0] damping [0:7];
    (* syn_ramstyle="block_ram" *) reg signed [17:0] tank [0:14051];
    reg signed [17:0] read_data;
    reg signed [15:0] dry;
    reg signed [17:0] send_pcm, damped, carry, ap_output;
    reg signed [20:0] comb_sum;
    reg signed [17:0] mul_a, mul_b;
    wire signed [35:0] product;
    reg [15:0] wet, feedback;
    integer i;

    function [13:0] line_base;
        input [3:0] index;
        begin
            case(index)
                0: line_base=14'd0;     1: line_base=14'd1215;
                2: line_base=14'd2532;  3: line_base=14'd3942;
                4: line_base=14'd5460;  5: line_base=14'd7059;
                6: line_base=14'd8742;  7: line_base=14'd10506;
                8: line_base=14'd12351; 9: line_base=14'd12956;
                10:line_base=14'd13436; default:line_base=14'd13807;
            endcase
        end
    endfunction
    function [10:0] line_length;
        input [3:0] index;
        begin
            case(index)
                0: line_length=11'd1215; 1: line_length=11'd1317;
                2: line_length=11'd1410; 3: line_length=11'd1518;
                4: line_length=11'd1599; 5: line_length=11'd1683;
                6: line_length=11'd1764; 7: line_length=11'd1845;
                8: line_length=11'd605;  9: line_length=11'd480;
                10:line_length=11'd371; default:line_length=11'd245;
            endcase
        end
    endfunction
    function signed [15:0] sat16;
        input signed [20:0] value;
        begin
            if(value>21'sd32767) sat16=16'sd32767;
            else if(value < -21'sd32768) sat16=-16'sd32768;
            else sat16=value[15:0];
        end
    endfunction
    function signed [17:0] sat18;
        input signed [20:0] value;
        begin
            if(value>21'sd131071) sat18=18'sd131071;
            else if(value < -21'sd131072) sat18=-18'sd131072;
            else sat18=value[17:0];
        end
    endfunction
    // Truncate feedback toward zero: negative arithmetic shifts alone bias
    // the tail and can leave a persistent quantization limit cycle.
    function signed [17:0] half_zero;
        input signed [18:0] value;
        begin half_zero=(value+(value[18] ? 19'sd1 : 19'sd0)) >>> 1; end
    endfunction
    function signed [20:0] q15_zero;
        input signed [35:0] value;
        begin q15_zero=(value+(value[35] ? 36'sd32767 : 36'sd0)) >>> 15; end
    endfunction

    wire [10:0] length=line_length(line_index);
    wire [13:0] address=line_base(line_index)+{3'b0,position[line_index]};
    wire signed [17:0] tap=(filled[line_index]==length) ? read_data : 18'sd0;
    wire signed [18:0] damp_sum=$signed({damping[line_index[2:0]][17],damping[line_index[2:0]]})
                                +$signed({tap[17],tap});
    wire signed [17:0] comb_value=sat18($signed(send_pcm)+q15_zero(product));
    wire signed [20:0] next_sum=comb_sum+$signed(comb_value);
    wire signed [20:0] average=(next_sum+(next_sum[20] ? 21'sd7 : 21'sd0)) >>> 3;
    wire signed [17:0] ap_value=sat18($signed(tap)-$signed(half_zero({carry[17],carry})));
    wire signed [17:0] ap_write=sat18($signed(carry)+$signed(half_zero({ap_output[17],ap_output})));
    // Tank is signed 18-bit Q2; declare only the 14052 used delay words.
    // Return gain compensates conservative send scaling. Limit the wet signal
    // before convex mixing, so extreme excitation cannot wrap the final PCM.
    wire signed [20:0] return_wide=$signed({{3{carry[17]}},carry}) <<< 2;
    wire signed [15:0] return_pcm=sat16(return_wide);
    wire multiply_ce=!fault && !in_valid && (state==COMB_MULT || state==OUT_MULT);
`ifdef GOWIN_PRIMITIVES
    // Automatic mapping selected a fabric multiply and put the rounding ADD
    // in DSP; full PnR missed 49.152 MHz. Explicitly bind the shared multiplier.
    MULT18X18 #(.AREG(1'b0),.BREG(1'b0),.OUT_REG(1'b1),.PIPE_REG(1'b0),
        .ASIGN_REG(1'b0),.BSIGN_REG(1'b0),.MULT_RESET_MODE("SYNC")) multiplier(
        .A(mul_a),.B(mul_b),.SIA(18'd0),.SIB(18'd0),.ASEL(1'b0),.BSEL(1'b0),
        .ASIGN(1'b1),.BSIGN(1'b1),.CLK(clk),.CE(multiply_ce),.RESET(rst),
        .DOUT(product),.SOA(),.SOB());
`else
    reg signed [35:0] product_model;
    assign product=product_model;
    always @(posedge clk)
        if(rst) product_model<=0;
        else if(multiply_ce) product_model<=mul_a*mul_b;
`endif
    wire [15:0] target=(wet_target>16'd32768) ? 16'd32768 : wet_target;
    wire signed [16:0] input_extended=$signed({in_pcm[15],in_pcm});
    wire signed [16:0] input_scaled=(input_extended+(in_pcm[15] ? 17'sd7 : 17'sd0)) >>> 3;
    wire store_enable=!rst && !fault && !in_valid && (state==COMB_STORE || state==AP_STORE);
    assign busy=(state!=IDLE);

    // Read-first synchronous RAM. The read/write collision result is never
    // consumed: RAM_WAIT settles the address after each line/pointer change.
    // RAM itself is not reset; per-line fill counts hide stale/uninitialised data.
    always @(posedge clk) begin
        read_data <= tank[address];
        if(store_enable) tank[address] <= (state==COMB_STORE) ? comb_value : ap_write;
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE; line_index<=0; out_pcm<=0; out_valid<=0; fault<=0;
            wet<=0; feedback<=0; dry<=0; send_pcm<=0; damped<=0; carry<=0;
            ap_output<=0; comb_sum<=0; mul_a<=0; mul_b<=0;
            for(i=0;i<12;i=i+1) begin position[i]<=0; filled[i]<=0; end
            for(i=0;i<8;i=i+1) damping[i]<=0;
        end else begin
            out_valid<=0;
            if(fault || (in_valid && busy)) begin
                fault<=1; out_pcm<=0; out_valid<=in_valid; state<=IDLE;
            end else begin
                case(state)
                    IDLE: if(in_valid) begin
                        if(bypass) begin
                            out_pcm<=in_pcm; out_valid<=1; wet<=0;
                            for(i=0;i<12;i=i+1) begin position[i]<=0; filled[i]<=0; end
                            for(i=0;i<8;i=i+1) damping[i]<=0;
                        end else begin
                            dry<=in_pcm; send_pcm<=input_scaled;
                            if(target>wet) wet<=wet+((target-wet>16'd64) ? 16'd64 : target-wet);
                            else wet<=wet-((wet-target>16'd64) ? 16'd64 : wet-target);
                            case(room_size)
                                0:feedback<=16'd22000; 1:feedback<=16'd26000;
                                2:feedback<=16'd29000; 3:feedback<=16'd31200;
                            endcase
                            line_index<=0; comb_sum<=0; state<=RAM_WAIT;
                        end
                    end
                    RAM_WAIT: state<=PREPARE;
                    PREPARE: begin
                        if(line_index<8) begin
                            damped<=half_zero(damp_sum); mul_a<=half_zero(damp_sum);
                            mul_b<=$signed({2'b0,feedback}); state<=COMB_MULT;
                        end
                        else begin ap_output<=ap_value; state<=AP_STORE; end
                    end
                    COMB_MULT,OUT_MULT: begin
                        state<=(state==COMB_MULT) ? COMB_STORE : OUT_STORE;
                    end
                    COMB_STORE,AP_STORE: begin
                        if(position[line_index]==length-11'd1) position[line_index]<=0;
                        else position[line_index]<=position[line_index]+11'd1;
                        if(filled[line_index]!=length) filled[line_index]<=filled[line_index]+11'd1;
                        if(state==COMB_STORE) begin
                            damping[line_index[2:0]]<=damped;
                            comb_sum<=next_sum;
                            if(line_index==7) carry<=average[17:0];
                        end else carry<=ap_output;
                        if(line_index==11) state<=OUT_PREPARE;
                        else begin line_index<=line_index+4'd1; state<=RAM_WAIT; end
                    end
                    OUT_PREPARE: begin
                        mul_a<=$signed({{2{return_pcm[15]}},return_pcm})-$signed({{2{dry[15]}},dry});
                        mul_b<=$signed({2'b0,wet});
                        state<=OUT_MULT;
                    end
                    OUT_STORE: begin
                        out_pcm<=sat16($signed(dry)+q15_zero(product));
                        out_valid<=1; state<=IDLE;
                    end
                    default: begin fault<=1; out_pcm<=0; out_valid<=1; state<=IDLE; end
                endcase
            end
        end
    end
endmodule
