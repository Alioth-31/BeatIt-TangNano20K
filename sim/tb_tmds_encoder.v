`timescale 1ns/1ps
module tb_tmds_encoder;
    reg clk=0,rst=1,de=0;reg [1:0] control=0;reg [7:0] data=0;
    wire [9:0] symbol;integer i,j,b,balance=0,ones;reg [7:0] q,decoded;
    tmds_encoder dut(clk,rst,de,control,data,symbol);
    always #5 clk=~clk;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(i=0;i<4;i=i+1)begin
            control=i;@(negedge clk);
            case(i)
                0:if(symbol!==10'b1101010100)$fatal(1,"control0");
                1:if(symbol!==10'b0010101011)$fatal(1,"control1");
                2:if(symbol!==10'b0101010100)$fatal(1,"control2");
                3:if(symbol!==10'b1010101011)$fatal(1,"control3");
            endcase
        end
        de=1;
        for(i=0;i<4096;i=i+1)begin
            data=(i*73+(i/256)*19);@(negedge clk);
            q=symbol[9]?~symbol[7:0]:symbol[7:0];decoded[0]=q[0];
            for(b=1;b<8;b=b+1)decoded[b]=symbol[8]?(q[b]^q[b-1]):~(q[b]^q[b-1]);
            if(decoded!==data)$fatal(1,"data reconstruct %h != %h",decoded,data);
            ones=0;for(j=0;j<10;j=j+1)ones=ones+symbol[j];
            balance=balance+2*ones-10;
            if(balance>8 || balance< -8)$fatal(1,"unbounded disparity %d",balance);
        end
        de=0;control=0;@(negedge clk);if(symbol!==10'b1101010100)$fatal(1,"blank reset");
        $display("PASS TMDS controls, all byte values, decode and bounded disparity");$finish;
    end
endmodule
