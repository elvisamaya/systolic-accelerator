// tb_pe.v - processing element: signed multiply-accumulate, clear, valid
// gating, and the one-cycle pass-through of a, b and valid to neighbours.
`timescale 1ns/1ps

module tb_pe;
    reg clk = 0, rst_n = 0, clear = 0, valid_in = 0;
    reg  signed [7:0]  a_in = 0, b_in = 0;
    wire signed [7:0]  a_out, b_out;
    wire               valid_out;
    wire signed [31:0] acc;

    pe dut (.clk(clk), .rst_n(rst_n), .clear(clear), .valid_in(valid_in),
            .a_in(a_in), .b_in(b_in), .valid_out(valid_out),
            .a_out(a_out), .b_out(b_out), .acc(acc));

    always #5 clk = ~clk;

    integer errors = 0, seed = 21, i, macs = 0;
    reg signed [31:0] model = 0;
    reg signed [7:0]  pa, pb;
    reg               pv;

    task check(input cond, input [8*48-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            if (errors < 10) $display("  ERROR @%0t: %0s (acc=%0d model=%0d)", $time, msg, acc, model);
        end
    endtask

    // drive at negedge, check at the next negedge (after the posedge update)
    task step(input c, input v, input signed [7:0] a, input signed [7:0] b);
        begin
            clear = c; valid_in = v; a_in = a; b_in = b;
            pa = a; pb = b; pv = v;
            @(negedge clk);
            if (c)      model = 0;
            else if (v) begin model = model + a * b; macs = macs + 1; end
            check(acc === model, "accumulator");
            check(a_out === pa && b_out === pb && valid_out === pv, "pass-through");
        end
    endtask

    initial begin
        $dumpfile("build/tb_pe.vcd");
        $dumpvars(0, tb_pe);
        repeat (2) @(negedge clk);
        rst_n = 1;

        // extremes: -128 * -128 = +16384 (largest product), -128 * 127, 127 * 127
        step(1, 0, 0, 0);
        step(0, 1, -128, -128);
        step(0, 1, -128, 127);
        step(0, 1, 127, 127);
        step(0, 1, -1, 1);
        step(0, 0, 100, 100);           // valid low: must NOT accumulate
        check(acc === 16384 - 16256 + 16129 - 1, "extreme products");

        // 64 x (-128 * -128): the largest sum a K=64 job can produce
        step(1, 0, 0, 0);
        for (i = 0; i < 64; i = i + 1) step(0, 1, -128, -128);
        check(acc === 64 * 16384, "max-magnitude accumulation");

        // random stream with random clears and bubbles
        for (i = 0; i < 20000; i = i + 1)
            step(({$random(seed)} % 100) == 0, $random(seed), $random(seed), $random(seed));

        $display("tb_pe: %0d multiply-accumulates checked, %0d errors", macs, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule
