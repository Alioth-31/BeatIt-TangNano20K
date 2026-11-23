`timescale 1ns/1ps
// Direct phase-edge checks complement the full-core PCM differential tests.
// INDEP=0 exercises both old coupled DDS updates in the same CALC clock.
module tb_phase_boundaries;
    parameter INDEP=1;
    reg clk=0,rst=1,ce=0;
    reg [31:0] held=0;
    reg override_enable=0;
    reg [5:0] override_id=0;
    reg [31:0] override_step=1;
    reg [31:0] rng=32'h5bc7912d;
    wire signed [15:0] pcm;wire valid,fault,busy;wire [3:0] active;
    integer f,cycles,checks=0,phase_checks=0,off_checks=0,fade_checks=0,restarts=0;
    integer selected;
    reg verify_edge;
    reg [31:0] expected_a,expected_b,before_a,before_b;
    synth_core #(.DUAL_OSC_ENABLE(1),.INDEPENDENT_OSC_ENABLE(INDEP),.LIVE_WAVE_ENABLE(1)) dut(
        clk,rst,ce,held,2'd2,17'd65536,17'd65536,pcm,valid,fault,busy,active,
        2'd0,17'd65536,2'd1,32'hffffffff,32'hffffffff,override_enable,override_id,override_step,
        224'd0,512'd0,1'b0,1'b0,32'd0);
    always #5 clk=~clk;
    task require;
        input condition;input [639:0] message;
        begin checks=checks+1;if(condition!==1'b1)begin $display("FAIL INDEP=%0d %0s",INDEP,message);$finish;end end
    endtask
    always @(posedge clk) if(!rst && !fault)begin
        verify_edge=0;selected=dut.voice_index;
        expected_a=dut.phase[selected];expected_b=dut.phase_b[selected];
        if(dut.scheduler==4)begin // CALC: A, and coupled B, must use the old slot phases
            verify_edge=1;
            if(dut.env_state[selected]!=0)begin
                expected_a=dut.phase[selected]+dut.frequency_product[47:16];
                if(!INDEP)expected_b=dut.phase_b[selected]+dut.osc2_step;
                if(dut.env_state[selected]==5)fade_checks=fade_checks+1;
            end else off_checks=off_checks+1;
        end else if(INDEP && dut.scheduler==6)begin // ACCUM: independent B only
            verify_edge=1;
            if(dut.env_state_b[selected]!=0)
                expected_b=dut.phase_b[selected]+dut.frequency_product[47:16];
            else off_checks=off_checks+1;
        end else if(dut.scheduler==2 && dut.env_state[selected]==5 && dut.fade_left[selected]==0)begin
            verify_edge=1;expected_a=0;expected_b=0;restarts=restarts+1;
        end
        if(verify_edge)begin
            #1;
            require(dut.phase[selected]===expected_a && dut.phase_b[selected]===expected_b,
                "phase update, OFF hold, or FADE restart differs from unsigned 32-bit arithmetic");
            phase_checks=phase_checks+1;
        end
    end
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;cycles=0;
            while(!valid && cycles<1023)begin @(negedge clk);cycles=cycles+1;end
            require(valid && !fault && cycles<1023,"phase boundary test sample deadline");
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(40)@(negedge clk);repeat(16)frame;
        held=1;frame;
        if(INDEP)begin
            override_enable=1;override_id=0;override_step=32'h7fffffff;frame;
            override_id=32;override_step=1;frame;
            dut.phase[0]=32'hffffffff;dut.phase_b[0]=32'hffffffff;frame;
            require(dut.phase[0]==32'h7ffffffe && dut.phase_b[0]==0,
                "A maximum increment and B unit increment wrap correctly");
            override_id=0;override_step=1;frame;
            override_id=32;override_step=32'h7fffffff;frame;
            dut.phase[0]=32'hffffffff;dut.phase_b[0]=32'hffffffff;frame;
            require(dut.phase[0]==0 && dut.phase_b[0]==32'h7ffffffe,
                "A unit increment and B maximum increment wrap correctly");
            for(f=0;f<32;f=f+1)begin
                rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                override_id=f[0]?32:0;override_step=(rng & 32'h7fffffff)|1;
                dut.phase[0]=rng^32'hf1234567;dut.phase_b[0]=~rng;frame;
            end
            override_enable=0;frame;
        end else begin
            dut.phase[0]=32'hfffffff0;dut.phase_b[0]=32'hfffffff0;
            before_a=dut.phase[0];before_b=dut.phase_b[0];frame;
            require(dut.phase[0]==before_a+dut.increment[0] &&
                dut.phase_b[0]==before_b+dut.increment_b[0] &&
                dut.phase[0]<before_a && dut.phase_b[0]<before_b,
                "coupled A and B wrap in the same CALC clock");
            for(f=0;f<32;f=f+1)begin
                rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
                dut.phase[0]=rng;dut.phase_b[0]=~rng;frame;
            end
        end
        // Fill the four slots and steal the oldest. FADE advances its old
        // phases, then PREP clears both phases before the pending note starts.
        held=15;frame;held=31;frame;
        require(dut.env_state[0]==5,"fifth note starts the old slot fade");
        repeat(34)frame;
        require(dut.owner[0]==4 && dut.env_state[0]!=0,"pending note starts after old fade");
        require(off_checks>0 && fade_checks>=32 && restarts>0 && phase_checks>300,
            "OFF hold, every fade sample, and phase reset were observed");
        $display("PASS shared phase boundaries INDEP=%0d wrap/override/random/OFF/FADE checks=%0d",INDEP,checks);
        $finish;
    end
    initial begin #100000000;$display("FAIL phase boundary timeout INDEP=%0d",INDEP);$finish;end
endmodule
