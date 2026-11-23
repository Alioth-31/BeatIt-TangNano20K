`timescale 1ns/1ps
// Queue-boundary fixture: UART/parser correctness is covered separately.
module tb_native_head_cache;
    reg clk=0,rst=1,ce=0;
    wire [39:0] held;wire [639:0] instances;wire [279:0] midi;
    integer c;
    synth_app_bridge #(.PERFORMANCE_ENABLED(1),.WATCHDOG_SAMPLES(3)) dut(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(1'b1),
        .physical_keys(8'b0),.raw_keys(8'hff),.performance_play_keys(8'b0),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),.active_voice_count(6'b0),.audio_fault(1'b0),
        .ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0),
        .performance_held(held),.source_instance(instances),.source_midi(midi));
    synth_app_bridge #(.PERFORMANCE_ENABLED(0)) legacy(
        .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(1'b1),
        .physical_keys(8'b0),.raw_keys(8'hff),.performance_play_keys(8'b0),
        .vol_up(1'b0),.vol_down(1'b0),.bend_up(1'b0),.bend_down(1'b0),
        .bend_reset(1'b0),.preset_next(1'b0),.active_voice_count(6'b0),.audio_fault(1'b0),
        .ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    task tick;input integer n;begin repeat(n) begin @(negedge clk);#1;end end endtask
    task reset;begin rst=1;ce=0;tick(3);rst=0;tick(1);end endtask
    task frame;begin ce=1;tick(1);ce=0;tick(2);end endtask
    task enqueue;input [7:0] length;input [63:0] payload;
        begin
            dut.cmd_type[0]=8'h21;dut.cmd_length[0]=length;dut.cmd_seq[0]=1;dut.cmd_payload[0]=payload;
            dut.cmd_read=0;dut.cmd_write=1;dut.cmd_count=1;
        end
    endtask
    task require;input yes;input [8*110-1:0] message;
        begin if(yes!==1'b1) begin $display("FAIL native head cache: %0s",message);$finish;end end
    endtask
    initial begin
        // Fetch and cache preparation may each coincide with an audio frame.
        reset;enqueue(6,64'h0000_0001_003c_0100);ce=1;tick(1);
        require(held==0 && instances==0,"prefetch edge consumed a newly fetched command");
        tick(1);
        require(held==0 && instances==0,"cache-load edge must wait for registered ready");
        tick(1);ce=0;tick(1);
        require(held[8] && instances[128+:16]==1 && midi[56+:7]==60,"ready native on did not commit exactly once");

        reset;enqueue(6,64'h0000_0001_003c_0100);tick(1);ce=1;tick(1);ce=0;tick(1);
        require(held==0,"sample immediately after fetch bypassed cache readiness");
        frame;
        require(held[8] && instances[128+:16]==1,"prepared command was not retained for next sample");

        // The next head cannot snapshot the previous command's old token.
        reset;enqueue(6,64'h0000_0001_003c_0100);
        dut.cmd_type[1]=8'h21;dut.cmd_length[1]=6;dut.cmd_seq[1]=2;
        dut.cmd_payload[1]=64'h0000_0002_003e_0100;dut.cmd_write=2;dut.cmd_count=2;
        tick(2);frame;frame;
        require(instances[128+:16]==2 && midi[56+:7]==62,"back-to-back native heads used a stale instance snapshot");

        // Full source byte, length and reserved byte still gate the mutation.
        for(c=0;c<4;c=c+1) begin
            reset;
            case(c)
                0:enqueue(6,64'h0000_0001_003c_0120);
                1:enqueue(5,64'h0000_0001_003c_0100);
                2:enqueue(7,64'h0000_0001_003c_0100);
                default:enqueue(6,64'h0000_0001_013c_0100);
            endcase
            tick(2);frame;
            require(held==0 && instances==0,"cached low source bits bypassed full request validation");
            require(dut.resp_type[0]==8'h80 && dut.resp_payload[0][15:0]==16'h0121,"invalid request did not return range/length ACK");
        end

        // A query snapshots pitch/token, but held is authoritative at consume.
        reset;enqueue(6,64'h0000_0001_003c_0100);tick(2);frame;frame;frame;
        enqueue(6,64'h0000_0000_0000_0200);tick(2);frame;
        require(!held[8] && instances[128+:16]==1 && midi[56+:7]==60,"watchdog query changed pitch/token or retained expired held");
        require(dut.resp_type[1]==8'h8a && dut.resp_payload[1][15:8]==0 &&
            dut.resp_payload[1][23:16]==60 && dut.resp_payload[1][39:24]==1,"query returned cached held instead of consume-time held");

        // Unsupported native requests in the legacy profile cannot wait forever.
        reset;legacy.cmd_type[0]=8'h21;legacy.cmd_length[0]=6;legacy.cmd_seq[0]=1;
        legacy.cmd_payload[0]=64'h0000_0001_003c_0100;legacy.cmd_read=0;legacy.cmd_write=1;legacy.cmd_count=1;
        tick(1);frame;
        require(!legacy.head_valid && legacy.resp_type[0]==8'h80 && legacy.resp_payload[0][15:0]==16'h0321,
            "legacy profile stalled instead of rejecting unsupported native command");
        $display("PASS native head cache readiness, full validation, fresh instances and consume-time watchdog held");$finish;
    end
    initial begin #100000;$display("FAIL native head cache timeout");$finish;end
endmodule
