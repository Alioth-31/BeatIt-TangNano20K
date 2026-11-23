`timescale 1ns/1ps
module tb_system;
    reg clk=0,reset_button=1,test_button=0;
    reg [7:0] keys_n=8'hff;
    reg [1:0] vab=3,bab=3;
    reg vsw=1,bsw=1;
    wire bclk,ws,sd,enable;
    wire [5:0] leds;
    integer samples=0,fd,cycle_count=0,input_cycle=0,pcm_cycle=0,i2s_cycle=0,latency_fd;
    reg [31:0] capture=0;
    integer bits=0;
    reg lastws=0,aligned=0;
    reg [15:0] left_sample=0;
    reg have_left=0;
    nano20k_synth_top dut(clk,reset_button,test_button,keys_n,vab,vsw,bab,bsw,bclk,ws,sd,enable,leds);
    always #5 clk=~clk;
    always @(posedge clk) begin
        cycle_count=cycle_count+1;
        if(!reset_button && keys_n!=8'hff && dut.pcm_valid && dut.pcm!=0 && pcm_cycle==0)
            pcm_cycle=cycle_count;
    end
    always @(posedge bclk) begin
        if(ws!=lastws) begin lastws=ws; bits=0; capture=0; aligned=1; end
        else if(aligned) begin
            capture={capture[30:0],sd}; bits=bits+1;
            if(bits==16 && !ws && samples<30000) begin
                left_sample=capture[15:0]; have_left=1;
                if(capture[15:0]!=0 && i2s_cycle==0) i2s_cycle=cycle_count;
                $fdisplay(fd,"%d",$signed(capture[15:0])); samples=samples+1;
            end
            if(bits==16 && ws && have_left && capture[15:0]!==left_sample) begin $display("FAIL L/R frame coherence"); $finish; end
        end
    end
    initial begin
        fd=$fopen("build/tone440_i2s.pcm.txt","w");
        repeat(5) @(negedge clk); reset_button=0;
        // Real default 2 ms debounce, followed by a 440-Hz note on key index 5.
        keys_n=8'hdf;
        input_cycle=cycle_count;
        wait(dut.core.active!=0);
        if($time/10>110000) begin $display("FAIL input-to-state latency"); $finish; end
        wait(samples==30000); $fclose(fd);
        if(pcm_cycle==0 || i2s_cycle==0 || i2s_cycle-input_cycle>491520) begin
            $display("FAIL input-to-PCM/I2S latency"); $finish;
        end
        latency_fd=$fopen("build/system_latency.json","w");
        $fdisplay(latency_fd,"{\"input_to_pcm_cycles\":%0d,\"input_to_i2s_cycles\":%0d,\"clock_hz\":49152000}",pcm_cycle-input_cycle,i2s_cycle-input_cycle);
        $fclose(latency_fd);
        if(dut.core_fault || dut.tx_fault || !enable) begin $display("FAIL integrated stream"); $finish; end
        reset_button=1; repeat(20) @(negedge clk);
        if(enable || sd) begin $display("FAIL reset mute"); $finish; end
        $display("PASS top-level default debounce, PCM-to-I2S, reset, continuous 440-Hz capture"); $finish;
    end
    initial begin #400000000; $display("FAIL system timeout"); $finish; end
endmodule
