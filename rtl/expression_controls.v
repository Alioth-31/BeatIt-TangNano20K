`timescale 1ns/1ps
// Adapt the validated peripheral driver, calibration mapper and control DSPs.
// Bus recovery never stops the audio clock. Missing ADC => unity/neutral.
module expression_controls(
    input clk,input rst,input sample_ce,
    input [16:0] volume,input [16:0] bend_a,input [16:0] bend_b,
    input [7:0] led_target,input scl_i,input sda_i,output scl_release,output sda_release,
    input [63:0] config_request,input config_commit,
    output config_valid,output [111:0] config_query,
    output [16:0] effective_volume,output [16:0] effective_a,output [16:0] effective_b,
    output fault,output led_available,output [7:0] led_applied
);
    wire [47:0] samples;wire [3:0] valid;wire adc_available,update;
    wire [1:0] channel,last_error;
    wire [95:0] calibration;wire [2:0] cal_mask,enables,calibrated,active;
    wire cal_commit,invert_x,map_fault,pitch_fault,mix_fault;
    wire [16:0] gain,depth,pitch;wire signed [17:0] position;
    assign fault=map_fault|pitch_fault|mix_fault;
    i2c_peripherals peripherals(.clk(clk),.rst(rst),.led_target(led_target),
        .scl_i(scl_i),.sda_i(sda_i),.scl_release(scl_release),.sda_release(sda_release),
        .adc_samples(samples),.adc_valid(valid),.adc_available(adc_available),
        .led_available(led_available),.led_applied(led_applied),.sample_update(update),
        .sample_channel(channel),.led_update(),.last_error(last_error));
    expression_config #(.PRESSURE_ENABLED(0)) config_store(clk,rst,config_request,config_commit,config_valid,
        cal_commit,calibration,cal_mask,invert_x,enables,samples,valid,adc_available,active,
        led_available,led_applied,last_error,fault,config_query);
    expression_mapper mapper(clk,rst,sample_ce,samples,valid,adc_available,update,channel,
        cal_commit,calibration,cal_mask,invert_x,enables,gain,position,depth,calibrated,active,,map_fault);
    pitch_modulation modulation(clk,rst,sample_ce,position,depth,pitch,,pitch_fault);
    // Pressure input was removed from the instrument; only the volume knob
    // and protocol master-volume setting control loudness.
    expression_mix mix(clk,rst,sample_ce,volume,bend_a,bend_b,17'd65536,pitch,
        effective_volume,effective_a,effective_b,,mix_fault);
endmodule
