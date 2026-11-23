`timescale 1ns/1ps
module debounce #(
    parameter STABLE_CYCLES=98304,
    parameter INITIAL_LEVEL=1
)(input clk, input rst, input pin, output reg stable);
    function integer clog2;
        input integer value; integer v;
        begin v=value-1; clog2=0; while(v>0) begin v=v>>1; clog2=clog2+1; end end
    endfunction
    localparam WIDTH=(STABLE_CYCLES<2)?1:clog2(STABLE_CYCLES);
    (* syn_preserve=1, ASYNC_REG="TRUE" *) reg meta, sync;
    reg [WIDTH-1:0] count;
    always @(posedge clk) begin
        if(rst) begin meta<=INITIAL_LEVEL; sync<=INITIAL_LEVEL; stable<=INITIAL_LEVEL; count<=0; end
        else begin
            meta<=pin; sync<=meta;
            if(sync==stable) count<=0;
            else if(count==STABLE_CYCLES-1) begin stable<=sync; count<=0; end
            else count<=count+1'b1;
        end
    end
endmodule
