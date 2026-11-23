`timescale 1ns/1ps
// UART helpers follow tb_performance_bridge; exercise the actual command path.
module tb_expression_bridge;
    reg clk=0,rst=1,rx=1,ce=0;wire tx;
    reg [7:0] data[0:7];integer tick=0,seq=0,checks=0,i;
    reg [15:0] crc;wire [63:0] request;wire commit,valid;
    wire [111:0] query;wire [95:0] calibration;wire [2:0] mask,enables;wire invert,cal_commit;
    reg packet_was=0;reg [7:0] reply_type;reg [143:0] reply;integer replies=0,old_replies;
    reg [7:0] reply_types[0:63];reg [143:0] reply_data[0:63];integer start_reply,j,max_responses=0;
    synth_app_bridge #(.CLOCK_HZ(1152000),.BAUD(115200),.PERIPHERALS_ENABLED(1)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),
        .raw_keys(8'hff),.physical_keys(8'd0),.vol_up(1'b0),.vol_down(1'b0),
        .bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
        .active_voice_count(6'd0),.audio_fault(1'b0),
        .peripheral_request(request),.peripheral_commit(commit),.peripheral_config_valid(valid),.peripheral_query(query));
    expression_config config_store(clk,rst,request,commit,valid,cal_commit,calibration,mask,invert,enables,
        48'h123fff456789,4'h7,1'b1,3'b010,1'b1,8'h55,2'd0,1'b0,query);
    always #5 clk=~clk;
    always @(negedge clk)begin
        tick=tick+1;ce=(tick%1024)==0;
        if(dut.packet_active&&!packet_was)begin reply_types[replies]=dut.out_type;reply_data[replies]=dut.out_payload;replies=replies+1;reply_type=dut.out_type;reply=dut.out_payload;end
        packet_was=dut.packet_active;
        if(dut.resp_count>max_responses)max_responses=dut.resp_count;
    end
    task require;input yes;input[511:0]text;
        begin checks=checks+1;if(yes!==1'b1)begin $display("FAIL expression bridge %0s",text);$finish;end end
    endtask
    task byte_out;input[7:0]value;integer b;
        begin rx=0;repeat(10)@(negedge clk);for(b=0;b<8;b=b+1)begin rx=value[b];repeat(10)@(negedge clk);end rx=1;repeat(10)@(negedge clk);end
    endtask
    task crc_out;input[7:0]value;integer b;
        begin byte_out(value);crc=crc^{value,8'd0};for(b=0;b<8;b=b+1)crc=crc[15] ? (crc<<1)^16'h1021 : crc<<1;end
    endtask
    task burst_packet;input[7:0]kind;input integer length;
        begin old_replies=replies;crc=16'hffff;byte_out(8'ha5);byte_out(8'h5a);crc_out(1);crc_out(kind);crc_out(seq);crc_out(seq>>8);crc_out(length);
            for(i=0;i<length;i=i+1)crc_out(data[i]);byte_out(crc[7:0]);byte_out(crc[15:8]);seq=seq+1;end
    endtask
    task packet;input[7:0]kind;input integer length;
        begin burst_packet(kind,length);repeat(5000)@(negedge clk);require(replies==old_replies+1,"one response per request");end
    endtask
    initial begin
        for(i=0;i<8;i=i+1)data[i]=0;
        repeat(8)@(negedge clk);rst=0;repeat(1100)@(negedge clk);
        data[0]=1;data[1]=3;data[2]=8'h9c;data[3]=8'hff;data[4]=8'hbc;data[5]=2;data[6]=8'h40;data[7]=6;
        packet(8'h26,8);require(reply_type==8'h80&&reply[15:0]==16'h0026,"valid calibration ACK");
        require(mask==2&&enables==2&&invert&&calibration[59:24]=={12'd1600,12'd700,12'hf9c},"accepted payload reaches calibration store");
        packet(8'h27,1);require(reply_type==8'h8c&&reply[79:32]=={16'd1600,16'd700,16'hff9c}&&reply[31:16]==16'h456,"readback calibration and raw ADC");
        data[7]=8'h08;packet(8'h26,8);require(reply[15:0]==16'h0126&&calibration[59:48]==1600,"out-of-range signed calibration rejected atomically");
        packet(8'h26,7);require(reply[15:0]==16'h0126,"length check");
        data[0]=3;packet(8'h27,1);require(reply[15:0]==16'h0127,"query channel check");
        packet(8'h02,0);require(reply_type==8'h82,"legacy status retained");
        start_reply=replies;data[0]=1;
        for(j=0;j<12;j=j+1)burst_packet(8'h27,1);
        data[1]=1;data[2]=8'h38;data[3]=8'hff;data[4]=8'h58;data[5]=2;data[6]=8'hdc;data[7]=5;
        burst_packet(8'h26,8);burst_packet(8'h27,1);repeat(40000)@(negedge clk);
        require(replies==start_reply+14&&max_responses==4,"response backpressure and full ordered delivery");
        for(j=0;j<12;j=j+1)require(reply_types[start_reply+j]==8'h8c&&reply_data[start_reply+j][79:32]=={16'd1600,16'd700,16'hff9c},"queued query keeps old calibration snapshot");
        require(reply_types[start_reply+12]==8'h80&&reply_data[start_reply+12][15:0]==16'h0026,"queued set ACK");
        require(reply_types[start_reply+13]==8'h8c&&reply_data[start_reply+13][79:32]=={16'd1500,16'd600,16'hff38},"following query sees newly committed calibration");
        rst=1;repeat(8)@(negedge clk);rst=0;require(mask==0&&enables==0,"configuration is volatile and opt-in");
        $display("PASS expression bridge %0d checks",checks);$finish;
    end
    initial begin #10000000;$display("FAIL expression bridge timeout");$finish;end
endmodule
