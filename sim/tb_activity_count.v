`timescale 1ns/1ps
// Status population count must be exact and registered, not a long path from
// live envelope states through the count into response/HDMI decode.
module tb_activity_count #(parameter N=32);
    reg clk=0,reset=1;reg[N-1:0]mask=0;reg[5:0]previous=0,held=0;
    integer i;reg[N-1:0]bits;
    nano20k_app_top #(.NUM_VOICES(N),.CONTROLS_ENABLED(0)) dut(
        .clk_audio(clk),.reset_button(reset),.test_button(1'b0),.keys_n(8'hff),
        .volume_ab(2'b11),.volume_sw_n(1'b1),.bend_ab(2'b11),.bend_sw_n(1'b1),.uart_rx(1'b1));
    always #5 clk=~clk;
    function[5:0]count;input[N-1:0]value;reg[N-1:0]v;begin
        v=value;count=0;while(v!=0)begin count=count+1'b1;v=v&(v-1'b1);end
    end endfunction
    task sample;input[N-1:0]value;begin
        @(negedge clk);held=dut.active_count;mask=value;#1;
        if(dut.active_count!==held)$fatal(1,"count changes without registered boundary");
        @(posedge clk);#1;
        if(dut.active_count!==previous)$fatal(1,"pipelined count N=%d got=%d expected=%d",N,dut.active_count,previous);
        previous=count(value);
    end endtask
    initial begin
        force dut.active=mask;
        repeat(3)@(negedge clk);reset=0;wait(!dut.rst);repeat(2)@(negedge clk);
        sample({N{1'b1}});sample(0);sample({N{1'b1}});
        for(i=0;i<N;i=i+1)begin bits=0;bits[i]=1;sample(bits);end
        for(i=0;i<1000;i=i+1)sample($random);
        sample(0);sample(0);reset=1;repeat(3)@(negedge clk);
        if(dut.active_count!==0)$fatal(1,"count not reset");
        release dut.active;
        $display("PASS registered activity count N=%0d one-hot, all-active,1000 random and reset",N);$finish;
    end
endmodule
