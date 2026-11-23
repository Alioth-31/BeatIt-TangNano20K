`timescale 1ns/1ps
module tb_pcm_fx_chain;
    reg clk=0,rst=1,valid=0;
    reg signed [15:0] data=0;
    wire signed [15:0] dry,echo,all_fx;
    wire vd,ve,va,fd,fe,fa;
    wire signed [15:0] clean;
    wire vc,fc;
    integer clean_count=0;
    integer n, dry_count=0, echo_count=0, all_count=0;
    integer nonzero_echo=0, all_changed=0;
    reg [1:0] mode=0;
    pcm_fx_chain passthrough(clk,rst,data,valid,mode,dry,vd,fd,16'd0,2'd0,1'b0);
    pcm_fx_chain #(.DELAY_ENABLE(1)) delayed(clk,rst,data,valid,mode,echo,ve,fe,16'd0,2'd0,1'b0);
    pcm_fx_chain #(.DC_ENABLE(1),.TREMOLO_ENABLE(1),.TONE_ENABLE(1),.DELAY_ENABLE(1)) combined(clk,rst,data,valid,mode,all_fx,va,fa,16'd0,2'd0,1'b0);
    pcm_fx_chain #(.TREMOLO_ENABLE(1),.DELAY_ENABLE(1),.REVERB_ENABLE(1)) clean_preset(
        clk,rst,data,valid,mode,clean,vc,fc,16'd8192,2'd1,1'b1);
    always #5 clk=~clk;
    always @(posedge clk) begin
        // Pure combinational bypass path must retain original valid timing.
        if(!rst && vd && (dry !== data || !valid || fd)) begin
            $display("FAIL FX default dry/valid/fault"); $finish;
        end
    end
    task emit;
        input signed [15:0] x;
        begin
            @(negedge clk); data=x; valid=1;
            @(negedge clk); valid=0;
            repeat(6) @(negedge clk);
        end
    endtask
    always @(negedge clk) begin
        #1;
        if(!rst) begin
        if(vd) dry_count=dry_count+1;
        if(vc)begin
            clean_count=clean_count+1;
            if(clean!==data || fc)$fatal(1,"clean preset must pass dry data without echo or tremolo");
        end
        if(ve) begin
            echo_count=echo_count+1;
            if(echo_count==4097 && echo!==16'sd2000) begin
                $display("FAIL FX echo impulse tap sample=%d val=%d",echo_count,echo); $finish;
            end
            if(echo_count==4097 && echo!=0) nonzero_echo=nonzero_echo+1;
        end
        if(va) begin
            all_count=all_count+1;
            if(all_fx!==echo) all_changed=all_changed+1;
        end
        end
    end
    initial begin
        repeat(4) @(negedge clk); rst=0;
        mode=2; emit(4000);
        for(n=1;n<=4200;n=n+1) emit(0);
        if(fd || fe || fa || dry_count!=4201 || echo_count!=4201 || all_count!=4201 ||
           nonzero_echo!=1 || all_changed<2 || clean_count!=4201 || fc) begin
            $display("FAIL FX chain counts=%d/%d/%d changed=%d faults=%b%b%b",
                     dry_count,echo_count,all_count,all_changed,fd,fe,fa);
            $finish;
        end
        $display("PASS pcm_fx_chain: exact dry path, 4096-sample echo, chained effects and strobe counts");
        $finish;
    end
endmodule
