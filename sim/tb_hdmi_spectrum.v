`timescale 1ns/1ps
module tb_hdmi_spectrum;
    reg clk=0,valid=0;
    reg [9:0] x=0,y=0;
    reg signed [7:0] pcm=0;
    wire fetch,hit;
    integer row,col;
    real phase;
    hdmi_spectrum dut(clk,x,y,valid,pcm,fetch,hit);
    always #5 clk=~clk;
    always @(posedge clk)begin
        phase=6.283185307179586*x/256.0;
        pcm<=$rtoi(32.0*$cos(2.0*phase)+64.0*$sin(6.0*phase));
    end
    task pixel;
        input [4:0] bin;
        input [9:0] scan_y;
        input wanted;
        begin
            @(negedge clk);x=10'd7+{bin,4'b0};y=scan_y;
            repeat(3)@(negedge clk);
            if(hit!==wanted)$fatal(1,"bin %d row %d got %b want %b",bin,scan_y,hit,wanted);
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);
        valid=1;
        for(row=492;row<524;row=row+1)begin
            for(col=0;col<771;col=col+1)begin
                @(negedge clk);y=row;x=col;
            end
        end
        pixel(1,425,1);pixel(1,410,0);
        pixel(5,400,1);pixel(5,375,0);
        pixel(0,447,0);pixel(2,447,0);pixel(3,447,0);
        pixel(4,447,0);pixel(6,447,0);pixel(7,447,0);
        pixel(31,447,0);
        @(negedge clk);valid=0;
        pixel(5,440,0);
        $display("PASS two real spectral peaks, quadrature phases, empty bins and valid gating");
        $finish;
    end
endmodule
