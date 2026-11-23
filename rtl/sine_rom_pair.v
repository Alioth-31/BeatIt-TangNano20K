`timescale 1ns/1ps
// Two synchronous read ports; one 1024 x 16 ROM per pair of voices.
module sine_rom_pair #(
    parameter INIT_FILE="rtl/sine.hex"
)(input clk, input [9:0] addr_a, input [9:0] addr_b,
  output signed [15:0] q_a, output signed [15:0] q_b);
`ifdef GOWIN_PRIMITIVES
    // Explicit true dual-port block: automatic ROM inference duplicates storage.
    DP #(.BIT_WIDTH_0(16),.BIT_WIDTH_1(16),.READ_MODE0(1'b0),.READ_MODE1(1'b0)
        `include "sine_dpb_init.vh"
    ) storage(.DOA(q_a),.DOB(q_b),.DIA(16'b0),.DIB(16'b0),.BLKSEL(3'b0),
        .ADA({addr_a,4'b0}),.ADB({addr_b,4'b0}),.WREA(1'b0),.WREB(1'b0),
        .CLKA(clk),.CLKB(clk),.CEA(1'b1),.CEB(1'b1),.OCEA(1'b1),.OCEB(1'b1),
        .RESETA(1'b0),.RESETB(1'b0));
`else
    reg signed [15:0] qa,qb;
    assign q_a=qa; assign q_b=qb;
    (* syn_romstyle="block_rom" *) reg signed [15:0] table_data [0:1023];
    initial $readmemh(INIT_FILE,table_data);
    always @(posedge clk) begin qa<=table_data[addr_a]; qb<=table_data[addr_b]; end
`endif
endmodule
