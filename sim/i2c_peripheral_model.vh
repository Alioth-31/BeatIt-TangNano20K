`timescale 1ns/1ps
// Test-only pin-level model: TI register layout, no knowledge of DUT states.
module i2c_peripheral_model(input clk,input scl,input sda,output reg release_sda,
    input adc_online,input led_online,input adc_stalled,input corrupt_config,
    input led_power_cycle,input adc_reset_on_read,output reg [7:0] led_latch,output reg [7:0] led_config,
    output reg [31:0] conversion_starts,output reg [31:0] led_writes);
    localparam IDLE=0,ADDR=1,PTR=2,WRITE=3,ACK_SET=4,ACK=5,READ=6,READ_ACK=7;
    integer state=IDLE,next_state=IDLE,bits=0,byte_no=0;
    reg [7:0] byte_in=0,pointer=0,tx=0;
    reg [6:0] selected=0;
    reg rw=0,ack=0,master_ack=0;
    reg [15:0] adc_config=16'h8583,config_word=0;
    reg [15:0] conversion=0;
    reg [2:0] conversion_mux=4;
    integer countdown=0;
    function [15:0] adc_value;
        input [2:0] mux;
        begin case(mux)
          4:adc_value=16'h1230;5:adc_value=16'h4560;
          6:adc_value=16'hfff0;7:adc_value=16'h6720;
          default:adc_value=16'h8000;
        endcase end
    endfunction
    function [7:0] read_byte;
        input integer number; reg [15:0] word_value;
        begin
            if(selected==7'h20)read_byte=(pointer==3)?led_config:led_latch;
            else begin
                word_value=(pointer==0)?conversion:(corrupt_config?16'h8583:adc_config);
                read_byte=(number==0)?word_value[15:8]:word_value[7:0];
            end
        end
    endfunction
    initial begin release_sda=1;led_latch=8'hff;led_config=8'hff;conversion_starts=0;led_writes=0;end
    always @(posedge clk) begin
        if(led_power_cycle)begin led_latch=8'hff;led_config=8'hff;end
        if(countdown>0 && !adc_stalled)begin
            countdown=countdown-1;
            if(countdown==0)begin conversion=adc_value(conversion_mux);adc_config[15]=1;end
        end
    end
    always @(negedge sda) if(scl)begin state=ADDR;bits=0;byte_in=0;byte_no=0;end
    always @(posedge sda) if(scl)begin state=IDLE;release_sda=1;end
    always @(posedge scl) begin
        if(state==ADDR||state==PTR||state==WRITE)begin
            byte_in={byte_in[6:0],sda};bits=bits+1;
            if(bits==8)begin
                bits=0;
                if(state==ADDR)begin
                    selected=byte_in[7:1];rw=byte_in[0];byte_no=0;
                    if(selected==7'h48&&rw&&pointer==0&&adc_reset_on_read)begin
                        adc_config=16'h8583;conversion=0;countdown=0;
                    end
                    ack=(selected==7'h48&&adc_online)||(selected==7'h20&&led_online);
                    next_state=ack?(rw?READ:PTR):IDLE;
                end else if(state==PTR)begin pointer=byte_in;byte_no=0;ack=1;next_state=WRITE;end
                else begin
                    ack=1;next_state=WRITE;
                    if(selected==7'h20)begin
                        if(pointer==1)begin led_latch=byte_in;led_writes=led_writes+1;end
                        if(pointer==3)led_config=byte_in;
                    end else if(pointer==1)begin
                        if(byte_no==0)config_word[15:8]=byte_in;
                        else begin
                            config_word[7:0]=byte_in;adc_config=config_word;
                            // TI: writing OS while already converting does not
                            // restart that conversion or change its sampled MUX.
                            if(countdown>0)adc_config[15]=0;
                            else if(config_word[15])begin
                                adc_config[15]=0;countdown=400;conversion_starts=conversion_starts+1;
                                conversion_mux=config_word[14:12];
                            end else adc_config[15]=1;
                        end
                    end
                    byte_no=byte_no+1;
                end
                state=ACK_SET;
            end
        end else if(state==READ)bits=bits+1;
        else if(state==READ_ACK)master_ack=~sda;
    end
    always @(negedge scl)begin
        if(state==ACK_SET)begin release_sda=~ack;state=ACK;end
        else if(state==ACK)begin
            release_sda=1;state=next_state;bits=0;
            if(state==READ)begin tx=read_byte(byte_no);release_sda=tx[7];end
        end else if(state==READ)begin
            if(bits==8)begin release_sda=1;state=READ_ACK;end
            else release_sda=tx[7-bits];
        end else if(state==READ_ACK)begin
            if(master_ack)begin byte_no=byte_no+1;bits=0;tx=read_byte(byte_no);release_sda=tx[7];state=READ;end
            else begin release_sda=1;state=IDLE;end
        end
    end
endmodule
