// soc.v
// A small system-on-chip: the RISC-V CPU, 4 KiB of data RAM, and the
// matrix-multiply accelerator, connected by a memory-mapped data bus.
//
//   address map
//     0x0000_0000 - 0x0000_0FFF   data RAM (wraps every 4 KiB)
//     0x4000_0000 - 0x4000_0FFF   accelerator registers and buffers
//
// The CPU talks to the accelerator with ordinary lw/sw instructions; nothing
// in the CPU knows the accelerator exists. That is what "memory-mapped I/O" means.
`timescale 1ns/1ps
`default_nettype none

module soc #(
    parameter integer N    = 4,
    parameter integer KMAX = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        halted,
    output wire        illegal_seen,
    output wire [31:0] cycles,
    output wire [31:0] instret
);
    wire [31:0] dbus_addr, dbus_wdata, dbus_rdata;
    wire [3:0]  dbus_be;
    wire        dbus_we;

    cpu_pipe #(.FORWARDING(1)) u_cpu (
        .clk(clk), .rst_n(rst_n), .halted(halted), .illegal_seen(illegal_seen),
        .cycles(cycles), .instret(instret),
        .dbus_addr(dbus_addr), .dbus_wdata(dbus_wdata), .dbus_be(dbus_be),
        .dbus_we(dbus_we), .dbus_rdata(dbus_rdata)
    );

    // ---- address decode ----
    wire accel_sel = (dbus_addr[31:28] == 4'h4);

    wire [31:0] ram_rdata;
    dmem u_dmem (
        .clk(clk), .we(dbus_we && !accel_sel), .be(dbus_be),
        .addr(dbus_addr), .wdata(dbus_wdata), .rdata(ram_rdata)
    );

    wire [31:0] acc_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        acc_busy, acc_done;     // status is also readable over the bus
    /* verilator lint_on UNUSEDSIGNAL */
    accel #(.N(N), .KMAX(KMAX)) u_accel (
        .clk(clk), .rst_n(rst_n),
        .sel(accel_sel), .we(dbus_we), .addr(dbus_addr[11:0]), .wdata(dbus_wdata),
        .rdata(acc_rdata), .busy(acc_busy), .done(acc_done)
    );

    assign dbus_rdata = accel_sel ? acc_rdata : ram_rdata;
endmodule

`default_nettype wire
