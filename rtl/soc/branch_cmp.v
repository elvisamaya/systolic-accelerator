// branch_cmp.v
// Decides whether a conditional branch is taken, based on funct3.
`timescale 1ns/1ps
`default_nettype none

module branch_cmp (
    input  wire [2:0]  funct3,
    input  wire [31:0] a,       // rs1
    input  wire [31:0] b,       // rs2
    output reg         taken
);
    always @(*) begin
        case (funct3)
            3'b000:  taken = (a == b);                       // BEQ
            3'b001:  taken = (a != b);                       // BNE
            3'b100:  taken = ($signed(a) <  $signed(b));     // BLT
            3'b101:  taken = ($signed(a) >= $signed(b));     // BGE
            3'b110:  taken = (a <  b);                       // BLTU
            3'b111:  taken = (a >= b);                       // BGEU
            default: taken = 1'b0;
        endcase
    end
endmodule

`default_nettype wire
