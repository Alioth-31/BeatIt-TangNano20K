`timescale 1ns/1ps
// One synchronous read and one write per clock for packed voice state.
// A same-address read during a write is unspecified; the scheduler must ignore
// that q value. No reset: the core initializes every live address before use.
module osc_envelope_ram #(
    parameter DEPTH=32, parameter WIDTH=72, parameter ADDR_W=5
)(input clk,input [ADDR_W-1:0] read_addr,output [WIDTH-1:0] q,
  input write_enable,input [ADDR_W-1:0] write_addr,input [WIDTH-1:0] data);
    // GW2A semi-dual-port RAM exposes 36 bits for this 1R/1W interface.
    // Retain the former 18-bit mapping for addresses deeper than 512 words.
    localparam BANK_WIDTH=(ADDR_W<=9)?36:18;
    localparam BANKS=(WIDTH+BANK_WIDTH-1)/BANK_WIDTH;
`ifdef GOWIN_PRIMITIVES
    wire [BANKS*BANK_WIDTH-1:0] result;
    wire [BANKS*BANK_WIDTH-1:0] padded_data={{(BANKS*BANK_WIDTH-WIDTH){1'b0}},data};
    assign q=result[WIDTH-1:0];
    genvar g;
    generate for(g=0;g<BANKS;g=g+1) begin: banks
      if(ADDR_W<=9)begin: semi_dual
        SDPX9 #(.BIT_WIDTH_0(36),.BIT_WIDTH_1(36),.READ_MODE(1'b0))
        storage(.DO(result[g*36+:36]),.DI(padded_data[g*36+:36]),.BLKSEL(3'b0),
          // [13:5] selects a word; [3:0] enable all four 9-bit write lanes.
          .ADA({{(9-ADDR_W){1'b0}},write_addr,5'b01111}),
          .ADB({{(9-ADDR_W){1'b0}},read_addr,5'b00000}),
          .WREA(write_enable),.WREB(1'b0),.CLKA(clk),.CLKB(clk),
          .CEA(1'b1),.CEB(1'b1),.OCE(1'b1),.RESETA(1'b0),.RESETB(1'b0));
      end else begin: deep_dual
        wire [17:0] unused;
        DPX9 #(.BIT_WIDTH_0(18),.BIT_WIDTH_1(18),.READ_MODE0(1'b0),.READ_MODE1(1'b0))
        storage(.DOA(result[g*18+:18]),.DOB(unused),.DIA(18'd0),.DIB(padded_data[g*18+:18]),.BLKSEL(3'b0),
          // Address [13:4] selects a word; [1:0] enable both 9-bit write lanes.
          .ADA({{(10-ADDR_W){1'b0}},read_addr,4'b0}),.ADB({{(10-ADDR_W){1'b0}},write_addr,4'b0011}),.WREA(1'b0),.WREB(write_enable),
          .CLKA(clk),.CLKB(clk),.CEA(1'b1),.CEB(1'b1),.OCEA(1'b1),.OCEB(1'b1),
          .RESETA(1'b0),.RESETB(1'b0));
      end
    end endgenerate
`else
    reg [WIDTH-1:0] words [0:DEPTH-1];
    reg [WIDTH-1:0] value;
    assign q=value;
    always @(posedge clk) begin
        value<=words[read_addr];
        if(write_enable)words[write_addr]<=data;
    end
`endif
endmodule
