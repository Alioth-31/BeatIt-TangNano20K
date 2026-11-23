`timescale 1ns/1ps
module tb_control_events;
    reg clk=0,rst=1;
    reg [1:0] vab=3,bab=3;
    reg vsw=1,bsw=1;
    wire vu,vd,bu,bd,br,pn;
    integer nvu=0,nvd=0,nbu=0,nbd=0,nbr=0,npn=0;
    control_surface #(.DEBOUNCE_CYCLES(8),.ENCODER_FILTER_CYCLES(2)) dut(
        .clk(clk),.rst(rst),.keys_n(8'hff),.volume_ab(vab),.volume_sw_n(vsw),
        .bend_ab(bab),.bend_sw_n(bsw),.test_button(1'b0),
        .vol_up(vu),.vol_down(vd),.bend_up(bu),.bend_down(bd),.bend_reset(br),.preset_next(pn));
    always #5 clk=~clk;
    always @(posedge clk) if(!rst) begin
        if(vu) nvu=nvu+1; if(vd) nvd=nvd+1;
        if(bu) nbu=nbu+1; if(bd) nbd=nbd+1;
        if(br) nbr=nbr+1; if(pn) npn=npn+1;
    end
    task turn; input reverse; input knob; integer e; reg [1:0] code;
        begin
            for(e=0;e<4;e=e+1) begin
                case(e) 0:code=reverse?1:2; 1:code=0; 2:code=reverse?2:1; default:code=3; endcase
                if(knob) bab=code; else vab=code;
                repeat(12) @(negedge clk);
            end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0; repeat(20) @(negedge clk);
        turn(0,0); turn(1,0); turn(0,1); turn(1,1);
        vsw=0; bsw=0; repeat(60) @(negedge clk);
        if(nvu!=1||nvd!=1||nbu!=1||nbd!=1||nbr!=1||npn!=1) begin
            $display("FAIL physical control event counts %d %d %d %d %d %d",nvu,nvd,nbu,nbd,nbr,npn); $finish;
        end
        vsw=1; bsw=1; repeat(20) @(negedge clk);
        if(nbr!=1||npn!=1) begin $display("FAIL release emitted action"); $finish; end
        $display("PASS physical deltas and one-shot button events"); $finish;
    end
endmodule
