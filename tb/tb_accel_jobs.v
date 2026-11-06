// tb_accel_jobs.v - runs a file of matrix jobs through the accelerator's
// bus interface and writes every result to a file. Python generates the jobs
// and checks the results (scripts/accel_model.py), so this testbench has no
// built-in expectations - it is the "hardware in the loop".
//
//   vvp build/tb_accel_jobs_n4.vvp +jobs=build/x.jobs +results=build/x.results
`timescale 1ns/1ps

`ifndef N
`define N 4
`endif

module tb_accel_jobs;
    localparam integer N    = `N;
    localparam integer KMAX = 64;
    localparam integer WPV  = N / 4;

    reg         clk = 0, rst_n = 0, sel = 0, we = 0;
    reg  [11:0] addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        busy, done;

    accel #(.N(N), .KMAX(KMAX)) dut (
        .clk(clk), .rst_n(rst_n), .sel(sel), .we(we), .addr(addr),
        .wdata(wdata), .rdata(rdata), .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    task bus_write(input [11:0] a, input [31:0] d);
        begin
            @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
            @(negedge clk); sel = 0; we = 0;
        end
    endtask
    task bus_read(input [11:0] a, output [31:0] d);
        begin
            @(negedge clk); sel = 1; we = 0; addr = a; #1 d = rdata;
            @(negedge clk); sel = 0;
        end
    endtask

    reg [8*256-1:0] jobs_path, results_path;
    integer fin, fout, njobs, job, K, n, i, code;
    reg [31:0] word, r;

    initial begin
        if (!$value$plusargs("jobs=%s", jobs_path) || !$value$plusargs("results=%s", results_path)) begin
            $display("usage: vvp tb_accel_jobs.vvp +jobs=<file> +results=<file>");
            $finish;
        end
        fin  = $fopen(jobs_path, "r");
        fout = $fopen(results_path, "w");
        if (fin == 0 || fout == 0) begin
            $display("ERROR: cannot open job/result files");
            $finish;
        end

        repeat (2) @(negedge clk);
        rst_n = 1;

        code = $fscanf(fin, "%h\n", njobs);
        for (job = 0; job < njobs; job = job + 1) begin
            code = $fscanf(fin, "%h\n", K);
            for (n = 0; n < K * WPV; n = n + 1) begin
                code = $fscanf(fin, "%h\n", word);
                bus_write(12'h400 + 4 * n, word);
            end
            for (n = 0; n < K * WPV; n = n + 1) begin
                code = $fscanf(fin, "%h\n", word);
                bus_write(12'h800 + 4 * n, word);
            end
            bus_write(12'h008, K);
            bus_write(12'h000, 1);
            r = 0;
            while (!r[1]) bus_read(12'h004, r);
            for (i = 0; i < N * N; i = i + 1) begin
                bus_read(12'hC00 + 4 * i, r);
                $fwrite(fout, "%h\n", r);
            end
            bus_read(12'h00C, r);
            $fwrite(fout, "%h\n", r);
        end
        $fclose(fin);
        $fclose(fout);
        $display("tb_accel_jobs (N=%0d): ran %0d jobs", N, njobs);
        $finish;
    end
endmodule
