`timescale 1ns/1ps
// Exercise real Gowin OSER10/TLVDS models. Controlled PLL clocks allow loss
// and recovery without treating an analog PLL model as hardware evidence.
module tb_hdmi_wire;
    reg fc=0,locked=0,rst=1,run=1,gsr_n=0;
    reg [7:0] red=0,green=8'h55,blue=8'ha7,last_red=0;
    reg have_previous=0;reg [7:0] bytes[0:2];
    wire pixel,vr,cp,cn;wire [2:0] dp,dn;
    reg [9:0] words[0:2];reg old_clock=0;integer bit_number=-1,checks=0,k,warmup=0,phase,before_checks;
    reg [7:0] q,decoded;reg [7:0] expected;
    GSR GSR(gsr_n);
    hdmi_output dut(1'b0,rst,red,green,blue,1'b1,1'b1,1'b1,pixel,vr,cp,cn,dp,dn);
    always #2 if(run)fc=~fc;
    always @(negedge pixel)begin
        if(vr)begin red<=0;green<=8'h55;blue<=8'ha7;end
        else begin red<=red+1'b1;green<=(red+8'd1)^8'h55;blue<=(red+8'd1)^8'ha7;end
    end
    always @(fc)begin
        #0.01;
        if(!rst && !vr)begin
            if(cp && !old_clock)bit_number=0;
            if(bit_number>=0 && bit_number<10)begin
                for(k=0;k<3;k=k+1)words[k][bit_number]=dp[k];
                if(bit_number==9 && warmup>=10)begin
                    for(k=0;k<3;k=k+1)begin
                        q=words[k][9]?~words[k][7:0]:words[k][7:0];decoded[0]=q[0];
                        decoded[1]=words[k][8]?(q[1]^q[0]):~(q[1]^q[0]);
                        decoded[2]=words[k][8]?(q[2]^q[1]):~(q[2]^q[1]);
                        decoded[3]=words[k][8]?(q[3]^q[2]):~(q[3]^q[2]);
                        decoded[4]=words[k][8]?(q[4]^q[3]):~(q[4]^q[3]);
                        decoded[5]=words[k][8]?(q[5]^q[4]):~(q[5]^q[4]);
                        decoded[6]=words[k][8]?(q[6]^q[5]):~(q[6]^q[5]);
                        decoded[7]=words[k][8]?(q[7]^q[6]):~(q[7]^q[6]);
                        bytes[k]=decoded;
                        if(dp[k]!==!dn[k])$fatal(1,"differential lane");
                    end
                    if(bytes[0] !== (bytes[2]^8'ha7) || bytes[1] !== (bytes[2]^8'h55))$fatal(1,"serialized channel/bit alignment %h %h %h",bytes[0],bytes[1],bytes[2]);
                    if(have_previous && bytes[2] !== last_red+8'd1)$fatal(1,"serialized pixel duplicated/lost %h -> %h",last_red,bytes[2]);
                    last_red=bytes[2];have_previous=1;
                    checks=checks+1;
                end
                if(bit_number==9)warmup=warmup+1;
                bit_number=bit_number+1;
            end
        end else begin bit_number=-1;warmup=0;have_previous=0;end
        old_clock=cp;
    end
    initial begin
        force dut.serial_clk=fc;force dut.locked=locked;
        #5;gsr_n=1;#25;locked=1;rst=0;
        #1000;
        if(checks<20)$fatal(1,"no valid serialized words");
        for(phase=0;phase<8;phase=phase+1)begin
            before_checks=checks;locked=0;#1;run=0;#10;
            if(!vr)$fatal(1,"lost PLL did not hold pixel reset");
            #(30+phase);run=1;locked=1;#1000;
            if(checks-before_checks<30)$fatal(1,"serializer failed to recover");
        end
        $display("PASS Gowin OSER10 wire decode/channel/bit order, differential outputs, clock loss/recovery (%d words)",checks);$finish;
    end
endmodule
