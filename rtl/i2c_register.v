`timescale 1ns/1ps
// Bounded one/two-byte register access around Alex Forencich's MIT I2C master.
// 16-bit words travel MSB first. One-byte transfers use bits [7:0].
// Single-master bus only. Outputs mean release (1), never drive high.
module i2c_register #(
    parameter PRESCALE=31, // ceil(49.152MHz / (4 * 400kHz))
    parameter TIMEOUT_CYCLES=491520
)(
    input clk,input rst,input start,input [6:0] address,input [7:0] reg_addr,
    input read_op,input two_bytes,input [15:0] write_data,
    output busy,output reg done,output reg [1:0] error,
    output reg [15:0] read_data,
    input scl_i,input sda_i,output scl_release,output sda_release
);
    function integer clog2;
        input integer v; integer n; begin n=v-1;clog2=0;
        while(n>0)begin clog2=clog2+1;n=n>>1;end end
    endfunction
    localparam TW=(TIMEOUT_CYCLES<2)?1:clog2(TIMEOUT_CYCLES);
    // Fast-mode tLOW >=1.3us: default 64 clocks at 49.152MHz.
    // PRESCALE is a quarter bit in the upstream master, not a half bit.
    localparam RECOVERY_HALF=2*PRESCALE+2;
    localparam PW=clog2(RECOVERY_HALF+1);
    localparam IDLE=0,CMD=1,DATA=2,RX=3,WAIT_STOP=4,
        REC_LOW=5,REC_HIGH=6,STOP_LOW=7,STOP_HIGH=8,STOP_RELEASE=9,SETTLE=10;
    reg [3:0] state;
    reg [1:0] step;
    reg [6:0] addr_latched;
    reg [7:0] pointer;
    reg rd,two;
    reg [15:0] word_data;
    reg [TW-1:0] timeout_count;
    reg [PW-1:0] pulse_count;
    reg [3:0] recovery_pulses;
    // Two-stage synchronization; master still sees the physical wired-AND bus.
    reg [1:0] scl_sync,sda_sync;
    wire recovery=state>=REC_LOW;
    wire core_scl,core_sda,core_busy,core_control,core_active,missed_ack;
    wire cmd_ready,data_ready,rx_valid;wire [7:0] rx_byte;
    wire reading=rd && step!=0;
    wire last_byte=two ? step==2 : step==1;
    wire [7:0] tx_byte=(step==0)?pointer:((two&&step==1)?word_data[15:8]:word_data[7:0]);
    assign busy=state!=IDLE;
    assign scl_release=recovery ? !(state==REC_LOW||state==STOP_LOW) : core_scl;
    assign sda_release=recovery ? !(state==STOP_LOW||state==STOP_HIGH) : core_sda;
    i2c_master master(
        .clk(clk),.rst(rst||recovery),.s_axis_cmd_address(addr_latched),
        .s_axis_cmd_start(step==0 || (rd && step==1)),.s_axis_cmd_read(reading),
        .s_axis_cmd_write(!reading),.s_axis_cmd_write_multiple(1'b0),
        .s_axis_cmd_stop(last_byte),.s_axis_cmd_valid(state==CMD),.s_axis_cmd_ready(cmd_ready),
        .s_axis_data_tdata(tx_byte),.s_axis_data_tvalid(state==DATA),
        .s_axis_data_tready(data_ready),.s_axis_data_tlast(1'b1),
        .m_axis_data_tdata(rx_byte),.m_axis_data_tvalid(rx_valid),
        .m_axis_data_tready(state==RX),.m_axis_data_tlast(),
        .scl_i(scl_sync[1]),.sda_i(sda_sync[1]),.scl_o(core_scl),.scl_t(),
        .sda_o(core_sda),.sda_t(),.busy(core_busy),.bus_control(core_control),
        .bus_active(core_active),.missed_ack(missed_ack),
        .prescale(PRESCALE[15:0]),.stop_on_idle(1'b0));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done<=0;error<=0;read_data<=0;step<=0;
            addr_latched<=0;pointer<=0;rd<=0;two<=0;word_data<=0;
            timeout_count<=0;pulse_count<=0;recovery_pulses<=0;
            scl_sync<=3;sda_sync<=3;
        end else begin
            scl_sync<={scl_sync[0],scl_i};sda_sync<={sda_sync[0],sda_i};done<=0;
            if(state!=IDLE) timeout_count<=timeout_count+1'b1;
            if(state==IDLE) begin
                timeout_count<=0;
                if(start) begin
                    addr_latched<=address;pointer<=reg_addr;rd<=read_op;two<=two_bytes;
                    word_data<=write_data;read_data<=0;step<=0;error<=0;
                    pulse_count<=0;recovery_pulses<=0;
                    if(scl_sync[1]&&sda_sync[1])state<=CMD;
                    else begin state<=REC_LOW;error<=2;end
                end
            end else if((!recovery && missed_ack) || timeout_count==TIMEOUT_CYCLES-1) begin
                // Reset the upstream engine, clock out a stranded slave and STOP.
                read_data<=0;timeout_count<=0;pulse_count<=0;recovery_pulses<=0;
                if(recovery) begin state<=IDLE;done<=1;error<=2;end
                else begin error<=missed_ack?1:2;state<=REC_LOW;end
            end else case(state)
                CMD: if(cmd_ready) state<=reading?RX:DATA;
                DATA: if(data_ready) begin
                    if(last_byte)state<=WAIT_STOP;
                    else begin step<=step+1'b1;state<=CMD;end
                end
                RX: if(rx_valid) begin
                    if(two&&step==1)read_data[15:8]<=rx_byte;
                    else read_data[7:0]<=rx_byte;
                    if(last_byte)state<=WAIT_STOP;
                    else begin step<=step+1'b1;state<=CMD;end
                end
                WAIT_STOP: if(!core_busy&&!core_control&&!core_active&&scl_sync[1]&&sda_sync[1]) begin
                    // Upstream STOP waits one quarter-bit. Add a full fast-mode
                    // bus-free interval before another client transaction starts.
                    state<=STOP_RELEASE;pulse_count<=0;
                end
                REC_LOW: if(pulse_count==RECOVERY_HALF-1)begin pulse_count<=0;state<=REC_HIGH;end
                         else pulse_count<=pulse_count+1'b1;
                REC_HIGH: if(scl_sync[1])begin
                    if(pulse_count==RECOVERY_HALF-1)begin
                        pulse_count<=0;recovery_pulses<=recovery_pulses+1'b1;
                        if(sda_sync[1]||recovery_pulses==8)state<=STOP_LOW;else state<=REC_LOW;
                    end else pulse_count<=pulse_count+1'b1;
                end else pulse_count<=0;
                STOP_LOW: if(pulse_count==RECOVERY_HALF-1)begin pulse_count<=0;state<=STOP_HIGH;end
                          else pulse_count<=pulse_count+1'b1;
                STOP_HIGH: if(scl_sync[1])begin
                    if(pulse_count==RECOVERY_HALF-1)begin pulse_count<=0;state<=STOP_RELEASE;end
                    else pulse_count<=pulse_count+1'b1;
                end else pulse_count<=0;
                STOP_RELEASE: if(pulse_count==RECOVERY_HALF-1)begin pulse_count<=0;state<=SETTLE;end
                              else pulse_count<=pulse_count+1'b1;
                SETTLE: begin state<=IDLE;done<=1;if(!sda_sync[1]||!scl_sync[1])error<=2;end
                default: begin state<=IDLE;done<=1;error<=2;end
            endcase
        end
    end
endmodule
