// systolic_array.v
// N x N output-stationary systolic array computing C = A * B.
//
// Each cycle k the caller supplies one column of A (A[0..N-1][k]) and one row
// of B (B[k][0..N-1]). Row i of A enters the left edge delayed by i cycles
// and column j of B enters the top edge delayed by j cycles ("skewing"), so
// that A[i][k] and B[k][j] meet in PE(i,j) on the same cycle:
//
//              B[k][0]  B[k][1]  B[k][2]      (column j delayed j cycles)
//                 |        |        |
//   A[0][k] ---> PE00 --> PE01 --> PE02
//                 |        |        |
//   A[1][k] -D-> PE10 --> PE11 --> PE12       (row i delayed i cycles)
//                 |        |        |
//   A[2][k] DD-> PE20 --> PE21 --> PE22
//
// After the last k, PE(i,j) holds C[i][j]. The result of the far corner
// (N-1,N-1) is ready DRAIN = 2N-1 cycles after the last input.
// N*N multiply-accumulates happen every cycle once the array is full.
`timescale 1ns/1ps
`default_nettype none

module systolic_array #(
    parameter integer N  = 4,
    parameter integer DW = 8,
    parameter integer AW = 32
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,
    input  wire              in_valid,
    input  wire [N*DW-1:0]   a_col,     // A[i][k] in bits [i*DW +: DW]
    input  wire [N*DW-1:0]   b_row,     // B[k][j] in bits [j*DW +: DW]
    output wire [N*N*AW-1:0] c_flat     // C[i][j] in bits [(i*N+j)*AW +: AW]
);
    // Wires between PEs. Horizontal a/valid: (N rows) x (N+1 columns).
    // Vertical b: (N+1 rows) x (N columns).
    wire [DW-1:0] a_w [0:N-1][0:N];
    wire          v_w [0:N-1][0:N];
    wire [DW-1:0] b_w [0:N][0:N-1];

    genvar i, j;
    generate
        // ---- input skew: row i of A delayed i cycles (valid travels with it) ----
        for (i = 0; i < N; i = i + 1) begin : g_skew_a
            if (i == 0) begin : g_direct
                assign a_w[0][0] = a_col[0 +: DW];
                assign v_w[0][0] = in_valid;
            end else begin : g_delay
                reg [DW-1:0] sh_a [0:i-1];
                reg          sh_v [0:i-1];
                integer s;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (s = 0; s < i; s = s + 1) begin
                            sh_a[s] <= {DW{1'b0}};
                            sh_v[s] <= 1'b0;
                        end
                    end else begin
                        sh_a[0] <= a_col[i*DW +: DW];
                        sh_v[0] <= in_valid;
                        for (s = 1; s < i; s = s + 1) begin
                            sh_a[s] <= sh_a[s-1];
                            sh_v[s] <= sh_v[s-1];
                        end
                    end
                end
                assign a_w[i][0] = sh_a[i-1];
                assign v_w[i][0] = sh_v[i-1];
            end
        end

        // ---- input skew: column j of B delayed j cycles ----
        for (j = 0; j < N; j = j + 1) begin : g_skew_b
            if (j == 0) begin : g_direct
                assign b_w[0][0] = b_row[0 +: DW];
            end else begin : g_delay
                reg [DW-1:0] sh_b [0:j-1];
                integer s;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (s = 0; s < j; s = s + 1) sh_b[s] <= {DW{1'b0}};
                    end else begin
                        sh_b[0] <= b_row[j*DW +: DW];
                        for (s = 1; s < j; s = s + 1) sh_b[s] <= sh_b[s-1];
                    end
                end
                assign b_w[0][j] = sh_b[j-1];
            end
        end

        // ---- the PE grid ----
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                wire [AW-1:0] acc;
                pe #(.DW(DW), .AW(AW)) u_pe (
                    .clk(clk), .rst_n(rst_n), .clear(clear),
                    .valid_in(v_w[i][j]),
                    .a_in(a_w[i][j]),   .b_in(b_w[i][j]),
                    .valid_out(v_w[i][j+1]),
                    .a_out(a_w[i][j+1]), .b_out(b_w[i+1][j]),
                    .acc(acc)
                );
                assign c_flat[(i*N+j)*AW +: AW] = acc;
            end
        end
    endgenerate
endmodule

`default_nettype wire
