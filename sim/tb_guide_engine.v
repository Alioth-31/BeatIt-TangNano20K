`timescale 1ns/1ps
module tb_guide_engine;
    reg clk=0,rst=1,ce=0,enable=0,settings=0,toggle=0,rewind=0,song=0,mono=0,led_ok=1;
    reg [1:0] tempo=2;reg [2:0] field=0;reg [7:0] keys=0;
    reg [55:0] mapped={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    reg [55:0] played={7'd72,7'd71,7'd69,7'd67,7'd65,7'd64,7'd62,7'd60};
    wire [7:0] leds,target,missed,wrong;wire running,ready,compatible,done;
    wire [3:0] step;wire [2:0] reason;
    integer checks=0,i,count,start_step;reg [7:0] saved_target;
    guide_engine #(.SAMPLE_HZ(240)) dut(clk,rst,ce,enable,settings,toggle,rewind,song,tempo,
        mapped,played,keys,mono,led_ok,field,leds,target,running,ready,compatible,done,step,missed,wrong,reason,1'b0,1'b0);
    always #5 clk=~clk;
    task check;input ok;input[639:0]text;begin checks=checks+1;if(ok!==1'b1)begin $display("FAIL guide %0s step%0d LEDs%h target%h reason%0d",text,step,leds,target,reason);$finish;end end endtask
    task frame;begin @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(3)@(negedge clk);end endtask
    task press_toggle;begin @(negedge clk);toggle=1;@(negedge clk);toggle=0;frame();end endtask
    task wait_ready;begin count=0;while(!ready&&count<100)begin @(negedge clk);count=count+1;end check(ready,"mapping validation bounded");end endtask
    task reset_guide;begin @(negedge clk);rewind=1;@(negedge clk);rewind=0;frame();end endtask
    initial begin
        repeat(5)@(negedge clk);rst=0;wait_ready();check(compatible&&!running,"default C scale maps exactly");
        keys=8'h81;frame();check(leds==8'h81,"perform echoes physical keys");keys=0;enable=1;frame();
        press_toggle();check(running&&step==0&&target==1&&leds==1,"explicit guide start");
        keys=8'h80;frame();check(leds==1,"wrong physical key cannot OR into guide LEDs");keys=1;
        // First step lasts120 samples (one quarter at120 BPM); its last30
        // samples are a real gap before repeated C, not same-key preview.
        repeat(88)frame();check(target==1,"first note held through gate");frame();check(target==0&&leds==0,"repeated-note gap is not overwritten by preview");
        repeat(30)frame();check(step==1&&target==1,"repeat note starts at exact event boundary");
        check(missed==0&&wrong==1,"correct note seen; wrong key counted once per event");
        settings=1;field=4;frame();start_step=step;saved_target=target;
        check(!running&&leds==8'h10,"settings pauses and has exclusive LED ownership");
        repeat(200)frame();check(step==start_step&&target==saved_target,"settings cannot advance song");
        settings=0;frame();check(!running,"leaving settings requires explicit resume");
        press_toggle();check(running,"resume via direct control");
        led_ok=0;frame();check(!running&&reason==4,"missing LED pauses and reports unavailable");
        press_toggle();check(!running,"cannot start an undeliverable guide");led_ok=1;frame();check(!running,"LED reconnect never auto-resumes");
        // Configuration change validates the complete song, including later notes.
        mapped[55:49]=73;frame();wait_ready();check(!compatible&&reason==2&&!running,"unreachable later C5 rejects full exercise");
        press_toggle();check(!running,"incompatible mapping blocks start");mapped[55:49]=72;frame();wait_ready();
        song=1;frame();wait_ready();check(compatible,"three-note exercise maps without transpose");
        mono=1;frame();wait_ready();check(!compatible&&reason==3,"mono cannot silently discard chord targets");
        mono=0;frame();wait_ready();press_toggle();check(target==8'h15&&leds==8'h15,"exact three-note chord target");
        // A key retained across an octave change may have the correct position
        // but the wrong sounding MIDI. It must not satisfy the guide.
        played[6:0]=48;keys=8'h15;repeat(240)frame();check(missed==1&&wrong==1,"actual latched key pitches checked");
        check(step==1&&target==0,"explicit rest target");keys=0;played=mapped;
        reset_guide();check(!running&&step==0&&missed==0&&wrong==0&&!done,"rewind resets progress and score");
        press_toggle();keys=8'h15;repeat(239)frame();check(step==0,"long chord duration");frame();check(step==1,"eighth-subdivision duration exact");
        // Finish without playing: fixed tempo advances independently of input.
        keys=0;for(i=0;i<1400;i=i+1)frame();check(done&&!running&&leds==0,"song completes and stops");
        press_toggle();check(running&&!done&&step==0,"start after completion replays from beginning");
        enable=0;keys=8'h42;frame();check(!running&&leds==8'h42,"perform mode restores key feedback");
        $display("PASS guide %0d checks",checks);$finish;
    end
    initial begin #10000000;$display("FAIL guide timeout");$finish;end
endmodule
