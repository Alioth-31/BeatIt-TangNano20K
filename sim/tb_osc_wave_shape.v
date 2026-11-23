`timescale 1ns/1ps
module tb_osc_wave_shape;
    reg [31:0] phase=0;
    reg [1:0] waveform=1;
    wire signed [15:0] sample;
    osc_wave_shape dut(phase,waveform,sample);

    task expect;
        input [31:0] p;
        input [1:0] w;
        input signed [15:0] value;
        begin
            phase=p; waveform=w; #1;
            if (sample !== value) begin
                $display("FAIL waveform=%d phase=%h expected=%d got=%d", w,p,value,sample);
                $finish;
            end
        end
    endtask
    initial begin
        expect(32'h00000000,1,-16'sd32768);
        expect(32'h40000000,1,-16'sd16384);
        expect(32'h80000000,1,16'sd0);
        expect(32'hc0000000,1,16'sd16384);
        expect(32'h00000000,2,16'sd32767);
        expect(32'h7fffffff,2,16'sd32767);
        expect(32'h80000000,2,-16'sd32767);
        expect(32'hffffffff,2,-16'sd32767);
        expect(32'h00000000,3,16'sd0);
        expect(32'h40000000,3,16'sd32767);
        expect(32'h80000000,3,16'sd0);
        expect(32'hc0000000,3,-16'sd32767);
        expect(32'h00000000,0,16'sd0);
        $display("PASS 32-bit DDS saw, DC-balanced pulse and triangle boundaries");
        $finish;
    end
endmodule
