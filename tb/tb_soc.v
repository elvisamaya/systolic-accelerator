// tb_soc.v - run a program on the SoC and check the matrix it leaves in RAM.
//
//   vvp build/tb_soc.vvp +prog=build/matmul_accel.hex +data=build/matmul
//
// loads the program into instruction memory and <data>.dmem into data RAM,
// runs until ECALL, then compares RAM words 0x200..0x23C (C) with
// <data>.expect from the NumPy golden model.
`timescale 1ns/1ps

module tb_soc;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire        halted, illegal_seen;
    wire [31:0] cycles, instret;

    soc dut (.clk(clk), .rst_n(rst_n), .halted(halted), .illegal_seen(illegal_seen),
             .cycles(cycles), .instret(instret));

    reg [8*200-1:0] prog, data;
    reg [31:0] expected [0:15];
    integer i, errors = 0;

    initial begin
        if (!$value$plusargs("prog=%s", prog) || !$value$plusargs("data=%s", data)) begin
            $display("usage: vvp tb_soc.vvp +prog=<hex> +data=<prefix>");
            $finish;
        end
        for (i = 0; i < 1024; i = i + 1) dut.u_cpu.u_imem.mem[i] = 32'h0000_0013;
        $readmemh(prog, dut.u_cpu.u_imem.mem);
        $readmemh({data, ".dmem"}, dut.u_dmem.mem);
        $readmemh({data, ".expect"}, expected);
        if ($test$plusargs("vcd")) begin
            $dumpfile("build/tb_soc.vcd");
            $dumpvars(0, tb_soc);
        end

        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1;
        while (!halted && cycles < 500000) @(posedge clk);
        @(negedge clk);

        if (!halted)      begin errors = errors + 1; $display("  ERROR: program did not finish"); end
        if (illegal_seen) begin errors = errors + 1; $display("  ERROR: illegal instruction"); end
        for (i = 0; i < 16; i = i + 1)
            if (dut.u_dmem.mem[128 + i] !== expected[i]) begin
                errors = errors + 1;
                $display("  ERROR: C[%0d][%0d] = %0d, expected %0d", i / 4, i % 4,
                         $signed(dut.u_dmem.mem[128 + i]), $signed(expected[i]));
            end

        $display("RESULT %0s cycles=%0d instret=%0d errors=%0d", prog, cycles, instret, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule
