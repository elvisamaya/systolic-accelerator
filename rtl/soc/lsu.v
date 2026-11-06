// lsu.v
// Load/store unit: adapts byte, halfword and word accesses to a 32-bit
// word-wide memory.
//  - Stores: replicate the data across the word and enable only the bytes
//    being written (byte enables).
//  - Loads: pick the right byte/halfword out of the word and sign- or
//    zero-extend it.
// Accesses are assumed naturally aligned (halfword on even address, word on
// a multiple of 4).
`timescale 1ns/1ps
`default_nettype none

module lsu (
    input  wire [2:0]  funct3,      // size + signedness, straight from the instruction
    input  wire [1:0]  addr_lo,     // byte offset within the word
    // store path
    input  wire [31:0] store_data,  // rs2
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_be,      // byte enables
    // load path
    input  wire [31:0] mem_rdata,
    output reg  [31:0] load_data
);
    // ---- store ----
    always @(*) begin
        case (funct3[1:0])
            2'b00: begin                                    // SB
                mem_wdata = {4{store_data[7:0]}};
                mem_be    = 4'b0001 << addr_lo;
            end
            2'b01: begin                                    // SH
                mem_wdata = {2{store_data[15:0]}};
                mem_be    = addr_lo[1] ? 4'b1100 : 4'b0011;
            end
            default: begin                                  // SW
                mem_wdata = store_data;
                mem_be    = 4'b1111;
            end
        endcase
    end

    // ---- load ----
    reg [7:0]  byte_sel;
    reg [15:0] half_sel;
    always @(*) begin
        case (addr_lo)
            2'd0: byte_sel = mem_rdata[7:0];
            2'd1: byte_sel = mem_rdata[15:8];
            2'd2: byte_sel = mem_rdata[23:16];
            default: byte_sel = mem_rdata[31:24];
        endcase
        half_sel = addr_lo[1] ? mem_rdata[31:16] : mem_rdata[15:0];

        case (funct3)
            3'b000:  load_data = {{24{byte_sel[7]}}, byte_sel};     // LB
            3'b001:  load_data = {{16{half_sel[15]}}, half_sel};    // LH
            3'b100:  load_data = {24'd0, byte_sel};                 // LBU
            3'b101:  load_data = {16'd0, half_sel};                 // LHU
            default: load_data = mem_rdata;                         // LW
        endcase
    end
endmodule

`default_nettype wire
