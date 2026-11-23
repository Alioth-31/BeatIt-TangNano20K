`timescale 1ns/1ps
module tb_app_system;
    reg clk=0,reset=1,rx=1;
    reg [7:0] keys=8'hff;
    wire tx,bck,ws,sd,pa;
    wire [5:0] leds;
    integer i,positive=0,negative=0,pcm_count=0;
    reg [15:0] crc;
    nano20k_app_top #(.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(keys),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),
        .uart_rx(rx),.uart_tx(tx),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(sd),.PA_EN(pa),.led_n(leds));
    always #5 clk=~clk;
    always @(posedge clk) if(dut.pcm_valid) begin
        pcm_count=pcm_count+1;
        if(dut.pcm>0) positive=positive+1;
        if(dut.pcm<0) negative=negative+1;
    end
    task byte_out; input [7:0] value; integer b;
        begin
            rx=0; repeat(427) @(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=value[b]; repeat(427) @(negedge clk); end
            rx=1; repeat(427) @(negedge clk);
        end
    endtask
    task crc_byte; input [7:0] value; integer b;
        begin
            byte_out(value); crc=crc ^ {value,8'h00};
            for(b=0;b<8;b=b+1) crc=crc[15]?(crc<<1)^16'h1021:(crc<<1);
        end
    endtask
    task set_keys; input [31:0] mask;
        begin
            crc=16'hffff; byte_out(8'ha5); byte_out(8'h5a);
            crc_byte(1); crc_byte(8'h12); crc_byte(1); crc_byte(0); crc_byte(4);
            crc_byte(mask[7:0]); crc_byte(mask[15:8]); crc_byte(mask[23:16]); crc_byte(mask[31:24]);
            byte_out(crc[7:0]); byte_out(crc[15:8]); repeat(2000) @(negedge clk);
        end
    endtask
    initial begin
        repeat(10) @(negedge clk); reset=0; repeat(3000) @(negedge clk);
        set_keys(32'h55); repeat(400000) @(negedge clk);
        if(dut.active!==4'hf || !pa || dut.audio_fault || positive==0 || negative==0) begin
            $display("FAIL remote UART to real synth/I2S active=%h pa=%b fault=%b",dut.active,pa,dut.audio_fault); $finish;
        end
        // Holding a physical key survives a remote panic.
        keys=8'hdf; repeat(3000) @(negedge clk); set_keys(0);
        if((dut.held_keys & 32'h20)==0) begin $display("FAIL source ownership after panic"); $finish; end
        keys=8'hff; repeat(6100000) @(negedge clk);
        if(dut.active!=0 || dut.held_keys!=0 || dut.pcm!=0 || dut.audio_fault) begin
            $display("FAIL release tail or stream fault"); $finish;
        end
        reset=1; repeat(20) @(negedge clk);
        if(pa || sd || tx!==1'b1) begin $display("FAIL app reset mute/UART idle"); $finish; end
        $display("PASS UART chord drives signed PCM/I2S, physical ownership, release and reset (%0d frames)",pcm_count); $finish;
    end
    initial begin #100000000; $display("FAIL integrated app timeout"); $finish; end
endmodule
