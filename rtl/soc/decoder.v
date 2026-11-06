// decoder.v
// Main control unit: turns an instruction into the control signals that
// steer the datapath. Purely combinational.
`timescale 1ns/1ps
`default_nettype none
`include "rv32i_defs.vh"

module decoder (
    input  wire [31:0] instr,
    output reg         reg_write,   // write rd
    output reg         mem_read,    // load
    output reg         mem_write,   // store
    output reg  [1:0]  wb_sel,      // `WB_ALU / `WB_MEM / `WB_PC4
    output reg  [1:0]  a_sel,       // ALU operand A: rs1 / pc / zero
    output reg         b_imm,       // ALU operand B: 1 = immediate, 0 = rs2
    output reg  [3:0]  alu_op,
    output reg         branch,      // conditional branch
    output reg         jal,
    output reg         jalr,
    output reg         uses_rs1,    // reads rs1 (for hazard detection)
    output reg         uses_rs2,    // reads rs2
    output reg         halt,        // ECALL / EBREAK: stop the core
    output reg         illegal
);
    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire       alt    = instr[30];    // selects SUB / SRA

    // ALU operation for OP and OP-IMM, chosen by funct3
    reg [3:0] arith_op;
    always @(*) begin
        case (funct3)
            3'b000: arith_op = `ALU_ADD;
            3'b001: arith_op = `ALU_SLL;
            3'b010: arith_op = `ALU_SLT;
            3'b011: arith_op = `ALU_SLTU;
            3'b100: arith_op = `ALU_XOR;
            3'b101: arith_op = alt ? `ALU_SRA : `ALU_SRL;
            3'b110: arith_op = `ALU_OR;
            default: arith_op = `ALU_AND;
        endcase
    end

    always @(*) begin
        // defaults: a harmless no-op
        reg_write = 1'b0;  mem_read = 1'b0;  mem_write = 1'b0;
        wb_sel    = `WB_ALU;  a_sel = `A_RS1;  b_imm = 1'b0;
        alu_op    = `ALU_ADD;
        branch    = 1'b0;  jal = 1'b0;  jalr = 1'b0;
        uses_rs1  = 1'b0;  uses_rs2 = 1'b0;
        halt      = 1'b0;  illegal = 1'b0;

        case (opcode)
            `OP_LUI: begin                  // rd = imm
                reg_write = 1'b1; a_sel = `A_ZERO; b_imm = 1'b1;
            end
            `OP_AUIPC: begin                // rd = pc + imm
                reg_write = 1'b1; a_sel = `A_PC; b_imm = 1'b1;
            end
            `OP_JAL: begin                  // rd = pc + 4; pc = pc + imm
                reg_write = 1'b1; wb_sel = `WB_PC4; jal = 1'b1;
            end
            `OP_JALR: begin                 // rd = pc + 4; pc = (rs1 + imm) & ~1
                reg_write = 1'b1; wb_sel = `WB_PC4; jalr = 1'b1;
                b_imm = 1'b1; uses_rs1 = 1'b1;
            end
            `OP_BRANCH: begin               // if (rs1 ? rs2) pc = pc + imm
                branch = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            `OP_LOAD: begin                 // rd = mem[rs1 + imm]
                reg_write = 1'b1; mem_read = 1'b1; wb_sel = `WB_MEM;
                b_imm = 1'b1; uses_rs1 = 1'b1;
            end
            `OP_STORE: begin                // mem[rs1 + imm] = rs2
                mem_write = 1'b1; b_imm = 1'b1;
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
            end
            `OP_IMM: begin                  // rd = rs1 op imm
                reg_write = 1'b1; b_imm = 1'b1; uses_rs1 = 1'b1;
                // no SUBI: funct3 000 is always ADD. instr[30] only matters
                // for shifts (SRAI vs SRLI), which arith_op already handles.
                alu_op = arith_op;
            end
            `OP_REG: begin                  // rd = rs1 op rs2
                reg_write = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                alu_op = (funct3 == 3'b000 && alt) ? `ALU_SUB : arith_op;
            end
            `OP_FENCE: begin
                // single core, in-order memory: nothing to do
            end
            `OP_SYSTEM: begin
                if (instr == 32'h0000_0073 || instr == 32'h0010_0073)
                    halt = 1'b1;            // ECALL / EBREAK end the program
                else
                    illegal = 1'b1;         // CSRs not implemented
            end
            default: illegal = 1'b1;
        endcase
    end
endmodule

`default_nettype wire
