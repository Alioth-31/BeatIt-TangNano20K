`timescale 1ns/1ps
module tb_input_monitor;
    reg clk=0,reset=1;
    reg [7:0] pins=8'hff;
    nano20k_app_top #(.DEBOUNCE_CYCLES(8),.CONTROLS_ENABLED(1)) attached(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(pins),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1));
    nano20k_app_top #(.DEBOUNCE_CYCLES(8),.CONTROLS_ENABLED(0)) unwired(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(pins),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1));
    always #5 clk=~clk;
    initial begin
        repeat(10) @(negedge clk); reset=0; repeat(30) @(negedge clk);
        pins=8'hfd; repeat(3) @(negedge clk);
        if(attached.raw_keys_sync!=8'hfd || attached.held!=0) begin
            $display("FAIL raw synchronization versus debounce"); $finish;
        end
        repeat(3000) @(negedge clk);
        if(attached.held_keys!=2 || unwired.held_keys!=0 || unwired.raw_keys_sync!=8'hfd) begin
            $display("FAIL attached/unwired profile separation"); $finish;
        end
        pins=8'hff; repeat(3000) @(negedge clk);
        if(attached.held_keys!=0) begin $display("FAIL physical release"); $finish; end
        $display("PASS synchronized raw pins, debounce and explicit unwired input profile"); $finish;
    end
endmodule
