`timescale 1ns/1ps
// Regression: quiet 32-voice-normalized PCM must survive display quantization.
module tb_hdmi_lowlevel;
    reg ac=0,vc=0,rst=1,valid=0,tick=0;
    reg [63:0] state=64'h123456789abcdef0;
    reg signed [15:0] pcm=0;
    reg [8:0] address=0;
    wire [63:0] visible;
    wire [7:0] wave;
    wire ready;
    wire [1:0] stride;
    reg silence=0;
    integer i;
    hdmi_capture dut(ac,rst,state,pcm,valid,vc,rst,tick,address,visible,wave,ready,stride);
    always #7 ac=~ac;
    always #11 vc=~vc;
    task boundary;begin
        @(negedge vc);tick=1;@(negedge vc);tick=0;
    end endtask
    task acquire;input integer last;begin
        repeat(12)@(negedge ac);
        for(i=0;i<512;i=i+1)begin
            // Invalid samples, including large outliers, must affect neither
            // the 512-point buffer nor its range.
            if(i%32==7)begin
                @(negedge ac);valid=0;pcm=32767;
                repeat(2)@(negedge ac);
            end
            @(negedge ac);valid=1;
            case(i%4)
                0:pcm=16'sd64;
                1:pcm=-16'sd64;
                2:pcm=16'sd32;
                3:pcm=-16'sd32;
            endcase
            if(silence)pcm=0;
            if(i==511)pcm=last;
        end
        @(negedge ac);valid=0;
        repeat(10)@(negedge vc);
    end endtask
    task check;input [8:0] index;input integer wanted;begin
        @(negedge vc);address=index;
        repeat(3)@(negedge vc);
        if($signed(wave)!==wanted)
            $fatal(1,"low-level waveform lost or scale torn: index=%d actual=%d want=%d",index,$signed(wave),wanted);
    end endtask
    task send_sample;input signed [15:0] value;begin
        @(negedge ac);valid=1;pcm=value;
    end endtask
    task check_low_note;
        input integer period;
        input integer spacing;
        input [1:0] expected_stride;
        integer n;
        begin
            rst=1;repeat(4)@(negedge vc);rst=0;repeat(12)@(negedge ac);
            send_sample(-16'sd64);send_sample(16'sd16);
            repeat(period-1)send_sample(-16'sd64);
            @(negedge ac);valid=0;
            boundary;repeat(12)@(negedge ac);
            send_sample(16'sd16);
            for(n=0;n<=255*spacing;n=n+1)
                send_sample(n==255*spacing ? 16'sd56 : (n%spacing==0 ? 16'sd24 : 16'sd40));
            @(negedge ac);valid=0;
            repeat(10)@(negedge vc);boundary;
            if(!ready || stride!==expected_stride)$fatal(1,"incorrect low note timebase");
            check(0,24);check(1,24);check(255,56);
        end
    endtask
    initial begin
        repeat(5)@(negedge vc);rst=0;boundary;
        acquire(-32);
        if(ready)$fatal(1,"published outside boundary");
        boundary;
        // Hand-derived: +/-64 need no right shift; a 64-pixel peak-to-peak trace.
        check(0,64);check(1,-64);check(2,32);check(3,-32);
        state=~state;
        acquire(16384);
        check(0,64); // New peak must not alter the currently visible bank.
        boundary;
        check(0,0);check(1,-1);check(511,64); // Last sample sets an 8-bit shift.
        acquire(-32768);boundary;check(511,-128); // Negative full scale.
        acquire(32767);boundary;check(511,127); // Positive full scale.
        acquire(128);boundary;check(511,64);
        acquire(256);boundary;check(511,64);
        acquire(512);boundary;check(511,64);
        acquire(1024);boundary;check(511,64);
        acquire(2048);boundary;check(511,64);
        acquire(4096);boundary;check(511,64);
        acquire(8192);boundary;check(511,64);
        acquire(-32);boundary;check(0,64);check(1,-64); // Recover quiet range.
        silence=1;acquire(0);boundary;check(0,0);check(1,0);check(511,0);
        if(visible!==state)$fatal(1,"state not coherent with waveform");
        rst=1;repeat(4)@(negedge vc);if(ready)$fatal(1,"reset exposed old data");
        state[52:47]=6'd1;
        rst=0;repeat(12)@(negedge ac);
        repeat(3)begin
            send_sample(16'sd16);
            repeat(8)send_sample(-16'sd64);
        end
        @(negedge ac);valid=0;
        boundary;repeat(12)@(negedge ac);
        repeat(8)send_sample(-16'sd64);
        send_sample(0); // Crossing starts the next 256-sample window.
        send_sample(16'sd16);
        repeat(254)send_sample(16'sd32);
        send_sample(16'sd48);
        @(negedge ac);valid=0;
        repeat(10)@(negedge vc);boundary;
        if(!ready)$fatal(1,"single voice did not publish after the short capture");
        if(stride!==0)$fatal(1,"short period did not use every sample");
        check(0,16);check(127,32);check(255,48);
        repeat(12)@(negedge ac);
        repeat(384)send_sample(16'sd32); // No crossing, bounded wait.
        repeat(256)send_sample(16'sd48);
        @(negedge ac);valid=0;
        repeat(10)@(negedge vc);boundary;
        check(0,48);check(255,48);
        check_low_note(300,2,2'd1);
        check_low_note(600,4,2'd2);
        $display("PASS quiet/silent PCM, all ranges, valid gaps, immutable scale, endpoint peaks and recovery");
        $finish;
    end
    initial begin #300000;$fatal(1,"lowlevel timeout");end
endmodule
