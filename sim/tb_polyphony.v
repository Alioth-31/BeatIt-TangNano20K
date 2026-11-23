`timescale 1ns/1ps
module tb_polyphony;
    parameter N=4;
    reg clk=0, rst=1, ce=0;
    reg [31:0] held=0;
    reg [1:0] preset=0;
    reg [16:0] volume=65536,bend=65536;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [N-1:0] active;
    integer i,f,wait_cycles,fd;
    reg [31:0] old_phase;
    synth_core #(.NUM_VOICES(N)) dut(clk,rst,ce,held,preset,volume,bend,pcm,valid,fault,busy,active,2'd0,17'd66048,2'd1,32'hffffffff,32'hffffffff,1'b0,6'd0,32'd0,224'd0,512'd0,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    task frame;
        begin
            @(negedge clk); ce=1; @(negedge clk); ce=0; wait_cycles=0;
            while(!valid && wait_cycles<1000) begin @(negedge clk); wait_cycles=wait_cycles+1; end
            if(!valid || fault) begin $display("FAIL deadline/fault N=%0d cycles=%0d",N,wait_cycles); $finish; end
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        for(i=0;i<N;i=i+1) held[i]=1;
        frame;
        if(active!=={N{1'b1}}) begin $display("FAIL simultaneous allocation %h",active); $finish; end
        for(i=0;i<N;i=i+1) if(dut.owner[i]!==i) begin $display("FAIL distinct owners"); $finish; end
        for(f=0;f<300;f=f+1) frame;
        preset=2; frame;
        if(dut.voice_preset[0]!==0) begin $display("FAIL active preset changed"); $finish; end
        old_phase=dut.phase[0]; bend=73562; frame;
        if(dut.phase[0]-old_phase!=dut.increment[0] || dut.bend_current!=65568) begin $display("FAIL phase continuity/smoothing"); $finish; end
        if(N==4) begin
            held[4]=1; frame;
            if(dut.env_state[0]!=5 || dut.fade_left[0]!=31) begin $display("FAIL oldest steal/fade"); $finish; end
            held[0]=0;
            repeat(31) frame;
            frame;
            if(dut.owner[0]!=4 || dut.env_state[0]==0 || dut.voice_preset[0]!=2) begin $display("FAIL replacement or old release"); $finish; end
            held[1]=0; frame;
            held[5]=1; frame;
            if(dut.pending_owner[1]!=5 || dut.env_state[1]!=5) begin $display("FAIL release-first selection"); $finish; end
            held[5]=0; repeat(34) frame;
            if(dut.env_state[1]!=0) begin $display("FAIL released pending note starts"); $finish; end
        end
        // N=4 also exercises the 300 ms preset above; other configurations
        // use the standard 120 ms / 5760 sample release.
        held=0; repeat((N==4)?15000:6000) frame;
        if(active!==0 || pcm!==0) begin $display("FAIL stuck tail"); $finish; end
        // Capture all independent oscillators for spectral analysis.
        preset=1; bend=65536;
        for(i=0;i<N;i=i+1) held[i]=1;
        repeat(6000) frame;
        if(N==4) fd=$fopen("build/poly4.pcm.txt","w");
        else if(N==8) fd=$fopen("build/poly8.pcm.txt","w");
        else if(N==16) fd=$fopen("build/poly16.pcm.txt","w");
        else fd=$fopen("build/poly32.pcm.txt","w");
        for(f=0;f<24000;f=f+1) begin frame; $fdisplay(fd,"%d",pcm); end
        $fclose(fd);
        // A new request while busy must fail closed.
        @(negedge clk); ce=1; repeat(3) @(negedge clk); ce=0;
        if(!fault) begin $display("FAIL missed overrun"); $finish; end
        $display("PASS %0d independent voices, envelope, allocation, deadline, overrun",N); $finish;
    end
endmodule
