`timescale 1ns/1ps
module tb_guide_control;
    reg clk=0,rst=1,ce=0,commit=0,ui=0,settings=0,toggle=0;
    reg [63:0] request=0;reg[2:0]field=0;reg[7:0]value=0;
    wire valid,enabled,song;wire[1:0]tempo;wire[7:0]leds;wire[127:0]query;wire[63:0]display_state;
    localparam[55:0]MAP={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    integer checks=0;
    guide_control #(.SAMPLE_HZ(240)) dut(clk,rst,ce,request,commit,valid,query,
        ui,field,value,settings,field,toggle,MAP,MAP,8'd0,1'b0,1'b1,8'h15,
        enabled,song,tempo,leds,display_state);
    always #5 clk=~clk;
    task frame;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(30)@(negedge clk);end endtask
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide control %0s",msg);$finish;end end endtask
    task command;input[31:0]payload;begin @(negedge clk);request=payload;commit=1;@(negedge clk);commit=0;request=0;repeat(4)frame();end endtask
    task panel;input[2:0]f;input[7:0]v;begin @(negedge clk);field=f;value=v;ui=1;@(negedge clk);ui=0;end endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;frame();check(!enabled,"default free performance");
        command(32'h01020001);check(enabled&&!song&&tempo==2&&display_state[1],"config and explicit start accepted");
        check(query[31:0]==32'h07020001&&query[63:56]==8'h15,"authoritative config/status and actual LED delivery query");
        command(32'h00020001);check(!display_state[1],"explicit pause");
        // Two host commits can queue only one audio sample apart. START and
        // PAUSE are absolute requests, never delayed toggles of stale state.
        @(negedge clk);request=32'h01020001;commit=1;@(negedge clk);commit=0;frame();
        command(32'h00020001);check(!display_state[1],"queued start then pause keeps last requested paused state");
        @(negedge clk);request=32'h01020001;commit=1;@(negedge clk);commit=0;frame();
        command(32'h01020001);check(display_state[1],"repeated queued start is idempotent");
        @(negedge clk);request=32'h01020001;commit=1;@(negedge clk);commit=0;
        @(negedge clk);ce=1;toggle=1;@(negedge clk);ce=0;toggle=0;repeat(30)@(negedge clk);
        check(display_state[1],"same-frame absolute START wins over local toggle");
        command(32'h00020001);
        command(32'h01040001);check(tempo==2&&!display_state[1],"invalid tempo rejects all changes");
        settings=1;panel(4,1);panel(5,1);frame();check(song&&tempo==1&&!display_state[1],"multiple pending panel fields retained");
        command(32'h01020101);settings=0;repeat(3)frame();check(!display_state[1],"start received in settings cannot auto-resume later");
        @(negedge clk);toggle=1;@(negedge clk);toggle=0;frame();check(display_state[1]&&leds==8'h15,"physical resume does not require ADC or host");
        command(32'h02020101);check(!display_state[1]&&display_state[11:8]==0,"rewind pauses at first event");
        panel(3,0);frame();check(!enabled,"panel selects free performance");
        $display("PASS guide authority %0d checks",checks);$finish;
    end
endmodule
