`timescale 1ns/1ps
// DVI TMDS, LSB transmitted first. Signed running disparity resets in blanking.
module tmds_encoder(input clk,input rst,input de,input [1:0] control,
    input [7:0] data,output reg [9:0] symbol);
    reg [8:0] q;
    reg signed [5:0] disparity;
    reg signed [5:0] balance;
    integer ones,k;
    reg xnor_mode;
    always @* begin
        ones=0;for(k=0;k<8;k=k+1)ones=ones+data[k];
        xnor_mode=ones>4 || (ones==4 && !data[0]);
        q[0]=data[0];
        for(k=1;k<8;k=k+1)q[k]=xnor_mode?~(q[k-1]^data[k]):(q[k-1]^data[k]);
        q[8]=!xnor_mode;
        ones=0;for(k=0;k<8;k=k+1)ones=ones+q[k];
        balance=2*ones-8;
    end
    always @(posedge clk)begin
        if(rst || !de)begin
            disparity<=0;
            case(control)
                0:symbol<=10'b1101010100;
                1:symbol<=10'b0010101011;
                2:symbol<=10'b0101010100;
                3:symbol<=10'b1010101011;
            endcase
        end else if(disparity==0 || balance==0)begin
            symbol<={~q[8],q[8],q[8]?q[7:0]:~q[7:0]};
            disparity<=disparity+(q[8]?balance:-balance);
        end else if((disparity>0 && balance>0)||(disparity<0 && balance<0))begin
            symbol<={1'b1,q[8],~q[7:0]};
            disparity<=disparity-balance+(q[8]?6'sd2:6'sd0);
        end else begin
            symbol<={1'b0,q[8],q[7:0]};
            disparity<=disparity+balance-(q[8]?6'sd0:6'sd2);
        end
    end
endmodule
