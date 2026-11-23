`timescale 1ns/1ps
// Reuses v6 UART CRC/sample-boundary harness for the independent B controls.
module tb_osc_control_uart;
    reg clk=0,rst=1,ce=0,rx=1;
    wire tx;
    wire [16:0] volume,bend,bend_b;
    wire [1:0] preset,preset_b,tone,wave;
    wire [31:0] held,physical,frames,gate_a,gate_b,step;
    wire [7:0] faults;
    wire override_on;
    wire [5:0] override_id;
    reg [15:0] crc;
    synth_app_bridge #(.INDEPENDENT_CONTROL_ENABLED(1),.WAVE_CONTROL_ENABLED(1),.TONE_CONTROL_ENABLED(1)) dut(
      .clk(clk),.rst(rst),.sample_ce(ce),.uart_rx(rx),.uart_tx(tx),
      .physical_keys(8'd0),.raw_keys(8'hff),.vol_up(1'b0),.vol_down(1'b0),
      .bend_up(1'b0),.bend_down(1'b0),.bend_reset(1'b0),.preset_next(1'b0),
      .active_voice_count(6'd0),.audio_fault(1'b0),.held_keys(held),.volume(volume),
      .bend(bend),.preset(preset),.faults(faults),.physical_mask(physical),
      .frame_counter(frames),.tone_mode(tone),.waveform_mode(wave),
      .osc2_bend(bend_b),.osc2_preset(preset_b),.osc1_gate_mask(gate_a),
      .osc2_gate_mask(gate_b),.osc_override_enable(override_on),
      .osc_override_id(override_id),.osc_override_increment(step),
        .performance_play_keys(8'b0),.ui_commit_valid(1'b0),.ui_commit_field(2'b0),.ui_commit_value(8'b0),
        .ui_settings_active(1'b0),.ui_selected_field(2'b0),.ui_preview_value(8'b0));
    always #5 clk=~clk;
    task uart_byte;input [7:0] x;integer b;begin
      rx=0;repeat(427)@(negedge clk);
      for(b=0;b<8;b=b+1)begin rx=x[b];repeat(427)@(negedge clk);end
      rx=1;repeat(427)@(negedge clk);
    end endtask
    task data_byte;input [7:0] x;integer b;begin
      uart_byte(x);crc=crc^{x,8'h00};
      for(b=0;b<8;b=b+1)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
    end endtask
    task packet;input [7:0] typ;input [7:0] len;input [47:0] payload;input bad;integer n;begin
      crc=16'hffff;uart_byte(8'ha5);uart_byte(8'h5a);data_byte(1);data_byte(typ);
      data_byte(1);data_byte(0);data_byte(len);
      for(n=0;n<len;n=n+1)data_byte(payload>>(8*n));
      uart_byte(bad?(crc[7:0]^8'h01):crc[7:0]);uart_byte(crc[15:8]);
      repeat(10)@(negedge clk);
    end endtask
    task commit;begin
      @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(10)@(negedge clk);
      // Responses finish before the next request (the production ce is periodic).
    end endtask
    task drain;begin repeat(100000)@(negedge clk);end endtask
    initial begin
      repeat(8)@(negedge clk);rst=0;
      packet(8'h01,0,0,0);commit;
      if(dut.out_payload[23:16]!==8'h7f)begin $display("FAIL capabilities");$finish;end
      drain;
      packet(8'h16,2,48'h000000000120,0);
      if(preset_b!==1)begin $display("FAIL early B update");$finish;end
      commit;
      if(dut.wire_bend_b!==8'd32 || bend_b==bend || preset_b!==1)begin
        $display("FAIL independent B pitch/preset");$finish;
      end
      drain;
      packet(8'h16,2,48'h000000000300,0);commit;drain;
      packet(8'h16,2,48'h000000000200,1);commit;
      if(dut.wire_bend_b!==8'd32 || preset_b!==1)begin
        $display("FAIL B CRC/range validation");$finish;
      end
      // Gate operation 2 affects only B slot 0 (id=32).
      packet(8'h17,6,48'h000000000220,0);commit;
      if(gate_b!==32'hfffffffe || gate_a!==32'hffffffff)begin
        $display("FAIL indexed B gate");$finish;
      end
      drain;
      packet(8'h17,6,{32'd44739243,8'd1,8'd32},0);commit;
      if(!override_on || override_id!==6'd32 || step!==32'd44739243)begin
        $display("FAIL indexed frequency control");$finish;
      end
      drain;
      packet(8'h17,6,0,0);commit;
      if(override_on || gate_a!==32'hffffffff || gate_b!==32'hffffffff || faults)begin
        $display("FAIL diagnostic restore");$finish;
      end
      $display("PASS independent UART controls, capabilities, CRC, bounds, sample commit");$finish;
    end
    initial begin #50000000;$display("FAIL timeout");$finish;end
endmodule
