// imem.v
// Instruction memory (read-only, combinational read).
// Load a program with INIT_FILE, or from a testbench with
// $readmemh(file, dut.u_imem.mem).
`timescale 1ns/1ps
`default_nettype none

module imem #(
    parameter integer DEPTH     = 1024,     // words (4 KiB)
    parameter         INIT_FILE = ""
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] addr,            // only the word-index bits are used
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [31:0] instr
);
    localparam integer AW = $clog2(DEPTH);

    reg [31:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    assign instr = mem[addr[AW+1:2]];       // word-addressed
endmodule

`default_nettype wire
