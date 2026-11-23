`timescale 1ns/1ps
module quadrature #(
    parameter FILTER_CYCLES=1024,
    parameter EDGES_PER_STEP=4
)(input clk, input rst, input [1:0] ab, output reg up, output reg down);
    wire [1:0] filtered;
    reg [1:0] previous;
    reg signed [3:0] travel;
    reg signed [2:0] delta;
    debounce #(.STABLE_CYCLES(FILTER_CYCLES)) qa(clk,rst,ab[1],filtered[1]);
    debounce #(.STABLE_CYCLES(FILTER_CYCLES)) qb(clk,rst,ab[0],filtered[0]);
    always @* begin
        case({previous,filtered})
            4'b1110,4'b1000,4'b0001,4'b0111: delta=1;
            4'b1101,4'b0100,4'b0010,4'b1011: delta=-1;
            default: delta=0;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin previous<=2'b11; travel<=0; up<=0; down<=0; end
        else begin
            up<=0; down<=0;
            if(filtered!=previous) begin
                previous<=filtered;
                if(delta==0) travel<=0;
                else if(travel+delta>=EDGES_PER_STEP) begin up<=1; travel<=0; end
                else if(travel+delta<=-EDGES_PER_STEP) begin down<=1; travel<=0; end
                else travel<=travel+delta;
            end
        end
    end
endmodule
