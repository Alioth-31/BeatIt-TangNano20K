`timescale 1ns/1ps
module tb_guide_onsets;
    reg clk=0,rst=1,ce=0,toggle=0,run_set=0,run_value=0;reg [7:0] keys=0;
    wire [7:0] target,missed,wrong;wire ready,running,done;wire [3:0] step;
    localparam [55:0] MAP={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    guide_engine #(.SAMPLE_HZ(240),.CONTROL_ENABLED(1)) dut(clk,rst,ce,1'b1,1'b0,toggle,1'b0,1'b0,2'd2,
        MAP,MAP,keys,1'b0,1'b1,3'd0,,target,running,ready,,done,step,missed,wrong,,run_set,run_value);
    always #5 clk=~clk;
    task frame;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(3)@(negedge clk);end endtask
    task start;
        begin rst=1;keys=0;repeat(4)@(negedge clk);rst=0;wait(ready);@(negedge clk);toggle=1;@(negedge clk);toggle=0;frame();end
    endtask
    initial begin
        start();keys=1;repeat(240)frame();
        if(step!=2||missed!=1||wrong!=1)begin $display("FAIL held repeated C counted as new attack: step%0d missed%0d wrong%0d",step,missed,wrong);$finish;end
        start();keys=1;repeat(90)frame();keys=0;repeat(30)frame();keys=1;repeat(120)frame();
        if(step!=2||missed!=0||wrong!=0)begin $display("FAIL released/repressed repeat not accepted");$finish;end
        start();keys=1;repeat(90)frame();keys=0;repeat(29)frame();keys=1;frame();
        if(step!=1||wrong!=0)begin $display("FAIL boundary repeated onset falsely penalizes previous event");$finish;end
        repeat(119)frame();keys=2;frame();
        if(step!=2||missed!=0||wrong!=0)begin $display("FAIL boundary different pitch double-counted as old wrong note");$finish;end
        repeat(120)frame();
        if(step!=3||missed!=0||wrong!=0)begin $display("FAIL boundary onset not retained by next event");$finish;end
        start();keys=1;run_set=1;run_value=1;frame();run_set=0;repeat(89)frame();
        if(target!=0)begin $display("FAIL redundant START swallowed one timing sample");$finish;end
        frame();if(missed!=0)begin $display("FAIL redundant START lost same-frame correct onset");$finish;end
        // A note held before pressing start is not a new strike in the score.
        rst=1;keys=1;repeat(4)@(negedge clk);rst=0;wait(ready);repeat(3)@(negedge clk);
        toggle=1;@(negedge clk);toggle=0;frame();repeat(90)frame();
        if(missed!=1)begin $display("FAIL pre-held key accepted as new event onset");$finish;end
        $display("PASS guide repeated-note and pre-held onset discrimination");$finish;
    end
endmodule
