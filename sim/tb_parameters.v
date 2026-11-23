`timescale 1ns/1ps
module tb_parameters;
    reg clk=0,rst=1;
    reg [1:0] vab=3,bab=3;
    reg vsw=1,bsw=1,test_button=0;
    wire [7:0] held;
    wire [16:0] volume,bend;
    wire [1:0] preset,mode;
    integer i;
    control_surface #(.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2))
        dut(.clk(clk),.rst(rst),.keys_n(8'hff),.volume_ab(vab),.volume_sw_n(vsw),
            .bend_ab(bab),.bend_sw_n(bsw),.test_button(test_button),.held(held),
            .volume(volume),.bend(bend),.preset(preset),.test_mode(mode));
    always #5 clk=~clk;
    task turn; input reverse; input knob; integer edge_id; reg [1:0] code;
        begin
            for(edge_id=0;edge_id<4;edge_id=edge_id+1) begin
                case(edge_id) 0:code=reverse?1:2; 1:code=0; 2:code=reverse?2:1; default:code=3; endcase
                if(knob) bab=code; else vab=code;
                repeat(12) @(negedge clk);
            end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        if(volume!=16384 || bend!=65536 || preset!=0 || mode!=0) begin $display("FAIL defaults"); $finish; end
        repeat(60) turn(0,0);
        if(volume!=65536) begin $display("FAIL max volume"); $finish; end
        repeat(60) turn(1,0);
        if(volume!=0) begin $display("FAIL min volume"); $finish; end
        repeat(40) turn(0,1);
        if(bend!=73562) begin $display("FAIL bend max %d",bend); $finish; end
        repeat(80) turn(1,1);
        if(bend!=58386) begin $display("FAIL bend min %d",bend); $finish; end
        bsw=0; repeat(20) @(negedge clk);
        if(bend!=65536) begin $display("FAIL bend reset"); $finish; end
        for(i=1;i<=3;i=i+1) begin
            vsw=0; test_button=1; repeat(20) @(negedge clk);
            if(preset!=i%3 || mode!=i%3) begin $display("FAIL preset/mode cycle"); $finish; end
            vsw=1; test_button=0; repeat(20) @(negedge clk);
        end
        $display("PASS parameter limits, bend center, preset and mode buttons"); $finish;
    end
endmodule
