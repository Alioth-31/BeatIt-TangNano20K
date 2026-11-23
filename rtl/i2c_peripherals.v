`timescale 1ns/1ps
// ADS1015 single-shot scanner and active-low TCA9534 LED driver.
// Purely asynchronous to audio requests: never gates sample_ce or direct keys.
// Outputs are raw signed ADC codes; calibration/expression is a separate layer.
module i2c_peripherals #(
    parameter PRESCALE=31,parameter POLL_WAIT_CYCLES=12288,
    parameter RETRY_CYCLES=491520,parameter HEALTH_CYCLES=4915200,
    parameter CONVERSION_TIMEOUT_CYCLES=196608,parameter BUS_TIMEOUT_CYCLES=491520
)(
    input clk,input rst,input [7:0] led_target,
    input scl_i,input sda_i,output scl_release,output sda_release,
    output reg [47:0] adc_samples,output reg [3:0] adc_valid,
    output reg adc_available,output reg led_available,output reg [7:0] led_applied,
    output reg sample_update,output reg [1:0] sample_channel,
    output reg led_update,output reg [1:0] last_error
);
    function integer clog2; input integer v;integer n;begin
        n=v-1;clog2=0;while(n>0)begin clog2=clog2+1;n=n>>1;end
    end endfunction
    localparam RW=(RETRY_CYCLES<2)?1:clog2(RETRY_CYCLES+1);
    localparam HW=(HEALTH_CYCLES<2)?1:clog2(HEALTH_CYCLES+1);
    localparam CW=(CONVERSION_TIMEOUT_CYCLES<2)?1:clog2(CONVERSION_TIMEOUT_CYCLES+1);
    localparam PW=(POLL_WAIT_CYCLES<2)?1:clog2(POLL_WAIT_CYCLES+1);
    localparam ADC_START=0,ADC_POLL=1,ADC_READ=2,LED_OFF=3,LED_DIR=4,LED_WRITE=5,LED_HEALTH=6,ADC_VERIFY=7,ADC_SYNC=8,ADC_IDLE=9;
    reg [3:0] operation;
    reg waiting,request_start;
    reg [6:0] address;reg [7:0] pointer;
    reg read_op,two_bytes;reg [15:0] write_data;
    wire transaction_busy,transaction_done;wire [1:0] transaction_error;wire [15:0] read_data;
    reg [2:0] adc_stage;
    reg [1:0] channel,led_stage;
    reg prefer_led;
    reg [7:0] sent_pattern;
    // Break the guide/menu combinational path before peripheral arbitration.
    // All request decisions and the transmitted byte use this same snapshot.
    // led_applied still describes only an acknowledged bus transaction.
    reg [7:0] led_requested;
    always @(posedge clk)begin
        if(rst)led_requested<=0;
        else led_requested<=led_target;
    end
    reg [11:0] pending_sample;
    reg [RW-1:0] adc_retry,led_retry;
    reg [HW-1:0] health_timer;
    reg [CW-1:0] conversion_timer;
    reg [PW-1:0] poll_timer;
    // OS=1, MUX=single-ended channel, PGA=+/-4.096V, single-shot,
    // DR=3300SPS, comparator disabled. ADC has 2mV/LSB at this range.
    wire [15:0] adc_config=16'hc3c3 | {1'b0,channel,12'b0};
    wire adc_due=(adc_retry==0)&&(adc_stage==0||adc_stage==4||poll_timer==0);
    wire led_due=(led_retry==0)&&(led_stage!=2||!led_available||led_requested!=led_applied||health_timer==0);
    i2c_register #(.PRESCALE(PRESCALE),.TIMEOUT_CYCLES(BUS_TIMEOUT_CYCLES)) bus(
        .clk(clk),.rst(rst),.start(request_start),.address(address),.reg_addr(pointer),
        .read_op(read_op),.two_bytes(two_bytes),.write_data(write_data),
        .busy(transaction_busy),.done(transaction_done),.error(transaction_error),.read_data(read_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_release(scl_release),.sda_release(sda_release));
    always @(posedge clk) begin
        if(rst)begin
            adc_samples<=0;adc_valid<=0;adc_available<=0;led_available<=0;led_applied<=0;
            sample_update<=0;sample_channel<=0;led_update<=0;last_error<=0;
            operation<=ADC_START;waiting<=0;request_start<=0;address<=0;pointer<=0;
            read_op<=0;two_bytes<=0;write_data<=0;adc_stage<=4;channel<=0;led_stage<=0;
            prefer_led<=1;sent_pattern<=0;pending_sample<=0;adc_retry<=0;led_retry<=0;health_timer<=0;
            conversion_timer<=0;poll_timer<=0;
        end else begin
            request_start<=0;sample_update<=0;led_update<=0;
            if(adc_retry!=0)adc_retry<=adc_retry-1'b1;
            if(led_retry!=0)led_retry<=led_retry-1'b1;
            if(health_timer!=0)health_timer<=health_timer-1'b1;
            if(poll_timer!=0)poll_timer<=poll_timer-1'b1;
            if(adc_stage!=0 && conversion_timer<CONVERSION_TIMEOUT_CYCLES)
                conversion_timer<=conversion_timer+1'b1;
            if(waiting)begin
                if(transaction_done)begin
                    waiting<=0;
                    if(transaction_error!=0)begin
                        last_error<=transaction_error;
                        if(operation<=ADC_READ||operation==ADC_VERIFY||operation==ADC_SYNC||operation==ADC_IDLE)begin
                            adc_available<=0;adc_valid<=0;adc_stage<=4;adc_retry<=RETRY_CYCLES;
                        end else begin led_available<=0;led_stage<=0;led_retry<=RETRY_CYCLES;end
                    end else case(operation)
                        ADC_START:begin adc_stage<=1;poll_timer<=POLL_WAIT_CYCLES;conversion_timer<=0;end
                        ADC_POLL:begin
                            // Match MUX/PGA/mode/rate as well as OS. A power-cycled
                            // converter must not publish a stale sample for this channel.
                            if(read_data[14:0]!=adc_config[14:0] || conversion_timer>=CONVERSION_TIMEOUT_CYCLES)begin
                                adc_available<=0;adc_valid<=0;adc_stage<=4;adc_retry<=RETRY_CYCLES;last_error<=3;
                            end else if(read_data[15])begin adc_stage<=2;poll_timer<=0;end
                            else poll_timer<=POLL_WAIT_CYCLES;
                        end
                        ADC_READ:begin
                            if(conversion_timer>=CONVERSION_TIMEOUT_CYCLES || read_data[3:0]!=0)begin
                                adc_available<=0;adc_valid<=0;adc_retry<=RETRY_CYCLES;last_error<=3;adc_stage<=4;
                            end else begin
                                pending_sample<=read_data[15:4];adc_stage<=3;
                            end
                        end
                        ADC_VERIFY:begin
                            // Detect a converter reset between ready polling and
                            // the conversion read. Only now publish the cached value.
                            if(read_data!=adc_config || conversion_timer>=CONVERSION_TIMEOUT_CYCLES)begin
                                adc_available<=0;adc_valid<=0;adc_retry<=RETRY_CYCLES;last_error<=3;adc_stage<=4;
                            end else begin
                                adc_samples[channel*12+:12]<=pending_sample;adc_valid[channel]<=1;
                                adc_available<=1;sample_update<=1;sample_channel<=channel;channel<=channel+1'b1;
                                adc_stage<=0;
                            end
                        end
                        ADC_SYNC:begin adc_stage<=5;poll_timer<=POLL_WAIT_CYCLES;conversion_timer<=0;end
                        ADC_IDLE:begin
                            // FPGA reset does not reset a still-powered ADC.
                            // OS=1 while busy is ignored: finish its old conversion
                            // in single-shot mode before starting our channel scan.
                            if(read_data[15])begin adc_stage<=0;poll_timer<=0;end
                            else if(conversion_timer>=CONVERSION_TIMEOUT_CYCLES)begin
                                adc_available<=0;adc_valid<=0;adc_retry<=RETRY_CYCLES;last_error<=3;adc_stage<=4;
                            end else poll_timer<=POLL_WAIT_CYCLES;
                        end
                        LED_OFF:begin led_stage<=1;led_available<=0;end
                        LED_DIR:led_stage<=2;
                        LED_WRITE:begin
                            led_applied<=sent_pattern;led_available<=1;led_update<=1;
                        end
                        LED_HEALTH:begin
                            health_timer<=HEALTH_CYCLES;
                            if(read_data[7:0]!=0)begin led_stage<=0;led_available<=0;end
                        end
                    endcase
                end
            end else if(!transaction_busy)begin
                // Alternate eligible devices; rapidly changing lights cannot
                // starve conversion polling, absent ADC cannot starve lights.
                if(led_due && (prefer_led||!adc_due))begin
                    address<=7'h20;two_bytes<=0;read_op<=0;pointer<=1;write_data<=16'h00ff;
                    if(led_stage==0)operation<=LED_OFF;
                    else if(led_stage==1)begin operation<=LED_DIR;pointer<=3;write_data<=0;end
                    else if(health_timer==0 && led_available)begin
                        operation<=LED_HEALTH;pointer<=3;read_op<=1;
                    end else begin
                        operation<=LED_WRITE;write_data<={8'd0,~led_requested};sent_pattern<=led_requested;
                        if(!led_available)health_timer<=HEALTH_CYCLES;
                    end
                    waiting<=1;request_start<=1;prefer_led<=0;
                end else if(adc_due)begin
                    address<=7'h48;two_bytes<=1;pointer<=1;write_data<=adc_config;read_op<=adc_stage!=0;
                    if(adc_stage==0)operation<=ADC_START;
                    else if(adc_stage==1)operation<=ADC_POLL;
                    else if(adc_stage==2)begin operation<=ADC_READ;pointer<=0;end
                    else if(adc_stage==3)operation<=ADC_VERIFY;
                    else if(adc_stage==4)begin operation<=ADC_SYNC;read_op<=0;write_data<=adc_config&16'h7fff;end
                    else operation<=ADC_IDLE;
                    waiting<=1;request_start<=1;prefer_led<=1;
                end
            end
        end
    end
endmodule
