`timescale 1ns/1ps
module tb_control_surface_buttons;
    reg clk=0,rst=1,volume_sw_n=1,bend_sw_n=1;
    wire volume_button_down,bend_button_down,preset_next,bend_reset;
    integer preset_pulses=0,bend_pulses=0;
    control_surface #(.DEBOUNCE_CYCLES(4),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk(clk),.rst(rst),.keys_n(8'hff),.volume_ab(2'b11),.volume_sw_n(volume_sw_n),
        .bend_ab(2'b11),.bend_sw_n(bend_sw_n),.test_button(1'b0),
        .preset_next(preset_next),.bend_reset(bend_reset),
        .volume_button_down(volume_button_down),.bend_button_down(bend_button_down));
    always #5 clk=~clk;
    always @(posedge clk) if(!rst) begin
        if(preset_next)preset_pulses=preset_pulses+1;
        if(bend_reset)bend_pulses=bend_pulses+1;
    end
    initial begin
        repeat(3) @(negedge clk);rst=0;repeat(3) @(negedge clk);
        if(volume_button_down!==0 || bend_button_down!==0) begin $display("FAIL released button level");$finish;end
        volume_sw_n=0;bend_sw_n=0;repeat(2) @(negedge clk);
        if(volume_button_down || bend_button_down) begin $display("FAIL short bounce reached button level");$finish;end
        volume_sw_n=1;bend_sw_n=1;repeat(10) @(negedge clk);
        if(volume_button_down || bend_button_down || preset_pulses || bend_pulses) begin $display("FAIL bounced press produced action");$finish;end
        volume_sw_n=0;bend_sw_n=0;repeat(18) @(negedge clk);
        if(volume_button_down!==1 || bend_button_down!==1 || preset_pulses!=1 || bend_pulses!=1) begin $display("FAIL debounced held level/legacy press events");$finish;end
        repeat(15) @(negedge clk);
        if(!volume_button_down || !bend_button_down || preset_pulses!=1 || bend_pulses!=1) begin $display("FAIL long hold repeated events");$finish;end
        volume_sw_n=1;bend_sw_n=1;repeat(15) @(negedge clk);
        if(volume_button_down || bend_button_down || preset_pulses!=1 || bend_pulses!=1) begin $display("FAIL release level/legacy compatibility");$finish;end
        rst=1;@(negedge clk);
        if(volume_button_down || bend_button_down) begin $display("FAIL button level asserted under reset");$finish;end
        $display("PASS debounced held button levels preserve legacy event semantics");$finish;
    end
endmodule
