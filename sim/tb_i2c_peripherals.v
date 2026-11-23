`timescale 1ns/1ps
`include "sim/i2c_peripheral_model.vh"
`timescale 1ns/1ps
module tb_i2c_peripherals;
    reg clk=0;always #5 clk=~clk;
    reg rst=1;reg [7:0] leds=8'h81;
    wire scl_r,sda_r,slave_r;wire scl=scl_r;wire sda=sda_r&slave_r;
    reg adc_on=1,led_on=1,stall=0,corrupt=0,power_cycle=0,reset_on_read=0;
    wire [47:0] samples;wire [3:0] valid;
    wire adc_available,led_available;wire [7:0] applied;wire sample_update,led_update;
    wire [1:0] channel;wire [1:0] last_error;
    wire [7:0] latch,ledcfg;wire [31:0] starts,writes;
    integer checks=0,updates=0,i; reg [31:0] old_starts,old_writes;
    i2c_peripherals #(.PRESCALE(4),.POLL_WAIT_CYCLES(250),.RETRY_CYCLES(10000),
        .HEALTH_CYCLES(30000),.CONVERSION_TIMEOUT_CYCLES(12000),.BUS_TIMEOUT_CYCLES(10000)) dut(
        .clk(clk),.rst(rst),.led_target(leds),.scl_i(scl),.sda_i(sda),
        .scl_release(scl_r),.sda_release(sda_r),.adc_samples(samples),.adc_valid(valid),
        .adc_available(adc_available),.led_available(led_available),.led_applied(applied),
        .sample_update(sample_update),.sample_channel(channel),.led_update(led_update),.last_error(last_error));
    i2c_peripheral_model model(clk,scl,sda,slave_r,adc_on,led_on,stall,corrupt,power_cycle,reset_on_read,latch,ledcfg,starts,writes);
    always @(posedge clk)if(sample_update)begin
        updates=updates+1;
        check(samples[channel*12+:12]!==12'd0,"reset conversion published as fresh");
        case(channel)
            0:check(samples[11:0]==12'h123,"old conversion attributed to pressure");
            1:check(samples[23:12]==12'h456,"old conversion attributed to X");
            2:check(samples[35:24]==12'hfff,"old conversion attributed to Y");
            3:check(samples[47:36]==12'h672,"old conversion attributed to Z");
        endcase
    end
    // Check every completed write, including requests captured while the
    // desired pattern changes each cycle. Never report a newer unsent value.
    always @(negedge clk)if(!rst && led_update)begin
        check(applied===~latch,"LED acknowledgement reported a different pattern from the device latch");
        check(led_available,"LED acknowledgement missing available flag");
    end
    task check;input ok;input[511:0]msg;begin checks=checks+1;if(!ok)begin $display("FAIL %0s",msg);$fatal(1);end end endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;
        wait(valid==15&&led_available);#1;
        check(samples===48'h672fff456123,"ADC channel order / signed 12-bit format");
        check(latch==8'h7e&&ledcfg==0&&applied==8'h81,"active-low LED initialization and delivery");
        old_starts=starts;
        // Changes during a transaction must converge to latest pattern.
        for(i=0;i<4096;i=i+1)begin @(negedge clk);leds=i;end
        leds=8'h42;wait(applied==8'h42);#1;check(latch==8'hbd,"latest LED value");
        repeat(20000)@(negedge clk);check(starts>old_starts+3,"LED traffic starved ADC");
        adc_on=0;wait(!adc_available);#1;check(valid==0,"missing ADC retained valid samples");
        leds=8'h24;wait(applied==8'h24);check(led_available,"ADC absence blocked LED");
        adc_on=1;wait(valid==15);check(adc_available,"ADC did not reconnect");
        stall=1;old_writes=writes;wait(!adc_available);#1;
        check(valid==0,"busy ADC returned stale conversion");
        leds=8'h55;wait(applied==8'h55);check(writes>old_writes,"conversion timeout blocked LED");
        stall=0;wait(valid==15);
        corrupt=1;wait(!adc_available);check(valid==0,"unexpected ADC reset/ledcfg accepted");
        corrupt=0;wait(valid==15);
        reset_on_read=1;wait(!adc_available);check(valid==0,"ADC poll/read reset not detected");
        reset_on_read=0;wait(valid==15);
        led_on=0;leds=8'haa;wait(!led_available);#1;
        check(applied!=8'haa,"NACK pattern falsely reported delivered");
        old_starts=starts;repeat(20000)@(negedge clk);check(starts>old_starts+3,"LED absence blocked ADC");
        led_on=1;wait(led_available&&applied==8'haa);check(latch==8'h55&&ledcfg==0,"LED reconnect initialization");
        @(negedge clk);power_cycle=1;@(negedge clk);power_cycle=0;
        wait(led_available&&ledcfg==0&&latch==8'h55);check(led_available,"silent LED power cycle not recovered");
        // ADC remains powered while FPGA resets in an in-progress X conversion.
        wait(model.countdown>0&&model.conversion_mux==5);
        @(negedge clk);model.countdown=5000;rst=1;
        repeat(8)@(negedge clk);rst=0;
        wait(valid==15);check(samples===48'h672fff456123,"FPGA-only reset changed sample ownership");
        $display("PASS peripherals %0d checks, %0d fresh ADC samples",checks,updates);$finish;
    end
    initial begin #10000000;$fatal(1,"peripheral timeout");end
endmodule
