`timescale 1ns/1ps
module tb_expression_mapper;
    reg clk=0,rst=1,ce=0,available=0,update=0,commit=0,invert_x=0;
    reg [47:0] raw=0;reg [3:0] valid=0;reg [1:0] channel=0;
    reg [95:0] calibration=0;reg [2:0] enable_mask=0,cal_mask=0;
    wire [16:0] expression,depth;wire signed [17:0] bend;
    wire [2:0] calibrated,active;wire busy,fault;
    integer checks=0,n,a,b,c,max_busy=0,clocks;
    reg signed [17:0] held_bend;reg [16:0] held_expression,held_depth;
    expression_mapper #(.STALE_SAMPLES(8),.DEAD_CODES(12'd16),.MIN_SPAN(16'd64)) dut(clk,rst,ce,raw,valid,available,update,channel,
        commit,calibration,cal_mask,invert_x,enable_mask,expression,bend,depth,calibrated,active,busy,fault);
    always #5 clk=~clk;
    task fresh;
        integer j;
        begin
            for(j=0;j<3;j=j+1)begin
                @(negedge clk);update=1;channel=j;@(negedge clk);update=0;
            end
        end
    endtask
    task frame;
        begin
            @(negedge clk);ce=1;@(negedge clk);ce=0;
            held_expression=expression;held_bend=bend;held_depth=depth;clocks=0;
            repeat(180)begin
                @(negedge clk);
                if(busy)clocks=clocks+1;
                if(expression!==held_expression || bend!==held_bend || depth!==held_depth)
                    $fatal(1,"parameters changed outside sample boundary");
            end
            if(clocks>max_busy)max_busy=clocks;
            if(busy||fault)$fatal(1,"mapper deadline/fault");
        end
    endtask
    task check;
        input [16:0] e;input signed [17:0] x;input [16:0] y;input [2:0] mask;
        begin
            checks=checks+1;
            if(expression!==e || bend!==x || depth!==y || active!==mask) begin
                $display("expected %0d %0d %0d/%b got %0d %0d %0d/%b",e,x,y,mask,expression,bend,depth,active);
                $fatal(1,"mapper check %0d",checks);
            end
        end
    endtask
    task apply_calibration;
        begin @(negedge clk);commit=1;@(negedge clk);commit=0;end
    endtask
    function integer axis_reference;
        input integer sample;
        begin
            if(sample<484) axis_reference=sample<=100 ? -65536 : -((484-sample)*65536/384);
            else if(sample>516) axis_reference=sample>=1500 ? 65536 : (sample-516)*65536/984;
            else axis_reference=0;
        end
    endfunction
    initial begin
        repeat(5)@(negedge clk);rst=0;frame;check(65536,0,0,0);
        // ADC presence alone never enables expression or calibrates itself.
        available=1;valid=15;raw={12'd0,12'd1500,12'd100,12'd1000};fresh;frame;fresh;frame;check(65536,0,0,0);
        calibration={12'd1500,12'd500,12'd100,12'd1500,12'd500,12'd100,12'd1000,12'd0};
        cal_mask=7;apply_calibration;enable_mask=7;fresh;frame;fresh;frame;check(65536,-65536,65536,7);
        raw={12'd0,12'd500,12'd500,12'd500};fresh;frame;fresh;frame;check(32768,0,0,7);
        raw={12'd0,12'd100,12'd1500,12'hfff};fresh;frame;fresh;frame;check(0,65536,65536,7);
        // Independent integer arithmetic exercises fractional division and both signs.
        for(n=0;n<500;n=n+1)begin
            a=($random & 2047)-200;b=($random & 2047)-200;c=($random & 2047)-200;
            raw={12'd0,c[11:0],b[11:0],a[11:0]};fresh;frame;fresh;frame;
            check(a<=0?0:(a>=1000?65536:a*65536/1000),axis_reference(b),
                axis_reference(c)<0?-axis_reference(c):axis_reference(c),7);
        end
        // A configuration update in flight must invalidate its old result.
        raw={12'd0,12'd500,12'd1500,12'd1000};fresh;
        @(negedge clk);ce=1;@(negedge clk);ce=0;repeat(6)@(negedge clk);
        invert_x=1;apply_calibration;frame;check(65536,0,0,0);fresh;frame;check(65536,-65536,0,7);
        // Reversed/zero spans invalidate only the affected sensor.
        calibration[23:12]=0;apply_calibration;fresh;frame;fresh;frame;check(65536,-65536,0,6);
        valid[1]=0;frame;check(65536,0,0,4);valid[1]=1;
        // Freshness needs a real update, not merely a stuck 'valid' level.
        repeat(10)frame;check(65536,0,0,0);fresh;frame;fresh;frame;check(65536,-65536,0,6);
        available=0;frame;check(65536,0,0,0);available=1;frame;check(65536,0,0,0);
        // In-flight device loss cannot leak a previous gain/bend at publication.
        fresh;@(negedge clk);ce=1;@(negedge clk);ce=0;repeat(12)@(negedge clk);available=0;
        repeat(170)@(negedge clk);frame;check(65536,0,0,0);
        // Signed calibration and explicitly sized parameter overrides.
        available=1;invert_x=0;
        calibration={12'sd500,-12'sd500,-12'sd1500,12'sd500,-12'sd500,-12'sd1500,12'sd1000,-12'sd1000};
        raw={12'd0,-12'sd500,-12'sd1000,12'd0};apply_calibration;fresh;frame;fresh;frame;
        check(32768,-(484*65536/984),0,7);
        // Only X goes stale while the converter continues publishing P and Y.
        for(n=0;n<9;n=n+1)begin
            @(negedge clk);channel=0;update=1;@(negedge clk);update=0;
            @(negedge clk);channel=2;update=1;@(negedge clk);update=0;frame;
        end
        check(32768,0,0,5);
        calibration[35:24]=12'sd500; // X minimum above its centre is invalid.
        @(negedge clk);commit=1;ce=1;@(negedge clk);commit=0;ce=0;
        check(65536,0,0,0);fresh;frame;fresh;frame;check(32768,0,0,5);
        // A too-fast frame is diagnosed and cannot change audio to a random gain.
        available=1;fresh;@(negedge clk);ce=1;@(negedge clk);ce=0;
        repeat(2)@(negedge clk);ce=1;@(negedge clk);ce=0;
        if(!fault || expression!==65536 || bend!==0 || depth!==0)$fatal(1,"overrun fallback");
        $display("PASS expression_mapper checks=%0d max_busy_cycles=%0d",checks,max_busy);$finish;
    end
endmodule

