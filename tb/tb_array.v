// tb_array.v - systolic array: random matrix products of random inner
// dimension K, checked against a straightforward triple-loop model.
// Results are checked exactly DRAIN = 2N-2 cycles after the last input,
// the moment the far-corner PE finishes.
// Compile with -DN=2|4|8 to test different array sizes.
`timescale 1ns/1ps

`ifndef N
`define N 4
`endif

module tb_array;
    localparam integer N = `N;
    localparam integer KMAX = 32;
    localparam integer JOBS = 200;

    reg clk = 0, rst_n = 0, clear = 0, in_valid = 0;
    reg  [N*8-1:0]    a_col = 0, b_row = 0;
    wire [N*N*32-1:0] c_flat;

    systolic_array #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear), .in_valid(in_valid),
        .a_col(a_col), .b_row(b_row), .c_flat(c_flat)
    );

    always #5 clk = ~clk;

    reg signed [7:0]  A [0:N-1][0:KMAX-1];
    reg signed [7:0]  B [0:KMAX-1][0:N-1];
    reg signed [31:0] C [0:N-1][0:N-1];
    integer errors = 0, seed = 7, job, i, j, k, K, ndiff_job;

    task compare(output integer ndiff);
        begin
            ndiff = 0;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    if ($signed(c_flat[(i*N+j)*32 +: 32]) !== C[i][j]) ndiff = ndiff + 1;
        end
    endtask

    initial begin
        $dumpfile("build/tb_array.vcd");
        $dumpvars(0, tb_array);
        repeat (2) @(negedge clk);
        rst_n = 1;

        for (job = 0; job < JOBS; job = job + 1) begin
            // random operands; every 10th job uses only the extreme values
            K = 1 + {$random(seed)} % KMAX;
            for (i = 0; i < N; i = i + 1)
                for (k = 0; k < K; k = k + 1) begin
                    A[i][k] = (job % 10 == 3) ? ($random(seed) & 1 ? -128 : 127) : $random(seed);
                    B[k][i] = (job % 10 == 3) ? ($random(seed) & 1 ? -128 : 127) : $random(seed);
                end
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    C[i][j] = 0;
                    for (k = 0; k < K; k = k + 1) C[i][j] = C[i][j] + A[i][k] * B[k][j];
                end

            // clear, then feed one column of A and one row of B per cycle
            @(negedge clk) clear = 1;
            @(negedge clk) clear = 0;
            for (k = 0; k < K; k = k + 1) begin
                for (i = 0; i < N; i = i + 1) begin
                    a_col[i*8 +: 8] = A[i][k];
                    b_row[i*8 +: 8] = B[k][i];
                end
                in_valid = 1;
                @(negedge clk);
            end
            in_valid = 0; a_col = 0; b_row = 0;

            // results must be complete exactly 2N-2 cycles after the last input
            repeat (2 * N - 2) @(negedge clk);
            compare(ndiff_job);
            if (ndiff_job != 0) begin
                errors = errors + 1;
                $display("  ERROR: job %0d (K=%0d): %0d of %0d results wrong", job, K, ndiff_job, N * N);
            end
        end

        $display("tb_array (N=%0d): %0d jobs, %0d errors", N, JOBS, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule
