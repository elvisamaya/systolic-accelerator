// accel_chip.v
// Top level for place-and-route: the accelerator with fixed parameters
// (4x4 array, K up to 16 to keep the buffers - and the run time - small).
`timescale 1ns/1ps
`default_nettype none

module accel_chip (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sel,
    input  wire        we,
    input  wire [11:0] addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        busy,
    output wire        done
);
    accel #(.N(4), .KMAX(16)) u_accel (
        .clk(clk), .rst_n(rst_n), .sel(sel), .we(we), .addr(addr),
        .wdata(wdata), .rdata(rdata), .busy(busy), .done(done)
    );
endmodule

`default_nettype wire
