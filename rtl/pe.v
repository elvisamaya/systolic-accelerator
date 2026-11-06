// pe.v
// Processing element: one cell of the systolic array.
//
//            b_in
//             |
//   a_in --> [ acc += a*b ] --> a_out
//             |
//            b_out
//
// Every cycle it multiplies the two int8 operands passing through it, adds
// the product to its own 32-bit accumulator, and forwards both operands to
// its neighbours (a to the right, b downwards) one cycle later.
// "Output stationary": each PE's result stays put; the inputs move.
`timescale 1ns/1ps
`default_nettype none

module pe #(
    parameter integer DW = 8,       // operand width (int8)
    parameter integer AW = 32       // accumulator width
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 clear,      // zero the accumulator (start of a job)
    input  wire                 valid_in,   // a_in/b_in carry real data this cycle
    input  wire signed [DW-1:0] a_in,
    input  wire signed [DW-1:0] b_in,
    output reg                  valid_out,
    output reg  signed [DW-1:0] a_out,
    output reg  signed [DW-1:0] b_out,
    output reg  signed [AW-1:0] acc
);
    // signed multiply: int8 x int8 -> 16-bit product, sign-extended to AW bits
    wire signed [2*DW-1:0] product = a_in * b_in;
    wire signed [AW-1:0]   product_ext = {{(AW-2*DW){product[2*DW-1]}}, product};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            a_out     <= {DW{1'b0}};
            b_out     <= {DW{1'b0}};
            acc       <= {AW{1'b0}};
        end else begin
            valid_out <= valid_in;
            a_out     <= a_in;
            b_out     <= b_in;
            if (clear)
                acc <= {AW{1'b0}};
            else if (valid_in)
                acc <= acc + product_ext;
        end
    end
endmodule

`default_nettype wire
