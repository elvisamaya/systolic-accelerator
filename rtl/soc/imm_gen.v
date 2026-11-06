// imm_gen.v
// Builds the sign-extended 32-bit immediate for each RISC-V instruction format.
// The bits are scattered differently in each format so that the sign bit is
// always instr[31] and most fields line up across formats (cheaper hardware).
`timescale 1ns/1ps
`default_nettype none
`include "rv32i_defs.vh"

module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);
    always @(*) begin
        case (instr[6:0])
            // I-type: loads, ALU-immediate, JALR
            `OP_IMM, `OP_LOAD, `OP_JALR:
                imm = {{20{instr[31]}}, instr[31:20]};
            // S-type: stores
            `OP_STORE:
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            // B-type: branches (offset is a multiple of 2)
            `OP_BRANCH:
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
            // U-type: LUI, AUIPC
            `OP_LUI, `OP_AUIPC:
                imm = {instr[31:12], 12'd0};
            // J-type: JAL (offset is a multiple of 2)
            `OP_JAL:
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'd0;
        endcase
    end
endmodule

`default_nettype wire
