// dmem.v
// Data memory: word-wide, combinational read, synchronous write with
// per-byte write enables. Addresses wrap within DEPTH words.
`timescale 1ns/1ps
`default_nettype none

module dmem #(
    parameter integer DEPTH = 1024          // words (4 KiB)
) (
    input  wire        clk,
    input  wire        we,
    input  wire [3:0]  be,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] addr,            // only the word-index bits are used
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);
    localparam integer AW = $clog2(DEPTH);

    reg [31:0] mem [0:DEPTH-1];
    wire [AW-1:0] widx = addr[AW+1:2];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[widx][7:0]   <= wdata[7:0];
            if (be[1]) mem[widx][15:8]  <= wdata[15:8];
            if (be[2]) mem[widx][23:16] <= wdata[23:16];
            if (be[3]) mem[widx][31:24] <= wdata[31:24];
        end
    end

    assign rdata = mem[widx];
endmodule

`default_nettype wire
