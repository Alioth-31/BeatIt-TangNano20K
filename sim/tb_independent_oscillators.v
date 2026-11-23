`timescale 1ns/1ps
// Reuses the v6 frame/deadline test; adds independent ADSR, gate and pitch proofs.
module tb_independent_oscillators;
    parameter N=4;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0,gate_a=32'hffffffff,gate_b=32'hffffffff;
    reg [16:0] bend_a=65536,bend_b=66048;
    reg override_on=0;
    reg [5:0] override_id=0;
    reg [31:0] override_step=44739243;
    wire signed [15:0] pcm;
    wire valid,fault,busy;
    wire [N-1:0] active;
    integer cycles,i,n,seen_nonzero=0;
    reg [31:0] a_step,b_step,neighbor_step,phase_before;
    reg [24:0] a_level;
    reg [31:0] contributed_a=0,contributed_b=0;
    reg [4:0] read_slot;
    reg [24:0] stored_level;
    reg [1:0] endpoint_wraps=0;
    synth_core #(.NUM_VOICES(N),.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(1)) dut(
      .clk(clk),.rst(rst),.sample_ce(ce),.held_keys(held),.preset(2'd2),
      .volume_target(17'd65536),.bend_target(bend_a),.pcm(pcm),.pcm_valid(valid),
      .fault(fault),.busy(busy),.active(active),.waveform_select(2'd0),
      .osc2_bend_target(bend_b),.osc2_preset(2'd1),
      .osc1_gate_mask(gate_a),.osc2_gate_mask(gate_b),
      .osc_override_enable(override_on),.osc_override_id(override_id),
      .osc_override_increment(override_step),.source_midi(224'd0),.source_instance(512'd0));
    always #5 clk=~clk;
    always @(posedge clk) if(!rst && dut.scheduler==14)begin
      if(dut.primary_pcm!=0)contributed_a[dut.voice_index]=1;
      if(dut.enveloped_b!=0)contributed_b[dut.voice_index]=1;
    end
    task read_b_level;
      input integer slot;
      begin
        read_slot=slot;force dut.b_state_store.read_addr=read_slot;
        repeat(2)@(negedge clk);stored_level=dut.b_read[27:3];
        release dut.b_state_store.read_addr;@(negedge clk);
      end
    endtask
    task frame;
      begin
        @(negedge clk);ce=1;@(negedge clk);ce=0;cycles=0;
        while(!valid && cycles<1000) begin @(negedge clk);cycles=cycles+1;end
        if(valid!==1 || fault!==0 || cycles>=1000 || (^pcm===1'bx)) begin
          $display("FAIL independent frame N=%0d cycles=%0d",N,cycles);$finish;
        end
        if(pcm!=0)seen_nonzero=seen_nonzero+1;
        repeat(1024-cycles-2) @(negedge clk);
      end
    endtask
    initial begin
      repeat(5) @(negedge clk);rst=0;
      held=(N==32)?32'hffffffff:((32'h1<<N)-1);
      repeat(8)frame;
      for(i=0;i<N;i=i+1)begin
        read_b_level(i);
        if(!active[i] || dut.envelope[i]===stored_level ||
           (^stored_level===1'bx) || dut.phase[i]===dut.phase_b[i])begin
          $display("FAIL independent envelope/phase slot=%0d",i);$finish;
        end
      end
      a_step=dut.increment[0];b_step=dut.increment_b[0];
      bend_b=70000;repeat(3)frame;
      if(dut.increment[0]!==a_step || dut.increment_b[0]<=b_step)begin
        $display("FAIL B bend altered A or stalled B");$finish;
      end
      neighbor_step=dut.increment[1];override_on=1;override_id=0;
      phase_before=dut.phase[0];frame;
      if(dut.increment[0]!==override_step || dut.increment[1]!==neighbor_step ||
         dut.phase[0]-phase_before!==override_step)begin
        $display("FAIL indexed frequency override/phase continuity");$finish;
      end
      a_step=dut.increment[0];override_id=6'd32;override_step=50000000;frame;
      if(dut.increment_b[0]!==override_step || dut.increment[0]!==a_step)begin
        $display("FAIL independent B override");$finish;
      end
      // Legal override endpoints exercise unsigned unity gain and phase wrap
      // through both halves of the synchronous frequency RAM.
      for(i=0;i<4;i=i+1)begin
        override_id=(i<2)?N-1:32+N-1;
        override_step=(i%2==0)?32'd1:32'h7fffffff;
        repeat(2)begin
          phase_before=(i<2)?dut.phase[N-1]:dut.phase_b[N-1];
          frame;
          if((i<2 && (dut.increment[N-1]!==override_step ||
              dut.phase[N-1]-phase_before!==override_step)) ||
             (i>=2 && (dut.increment_b[N-1]!==override_step ||
              dut.phase_b[N-1]-phase_before!==override_step)))begin
            $display("FAIL override endpoint id=%0d step=%h",override_id,override_step);$finish;
          end
          if(((i<2)?dut.phase[N-1]:dut.phase_b[N-1])<phase_before)
            endpoint_wraps[(i<2)?0:1]=1;
        end
      end
      if(endpoint_wraps!==2'b11)begin $display("FAIL override phase wrap coverage");$finish;end
      // Every indexed DDS must accept a new frequency without resetting phase
      // or modifying its neighbor. Both enveloped paths must reach the mixer.
      override_on=0;repeat(128)frame;override_on=1;
      for(i=0;i<N;i=i+1)begin
        override_id=i;override_step=40000000+i*12345;
        neighbor_step=dut.increment_b[i];phase_before=dut.phase[i];frame;
        if(dut.increment[i]!==override_step || dut.increment_b[i]!==neighbor_step ||
           dut.phase[i]-phase_before!==override_step)begin
          $display("FAIL A indexed independence slot=%0d",i);$finish;
        end
        override_id=32+i;override_step=50000000+i*12345;
        phase_before=dut.phase_b[i];frame;
        if(dut.increment_b[i]!==override_step || dut.phase_b[i]-phase_before!==override_step)begin
          $display("FAIL B indexed independence slot=%0d",i);$finish;
        end
      end
      for(i=0;i<N;i=i+1)if(dut.increment[i]!==40000000+i*12345 || dut.increment_b[i]!==50000000+i*12345)begin
        $display("FAIL independently programmed frequencies must persist slot=%0d",i);$finish;
      end
      if((contributed_a&held)!==held || (contributed_b&held)!==held)begin
        $display("FAIL missing oscillator output contribution A=%h B=%h",contributed_a,contributed_b);$finish;
      end
      override_on=0;gate_b[0]=0;frame;
      if(dut.env_state_b[0]!==3'd4 || dut.env_state[0]===3'd4 ||
         dut.env_state_b[1]===3'd4)begin
        $display("FAIL independent B release");$finish;
      end
      // Validate actual output contribution, not just two phase registers.
      if(seen_nonzero<2)begin $display("FAIL no audible PCM contribution");$finish;end
      if(N==32)begin
        // Exercise each release gate with the paired oscillator still held.
        rst=1;repeat(5)@(negedge clk);rst=0;gate_a=32'hffffffff;gate_b=32'hffffffff;repeat(8)frame;
        for(i=0;i<N;i=i+1)begin
          gate_a[i]=0;frame;
          if(dut.env_state[i]!==3'd4 || dut.env_state_b[i]===3'd4)begin
            $display("FAIL indexed A release independence slot=%0d",i);$finish;
          end
        end
        rst=1;repeat(5)@(negedge clk);rst=0;gate_a=32'hffffffff;gate_b=32'hffffffff;repeat(8)frame;
        for(i=0;i<N;i=i+1)begin
          gate_b[i]=0;frame;
          if(dut.env_state_b[i]!==3'd4 || dut.env_state[i]===3'd4)begin
            $display("FAIL indexed B release independence slot=%0d",i);$finish;
          end
        end
      end
      // Long ADSR lifecycle is exercised at N=4; all sizes exercise the scheduler.
      if(N==4)begin
        repeat(2880)frame;
        if(dut.env_state_b[0]!==0 || !active[0] || dut.envelope[0]==0)begin
          $display("FAIL B release must finish while A remains audible");$finish;
        end
        gate_a[1]=0;frame;
        if(dut.env_state[1]!==3'd4 || dut.env_state_b[1]===3'd4)begin
          $display("FAIL independent A release");$finish;
        end
        held=0;repeat(14401)frame;
        if(active!==0 || pcm!==0 || fault)begin
          $display("FAIL full release/silence");$finish;
        end
      end
      $display("PASS independent oscillators N=%0d",N);$finish;
    end
    initial begin #300000000;$display("FAIL timeout");$finish;end
endmodule
