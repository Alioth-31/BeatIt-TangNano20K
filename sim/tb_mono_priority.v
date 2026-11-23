`timescale 1ns/1ps
// Catch highest-pitch/source shortcuts, lost fallback, stale instance parity,
// duration counter wrap and accidental legato at a poly/mono transition.
module tb_mono_priority;
    reg clk=0,rst=1,ce=0,enable=0;
    reg [39:0] held=0;
    reg [639:0] instances=0;
    wire [39:0] routed;
    wire done,mode,legato,fault;
    wire [5:0] selected;
    integer checks=0,cycles,i;
`ifdef LEGACY_MONO_RED
    assign routed=held;assign done=ce;assign mode=enable;
    assign legato=0;assign selected=0;assign fault=0;
`else
    mono_priority #(.SEQUENTIAL_INSTANCE_ENABLE(1)) dut(
        clk,rst,ce,enable,held,instances,done,routed,selected,mode,legato,fault);
`endif
    always #5 clk=~clk;
    task require;
        input ok;input [767:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL %0s",label);$finish;end end
    endtask
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);cycles=0;
            // done may be coincident with ce for the old direct adapter.
            if(!done)begin ce=0;while(!done && cycles<160)begin @(negedge clk);cycles=cycles+1;end end
            require(done && !fault && cycles<160,"bounded priority routing latency");ce=0;
            @(negedge clk);
        end
    endtask
    task expect;
        input [39:0] want;input lg;
        begin frame;require(routed==want,"most recently pressed held source wins");
            require(legato==lg,"legato reflects a continuous routed gate");end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;
        held=40'h1000000001;expect(held,0); // poly passes both endpoints
        enable=1;expect(0,0); // mode change releases the old poly owners
        expect(40'h1000000000,0);
        held[2]=1;instances[32+:16]=1;expect(4,1);
        held[2]=0;expect(40'h1000000000,1);
        // A held source with a new instance is a new press, even if its
        // source ID and pitch are lower than the current winner.
        instances[0+:16]=1;expect(1,1);
        instances[0+:16]=2;expect(1,1);
        held[0]=0;expect(40'h1000000000,1);
        held=0;expect(0,0);
        held=40'hffffffffff;
        for(i=0;i<40;i=i+1)instances[i*16+:16]=instances[i*16+:16]+1;
        expect(40'h8000000000,0);
        for(i=39;i>0;i=i-1)begin held[i]=0;expect(40'b1<<(i-1),1);end
        held=0;expect(0,0);
        held[3]=1;expect(8,0);
        instances[3*16+:16]=instances[3*16+:16]+1;expect(8,0);
        // No continuing source instance: simultaneous release/new press is
        // a new phrase, not legato merely because each frame has a note.
        held=16;instances[4*16+:16]=instances[4*16+:16]+1;expect(16,0);
        enable=0;held[8]=1;expect(0,0);expect(held,0);
        require(!mode,"poly mode restored explicitly");
        $display("PASS mono priority40 sources, re-press, LRU fallback and mode boundaries (%0d checks)",checks);$finish;
    end
endmodule
