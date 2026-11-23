`timescale 1ns/1ps
module tb_pcm_reverb;
`ifdef GOWIN_PRIMITIVES
    GSR GSR(1'b1);
`endif
    reg clk=0;always #5 clk=~clk;
    reg rst=1,in_valid=0,bypass=0;
    reg signed [15:0] in_pcm=0;
    reg [15:0] wet_target=32768;
    reg [1:0] room_size=0;
    wire signed [15:0] out_pcm;wire out_valid,fault,busy;
    integer fd,rc,sample_in,wet_in,room_in,bypass_in,reset_in,wanted;
    integer samples=0,cycles,max_cycles=0,outputs=0;
    reg [1023:0] vector_file;
    pcm_reverb dut(clk,rst,in_pcm,in_valid,bypass,wet_target,room_size,out_pcm,out_valid,fault,busy);
    always @(posedge clk)if(out_valid)outputs=outputs+1;
    initial begin
        if(!$value$plusargs("vectors=%s",vector_file))begin
            // Small default regression; numeric harness supplies full-size vectors.
            repeat(4)@(negedge clk);rst=0;
            repeat(600)begin
                in_pcm=0;in_valid=1;@(negedge clk);in_valid=0;
                cycles=0;
                while(!out_valid && cycles<95)begin @(negedge clk);cycles=cycles+1;end
                if(!out_valid||out_pcm!==0||fault)$fatal(1,"reverb reset/silence/deadline");
                repeat(3)@(negedge clk);
            end
        end else begin
            fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"cannot open reverb vectors");
            repeat(4)@(negedge clk);rst=0;
            while(!$feof(fd))begin
                rc=$fscanf(fd,"%d %d %d %d %d %d\n",sample_in,wet_in,room_in,bypass_in,reset_in,wanted);
                if(rc==6)begin
                    if(reset_in)begin rst=1;repeat(2)@(negedge clk);rst=0;end
                    in_pcm=sample_in;wet_target=wet_in;room_size=room_in;bypass=bypass_in;
                    in_valid=1;@(negedge clk);in_valid=0;cycles=0;
                    while(!out_valid && cycles<95)begin @(negedge clk);cycles=cycles+1;end
                    if(cycles>max_cycles)max_cycles=cycles;
                    if(!out_valid||fault||out_pcm!==wanted[15:0])begin
                        $display("FAIL reverb sample=%0d want=%0d got=%0d cycles=%0d",samples,wanted,out_pcm,cycles);$fatal(1);
                    end
                    samples=samples+1;repeat(3)@(negedge clk);
                end else if(!$feof(fd))$fatal(1,"invalid vector record");
            end
            $fclose(fd);
        end
        // Overrun cannot silently drop a sample or expose an old wet value.
        @(negedge clk);bypass=0;in_pcm=32767;in_valid=1;
        @(negedge clk);in_valid=0;repeat(2)@(negedge clk);in_valid=1;
        @(negedge clk);in_valid=0;
        if(!fault||out_pcm!==0)$fatal(1,"reverb overrun did not fault/mute");
        repeat(5)@(negedge clk);if(!fault)$fatal(1,"fault was not sticky");
        rst=1;repeat(3)@(negedge clk);rst=0;
        @(negedge clk);bypass=1;in_pcm=-12345;in_valid=1;
        @(negedge clk);in_valid=0;
        if(fault||!out_valid||out_pcm!==-16'sd12345)$fatal(1,"reset/bypass did not recover");
        $display("PASS reverb vectors=%0d max_cycles=%0d",samples,max_cycles);$finish;
    end
endmodule
