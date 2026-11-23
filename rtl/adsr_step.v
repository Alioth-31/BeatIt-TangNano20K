`timescale 1ns/1ps
// One shared combinational envelope ALU. Q24 level, exact stage sample counts.
// State 0=off, 1=attack, 2=decay, 3=sustain, 4=release; 5=steal is external.
module adsr_step(
    input [2:0] state, input [24:0] level, input [14:0] remaining,
    input [24:0] release_step, input [1:0] preset, input gate,
    output reg [2:0] next_state, output reg [24:0] next_level,
    output reg [14:0] next_remaining, output reg [24:0] next_step
);
    reg [24:0] sustain, attack_step, decay_step;
    reg [14:0] decay_samples, release_samples;
    reg [31:0] reciprocal;
    reg [56:0] release_product;
    reg [24:0] first_step;
    always @* begin
        case(preset)
            1: begin
                sustain=5033165; attack_step=174763; decay_step=2447;
                decay_samples=4800; release_samples=2880; reciprocal=1491309;
            end
            2: begin
                sustain=13421773; attack_step=69906; decay_step=350;
                decay_samples=9600; release_samples=14400; reciprocal=298262;
            end
            default: begin
                sustain=11744051; attack_step=69906; decay_step=1311;
                decay_samples=3840; release_samples=5760; reciprocal=745655;
            end
        endcase
        release_product=level*reciprocal;
        first_step=(release_product>>32)+1'b1;
        next_state=state; next_level=level; next_remaining=remaining; next_step=release_step;
        if(state!=0 && state!=4 && !gate) begin
            next_state=4; next_remaining=release_samples-1'b1; next_step=first_step;
            next_level=(level>first_step)?level-first_step:0;
        end else begin
            case(state)
                0: begin next_level=0; next_remaining=0; end
                1: begin
                    if(remaining<=1) begin next_level=16777216; next_state=2; next_remaining=decay_samples; end
                    else begin
                        next_remaining=remaining-1'b1;
                        next_level=(level+attack_step>=16777216)?16777216:level+attack_step;
                    end
                end
                2: begin
                    if(remaining<=1) begin next_level=sustain; next_state=3; next_remaining=0; end
                    else begin
                        next_remaining=remaining-1'b1;
                        next_level=(level>sustain+decay_step)?level-decay_step:sustain;
                    end
                end
                3: next_level=sustain;
                4: begin
                    if(remaining<=1) begin next_state=0; next_level=0; next_remaining=0; end
                    else begin
                        next_remaining=remaining-1'b1;
                        next_level=(level>release_step)?level-release_step:0;
                    end
                end
                default: begin next_state=0; next_level=0; next_remaining=0; end
            endcase
        end
    end
endmodule
