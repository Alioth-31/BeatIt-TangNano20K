`timescale 1ns/1ps
// Bounded extension of the existing eight-byte command payload.
// SET: channel8, flags8 (enable, X reverse), signed LE16 low/centre/high.
// Pressure uses low/high only and requires centre=0. A write is explicit
// calibration, never inferred from the first sample. Configuration is volatile.
module expression_config #(parameter PRESSURE_ENABLED=1)(
    input clk,input rst,input [63:0] request,input commit,output request_valid,
    output reg cal_commit,output reg [95:0] calibration,
    output reg [2:0] calibration_mask,output reg invert_x,output reg [2:0] enable_mask,
    input [47:0] adc_samples,input [3:0] adc_valid,input adc_available,
    input [2:0] active,input led_available,input [7:0] led_applied,
    input [1:0] last_error,input arithmetic_fault,output reg [111:0] query
);
    `include "expression_boot.vh"
    reg boot_pending;
    wire [7:0] channel=request[7:0],flags=request[15:8];
    wire signed [16:0] low=$signed(request[31:16]);
    wire signed [16:0] centre=$signed(request[47:32]);
    wire signed [16:0] high=$signed(request[63:48]);
    wire ranges_ok=low>= -17'sd2048 && high<=17'sd2047 && high>low;
    assign request_valid=channel<3 && (channel!=0 || PRESSURE_ENABLED!=0) && flags<4 && (channel==1 || !flags[1]) && ranges_ok &&
        (channel==0 ? centre==0 && high-low>=17'sd64 : centre-low>=17'sd80 && high-centre>=17'sd80);
    reg signed [11:0] raw,stored_low,stored_centre,stored_high;
    always @* begin
        raw=0;stored_low=0;stored_centre=0;stored_high=0;query=0;
        case(channel)
            0:begin raw=adc_samples[11:0];stored_low=calibration[11:0];stored_high=calibration[23:12];end
            1:begin raw=adc_samples[23:12];stored_low=calibration[35:24];stored_centre=calibration[47:36];stored_high=calibration[59:48];end
            2:begin raw=adc_samples[35:24];stored_low=calibration[71:60];stored_centre=calibration[83:72];stored_high=calibration[95:84];end
        endcase
        query[7:0]=channel;
        if(channel<3)query[15:8]={2'b0,active[channel],adc_valid[channel],adc_available,
            (channel==1&&invert_x),enable_mask[channel],calibration_mask[channel]};
        query[31:16]=raw;query[47:32]=stored_low;query[63:48]=stored_centre;query[79:64]=stored_high;
        query[87:80]={7'b0,led_available};query[95:88]=led_applied;
        query[103:96]={6'b0,last_error};query[111:104]={7'b0,arithmetic_fault};
    end
    always @(posedge clk)begin
        if(rst)begin
            cal_commit<=0;calibration<=BOOT_CALIBRATION;
            calibration_mask<=BOOT_CALIBRATION_MASK & (PRESSURE_ENABLED!=0?3'b111:3'b110);
            enable_mask<=BOOT_ENABLE_MASK & (PRESSURE_ENABLED!=0?3'b111:3'b110);
            invert_x<=BOOT_INVERT_X;boot_pending<=|BOOT_CALIBRATION_MASK;
        end
        else begin
            cal_commit<=0;
            // Load the same measured calibration into the existing mapper on
            // the first clock after reset. Runtime SET still uses its old path.
            if(boot_pending)begin cal_commit<=1;boot_pending<=0;end
            if(commit&&request_valid)begin
                cal_commit<=1;calibration_mask[channel]<=1;enable_mask[channel]<=flags[0];
                case(channel)
                    0:calibration[23:0]<={high[11:0],low[11:0]};
                    1:begin calibration[59:24]<={high[11:0],centre[11:0],low[11:0]};invert_x<=flags[1];end
                    2:calibration[95:60]<={high[11:0],centre[11:0],low[11:0]};
                endcase
            end
        end
    end
endmodule
