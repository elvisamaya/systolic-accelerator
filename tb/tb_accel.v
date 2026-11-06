// tb_accel.v - the accelerator as software sees it: through its registers.
//   1. INFO register reports N and KMAX
//   2. A x I = A (identity), and buffer read-back
//   3. Every operand at -128 with K = KMAX (largest possible results)
//   4. 100 random jobs with random K, checked against a model
//   5. Writes are ignored while busy; K is clamped to 1..KMAX
//   6. The cycle counter matches K + 2N + 1 (clear + feed + drain)
// Compile with -DN=4 or -DN=8.
`timescale 1ns/1ps

`ifndef N
`define N 4
`endif

module tb_accel;
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

    integer errors = 0, seed = 5, i, j, k, K, job, polls;
    reg [31:0]        r;
    reg signed [7:0]  A [0:N-1][0:KMAX-1];
    reg signed [7:0]  B [0:KMAX-1][0:N-1];
    reg signed [31:0] C [0:N-1][0:N-1];

    // ---- bus helpers: one transaction per clock ----
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

    task fail(input [8*60-1:0] msg);
        begin
            errors = errors + 1;
            if (errors < 15) $display("  ERROR: %0s", msg);
        end
    endtask

    // pack and load A (column vectors) and B (row vectors), set K
    task load(input integer kk);
        integer kc, w, e;
        reg [31:0] word;
        begin
            for (kc = 0; kc < kk; kc = kc + 1)
                for (w = 0; w < WPV; w = w + 1) begin
                    for (e = 0; e < 4; e = e + 1) word[e*8 +: 8] = A[w*4 + e][kc];
                    bus_write(12'h400 + 4 * (kc * WPV + w), word);
                    for (e = 0; e < 4; e = e + 1) word[e*8 +: 8] = B[kc][w*4 + e];
                    bus_write(12'h800 + 4 * (kc * WPV + w), word);
                end
            bus_write(12'h008, kk);
        end
    endtask

    task run_and_check(input integer kk, input [8*24-1:0] name);
        integer ii, jj, kc, bad;
        begin
            for (ii = 0; ii < N; ii = ii + 1)
                for (jj = 0; jj < N; jj = jj + 1) begin
                    C[ii][jj] = 0;
                    for (kc = 0; kc < kk; kc = kc + 1) C[ii][jj] = C[ii][jj] + A[ii][kc] * B[kc][jj];
                end
            bus_write(12'h000, 1);                          // START
            polls = 0;
            r = 0;
            while (!r[1]) begin bus_read(12'h004, r); polls = polls + 1; end
            bad = 0;
            for (ii = 0; ii < N; ii = ii + 1)
                for (jj = 0; jj < N; jj = jj + 1) begin
                    bus_read(12'hC00 + 4 * (ii * N + jj), r);
                    if ($signed(r) !== C[ii][jj]) bad = bad + 1;
                end
            if (bad) begin
                errors = errors + 1;
                $display("  ERROR: %0s (K=%0d): %0d of %0d results wrong", name, kk, bad, N * N);
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_accel.vcd");
        $dumpvars(0, tb_accel);
        repeat (2) @(negedge clk);
        rst_n = 1;

        // 1. INFO
        bus_read(12'h010, r);
        if (r !== {KMAX[15:0], N[15:0]}) fail("INFO register");

        // 2. identity: A x I = A, plus buffer read-back
        K = N;
        for (i = 0; i < N; i = i + 1)
            for (k = 0; k < K; k = k + 1) begin
                A[i][k] = i * 16 + k - 40;
                B[k][i] = (k == i) ? 1 : 0;
            end
        load(K);
        bus_read(12'h400, r);
        if (r[7:0] !== A[0][0] || r[15:8] !== A[1][0]) fail("A buffer read-back");
        run_and_check(K, "identity");

        // 3. extremes at K = KMAX: every product is (-128)*(-128) = 16384
        K = KMAX;
        for (i = 0; i < N; i = i + 1)
            for (k = 0; k < K; k = k + 1) begin A[i][k] = -128; B[k][i] = -128; end
        load(K);
        run_and_check(K, "all -128, K=KMAX");

        // 4. random jobs
        for (job = 0; job < 100; job = job + 1) begin
            K = 1 + {$random(seed)} % KMAX;
            for (i = 0; i < N; i = i + 1)
                for (k = 0; k < K; k = k + 1) begin A[i][k] = $random(seed); B[k][i] = $random(seed); end
            load(K);
            run_and_check(K, "random");
        end

        // 5a. writes while busy are ignored (start a K=KMAX job, then try to change K and A)
        bus_write(12'h008, KMAX);
        bus_write(12'h000, 1);
        bus_read(12'h004, r);
        if (!r[0]) fail("STATUS.busy not set after START");
        bus_write(12'h008, 3);
        bus_write(12'h400, 32'hFFFF_FFFF);
        while (!r[1]) bus_read(12'h004, r);
        bus_read(12'h008, r);
        if (r !== KMAX) fail("K changed while busy");
        bus_read(12'h400, r);
        if (r === 32'hFFFF_FFFF) fail("A buffer written while busy");

        // 5b. K clamping
        bus_write(12'h008, 0);        bus_read(12'h008, r); if (r !== 1)    fail("K=0 not clamped to 1");
        bus_write(12'h008, KMAX + 9); bus_read(12'h008, r); if (r !== KMAX) fail("K>KMAX not clamped");

        // 6. performance counter: 1 clear cycle + K feed cycles + (2N-2) drain cycles, +1 start
        bus_write(12'h008, 10);
        bus_write(12'h000, 1);
        r = 0; while (!r[1]) bus_read(12'h004, r);
        bus_read(12'h00C, r);
        if (r !== 10 + 2 * N) begin
            errors = errors + 1;
            $display("  ERROR: CYCLES = %0d, expected %0d", r, 10 + 2 * N);
        end

        $display("tb_accel (N=%0d): 102 matrix jobs + register checks, %0d errors", N, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule
