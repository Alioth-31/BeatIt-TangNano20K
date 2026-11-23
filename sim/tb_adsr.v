`timescale 1ns/1ps
module tb_adsr;
    reg [2:0] state=1;
    reg [24:0] level=0, release_step=0;
    reg [14:0] remaining=240;
    reg [1:0] preset=0;
    reg gate=1;
    wire [2:0] next_state;
    wire [24:0] next_level,next_step;
    wire [14:0] next_remaining;
    integer p,i,at,dt,rt;
    reg [24:0] sustain, previous;
    adsr_step dut(state,level,remaining,release_step,preset,gate,next_state,next_level,next_remaining,next_step);
    task tick; begin #5; state=next_state; level=next_level; remaining=next_remaining; release_step=next_step; #5; end endtask
    initial begin
        for(p=0;p<3;p=p+1) begin
            preset=p; at=(p==1)?96:240; dt=(p==0)?3840:(p==1)?4800:9600;
            rt=(p==0)?5760:(p==1)?2880:14400;
            sustain=(p==0)?11744051:(p==1)?5033165:13421773;
            state=1; level=0; remaining=at; gate=1;
            for(i=0;i<at;i=i+1) begin previous=level; tick; if(level<previous) begin $display("FAIL attack monotonic"); $finish; end end
            if(state!=2 || level!=16777216) begin $display("FAIL attack duration"); $finish; end
            for(i=0;i<dt;i=i+1) begin previous=level; tick; if(level>previous) begin $display("FAIL decay monotonic"); $finish; end end
            if(state!=3 || level!=sustain) begin $display("FAIL sustain"); $finish; end
            repeat(20) tick;
            gate=0;
            for(i=0;i<rt;i=i+1) begin previous=level; tick; if(level>previous) begin $display("FAIL release monotonic"); $finish; end end
            if(state!=0 || level!=0) begin $display("FAIL release duration"); $finish; end
            state=1; level=100; remaining=at; gate=0;
            for(i=0;i<rt;i=i+1) tick;
            if(state!=0 || level!=0) begin $display("FAIL early release"); $finish; end
        end
        $display("PASS ADSR three presets, durations, monotonicity and early release"); $finish;
    end
endmodule
