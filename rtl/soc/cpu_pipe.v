// cpu_pipe.v
// The 5-stage pipelined RV32I core from github.com/elvisamaya/processor
// (rtl/core_pipe.v), with one change: data memory moved OUTSIDE the core,
// behind a data bus, so the SoC can map other devices (the accelerator)
// into the address space next to RAM.
//
// 5-stage pipelined RV32I core:
//
//   IF  -> ID  -> EX  -> MEM -> WB
//   fetch  decode  ALU    data    write
//          + regs  branch memory  back
//
// Up to five instructions are in flight at once, one per stage, so the
// clock only has to cover the slowest STAGE rather than the whole
// instruction. The cost is hazards: instructions that depend on results
// still moving through the pipeline.
//
// Hazard handling
//  * Data hazards
//      FORWARDING = 0: decode stalls until the producing instruction has
//                      reached write-back (the register file writes through,
//                      so the value is visible in that same cycle).
//      FORWARDING = 1: results are bypassed from the MEM and WB stages
//                      straight into the ALU inputs. Only a load followed
//                      immediately by a user of its result must stall
//                      (1 bubble), because load data isn't ready until MEM.
//  * Control hazards
//      Branches and jumps resolve in EX. The pipeline predicts "not taken"
//      and keeps fetching sequentially; on a taken branch or jump the two
//      younger instructions (in IF/ID and ID/EX) are flushed (2 bubbles).
//  * ECALL/EBREAK stops fetching once it leaves decode; `halted` rises when
//    it reaches write-back, after every older instruction has completed.
`timescale 1ns/1ps
`default_nettype none
`include "rv32i_defs.vh"

module cpu_pipe #(
    parameter integer FORWARDING = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         halted,
    output reg         illegal_seen,
    output reg  [31:0] cycles,
    output reg  [31:0] instret,
    // data bus (driven from the MEM stage; reads are combinational)
    output wire [31:0] dbus_addr,
    output wire [31:0] dbus_wdata,
    output wire [3:0]  dbus_be,
    output wire        dbus_we,
    input  wire [31:0] dbus_rdata
);
    // =====================================================================
    // Pipeline registers
    // =====================================================================
    reg  [31:0] pc;
    reg         fetch_stop;                     // set once ECALL leaves decode

    // IF/ID
    reg         ifid_valid;
    reg  [31:0] ifid_pc, ifid_instr;

    // ID/EX
    reg         idex_valid;
    reg  [31:0] idex_pc, idex_rv1, idex_rv2, idex_imm;
    reg  [4:0]  idex_rs1, idex_rs2, idex_rd;
    reg  [2:0]  idex_funct3;
    reg  [3:0]  idex_alu_op;
    reg  [1:0]  idex_a_sel, idex_wb_sel;
    reg         idex_b_imm, idex_reg_write, idex_mem_read, idex_mem_write;
    reg         idex_branch, idex_jal, idex_jalr, idex_halt, idex_illegal;

    // EX/MEM
    reg         exmem_valid;
    reg  [31:0] exmem_result, exmem_rv2;
    reg  [4:0]  exmem_rd;
    reg  [2:0]  exmem_funct3;
    reg  [1:0]  exmem_wb_sel;
    reg         exmem_reg_write, exmem_mem_write, exmem_halt, exmem_illegal;

    // MEM/WB
    reg         memwb_valid;
    reg  [31:0] memwb_data;
    reg  [4:0]  memwb_rd;
    reg         memwb_reg_write, memwb_halt, memwb_illegal;

    // =====================================================================
    // IF: fetch
    // =====================================================================
    wire [31:0] if_instr;
    imem u_imem (.addr(pc), .instr(if_instr));

    // =====================================================================
    // ID: decode + register read
    // =====================================================================
    wire [4:0] id_rs1 = ifid_instr[19:15];
    wire [4:0] id_rs2 = ifid_instr[24:20];
    wire [4:0] id_rd  = ifid_instr[11:7];

    wire        id_reg_write, id_mem_read, id_mem_write, id_b_imm, id_branch, id_jal, id_jalr;
    wire        id_uses_rs1, id_uses_rs2, id_halt, id_illegal;
    wire [1:0]  id_wb_sel, id_a_sel;
    wire [3:0]  id_alu_op;
    decoder u_dec (
        .instr(ifid_instr), .reg_write(id_reg_write), .mem_read(id_mem_read),
        .mem_write(id_mem_write), .wb_sel(id_wb_sel), .a_sel(id_a_sel), .b_imm(id_b_imm),
        .alu_op(id_alu_op), .branch(id_branch), .jal(id_jal), .jalr(id_jalr),
        .uses_rs1(id_uses_rs1), .uses_rs2(id_uses_rs2), .halt(id_halt), .illegal(id_illegal)
    );

    wire [31:0] id_imm;
    imm_gen u_imm (.instr(ifid_instr), .imm(id_imm));

    wire        wb_we = memwb_valid && memwb_reg_write && !halted;
    wire [31:0] id_rv1, id_rv2;
    regfile #(.BYPASS(1)) u_rf (
        .clk(clk), .we(wb_we), .waddr(memwb_rd), .wdata(memwb_data),
        .raddr1(id_rs1), .raddr2(id_rs2), .rdata1(id_rv1), .rdata2(id_rv2)
    );

    // ---- hazard detection ----
    // Does a producer in EX (ID/EX register) or MEM (EX/MEM register) write a
    // register that the instruction in decode reads?
    wire ex_writes  = idex_valid  && idex_reg_write  && (idex_rd  != 5'd0);
    wire mem_writes = exmem_valid && exmem_reg_write && (exmem_rd != 5'd0);

    wire dep_ex  = ex_writes  && ((id_uses_rs1 && idex_rd  == id_rs1) ||
                                  (id_uses_rs2 && idex_rd  == id_rs2));
    wire dep_mem = mem_writes && ((id_uses_rs1 && exmem_rd == id_rs1) ||
                                  (id_uses_rs2 && exmem_rd == id_rs2));

    wire load_use = dep_ex && idex_mem_read;    // load result needed next cycle

    wire stall = ifid_valid && ((FORWARDING != 0) ? load_use : (dep_ex || dep_mem));

    // =====================================================================
    // EX: execute
    // =====================================================================
    // ---- forwarding (bypass) ----
    // The newest value wins: EX/MEM (1 instruction ahead) before MEM/WB (2 ahead).
    wire [31:0] wb_data;
    wire fwd_a_mem = (FORWARDING != 0) && mem_writes && (exmem_rd == idex_rs1);
    wire fwd_b_mem = (FORWARDING != 0) && mem_writes && (exmem_rd == idex_rs2);
    wire fwd_a_wb  = (FORWARDING != 0) && wb_we && (memwb_rd != 5'd0) && (memwb_rd == idex_rs1);
    wire fwd_b_wb  = (FORWARDING != 0) && wb_we && (memwb_rd != 5'd0) && (memwb_rd == idex_rs2);

    wire [31:0] ex_rs1 = fwd_a_mem ? exmem_result : fwd_a_wb ? wb_data : idex_rv1;
    wire [31:0] ex_rs2 = fwd_b_mem ? exmem_result : fwd_b_wb ? wb_data : idex_rv2;

    wire [31:0] alu_a = (idex_a_sel == `A_PC)   ? idex_pc :
                        (idex_a_sel == `A_ZERO) ? 32'd0   : ex_rs1;
    wire [31:0] alu_b = idex_b_imm ? idex_imm : ex_rs2;
    wire [31:0] alu_y;
    alu u_alu (.op(idex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

    wire br_taken;
    branch_cmp u_br (.funct3(idex_funct3), .a(ex_rs1), .b(ex_rs2), .taken(br_taken));

    wire        ex_redirect = idex_valid && (idex_jal || idex_jalr || (idex_branch && br_taken));
    wire [31:0] ex_target   = idex_jalr ? {alu_y[31:1], 1'b0} : (idex_pc + idex_imm);
    wire [31:0] ex_result   = (idex_wb_sel == `WB_PC4) ? (idex_pc + 32'd4) : alu_y;

    // =====================================================================
    // MEM: data memory
    // =====================================================================
    wire [31:0] mem_rdata, mem_wdata, load_data;
    wire [3:0]  mem_be;
    lsu u_lsu (
        .funct3(exmem_funct3), .addr_lo(exmem_result[1:0]),
        .store_data(exmem_rv2), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_rdata(mem_rdata), .load_data(load_data)
    );
    assign dbus_addr  = exmem_result;
    assign dbus_wdata = mem_wdata;
    assign dbus_be    = mem_be;
    assign dbus_we    = exmem_valid && exmem_mem_write && !halted;
    assign mem_rdata  = dbus_rdata;
    wire [31:0] mem_result = (exmem_wb_sel == `WB_MEM) ? load_data : exmem_result;

    // =====================================================================
    // WB: write-back (register file write happens via wb_we above)
    // =====================================================================
    assign wb_data = memwb_data;

    // =====================================================================
    // Pipeline advance
    // =====================================================================
    // ECALL leaving decode this cycle: stop fetching younger instructions
    wire halt_issue = ifid_valid && id_halt && !stall && !ex_redirect;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'd0;  fetch_stop <= 1'b0;
            halted <= 1'b0;  illegal_seen <= 1'b0;
            cycles <= 32'd0; instret <= 32'd0;
            ifid_valid <= 1'b0;  idex_valid <= 1'b0;
            exmem_valid <= 1'b0; memwb_valid <= 1'b0;
            ifid_pc <= 32'd0; ifid_instr <= 32'h0000_0013;
            idex_pc <= 32'd0; idex_rv1 <= 32'd0; idex_rv2 <= 32'd0; idex_imm <= 32'd0;
            idex_rs1 <= 5'd0; idex_rs2 <= 5'd0; idex_rd <= 5'd0; idex_funct3 <= 3'd0;
            idex_alu_op <= `ALU_ADD; idex_a_sel <= `A_RS1; idex_wb_sel <= `WB_ALU;
            idex_b_imm <= 1'b0; idex_reg_write <= 1'b0; idex_mem_read <= 1'b0;
            idex_mem_write <= 1'b0; idex_branch <= 1'b0; idex_jal <= 1'b0;
            idex_jalr <= 1'b0; idex_halt <= 1'b0; idex_illegal <= 1'b0;
            exmem_result <= 32'd0; exmem_rv2 <= 32'd0; exmem_rd <= 5'd0;
            exmem_funct3 <= 3'd0; exmem_wb_sel <= `WB_ALU; exmem_reg_write <= 1'b0;
            exmem_mem_write <= 1'b0; exmem_halt <= 1'b0; exmem_illegal <= 1'b0;
            memwb_data <= 32'd0; memwb_rd <= 5'd0; memwb_reg_write <= 1'b0;
            memwb_halt <= 1'b0; memwb_illegal <= 1'b0;
        end else if (!halted) begin
            cycles <= cycles + 32'd1;

            // ---- WB: retire ----
            if (memwb_valid) begin
                instret <= instret + 32'd1;
                if (memwb_halt)    halted       <= 1'b1;
                if (memwb_illegal) illegal_seen <= 1'b1;
            end

            // ---- MEM -> WB ----
            memwb_valid     <= exmem_valid;
            memwb_data      <= mem_result;
            memwb_rd        <= exmem_rd;
            memwb_reg_write <= exmem_reg_write;
            memwb_halt      <= exmem_halt;
            memwb_illegal   <= exmem_illegal;

            // ---- EX -> MEM ----
            exmem_valid     <= idex_valid;
            exmem_result    <= ex_result;
            exmem_rv2       <= ex_rs2;
            exmem_rd        <= idex_rd;
            exmem_funct3    <= idex_funct3;
            exmem_wb_sel    <= idex_wb_sel;
            exmem_reg_write <= idex_reg_write;
            exmem_mem_write <= idex_mem_write;
            exmem_halt      <= idex_halt;
            exmem_illegal   <= idex_illegal;

            // ---- ID -> EX: a bubble on flush or stall ----
            idex_valid     <= ifid_valid && !stall && !ex_redirect;
            idex_pc        <= ifid_pc;
            idex_rv1       <= id_rv1;
            idex_rv2       <= id_rv2;
            idex_imm       <= id_imm;
            idex_rs1       <= id_rs1;
            idex_rs2       <= id_rs2;
            idex_rd        <= id_rd;
            idex_funct3    <= ifid_instr[14:12];
            idex_alu_op    <= id_alu_op;
            idex_a_sel     <= id_a_sel;
            idex_wb_sel    <= id_wb_sel;
            idex_b_imm     <= id_b_imm;
            idex_reg_write <= id_reg_write;
            idex_mem_read  <= id_mem_read;
            idex_mem_write <= id_mem_write;
            idex_branch    <= id_branch;
            idex_jal       <= id_jal;
            idex_jalr      <= id_jalr;
            idex_halt      <= id_halt;
            idex_illegal   <= id_illegal;

            // ---- IF -> ID and PC ----
            if (ex_redirect) begin                  // taken branch / jump: flush, refetch
                ifid_valid <= 1'b0;
                pc         <= ex_target;
            end else if (stall) begin               // hold IF/ID and PC
            end else if (halt_issue || fetch_stop) begin
                ifid_valid <= 1'b0;                 // nothing younger than ECALL
                fetch_stop <= 1'b1;
            end else begin
                ifid_valid <= 1'b1;
                ifid_pc    <= pc;
                ifid_instr <= if_instr;
                pc         <= pc + 32'd4;
            end
        end
    end
endmodule

`default_nettype wire
