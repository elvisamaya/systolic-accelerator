// regfile.v
// 32 x 32-bit register file: two combinational read ports, one write port.
//  - x0 always reads as zero; writes to x0 are ignored.
//  - BYPASS = 1 (write-through): a read of the register being written this
//    cycle returns the new value, so an instruction in decode sees a result
//    being written back in the same cycle (removes one pipeline hazard case).
//    Must be 0 in a single-cycle core: there the write data is computed FROM
//    the read data in the same cycle, and write-through would form a
//    combinational loop (e.g. addi t0, t0, 1).
`timescale 1ns/1ps
`default_nettype none

module regfile #(
    parameter integer BYPASS = 0
) (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);
    reg [31:0] regs [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) regs[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (we && waddr != 5'd0)
            regs[waddr] <= wdata;
    end

    assign rdata1 = (raddr1 == 5'd0)                        ? 32'd0 :
                    (BYPASS != 0 && we && waddr == raddr1) ? wdata : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0)                        ? 32'd0 :
                    (BYPASS != 0 && we && waddr == raddr2) ? wdata : regs[raddr2];
endmodule

`default_nettype wire
