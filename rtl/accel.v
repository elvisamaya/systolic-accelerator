// accel.v
// Memory-mapped matrix-multiply accelerator:  C (N x N, int32) = A (N x K, int8) * B (K x N, int8)
//
// Software writes A and B into on-chip buffers over a simple 32-bit bus,
// writes K, sets START, polls STATUS until DONE, then reads C.
//
// Register map (byte offsets within the accelerator's 4 KiB window)
//   0x000  CTRL     W   bit0 = start (self-clearing)
//   0x004  STATUS   R   bit0 = busy, bit1 = done (cleared by the next start)
//   0x008  K        RW  inner dimension, 1..KMAX
//   0x00C  CYCLES   R   clock cycles taken by the last job (performance counter)
//   0x010  INFO     R   {16'(KMAX), 16'(N)}  so software can discover the size
//   0x400  A buffer RW  column k of A = A[0..N-1][k], packed 4 int8 per word,
//                       A[i][k] at byte i;   word index = k*(N/4) + i/4
//   0x800  B buffer RW  row k of B = B[k][0..N-1], same packing (B[k][j] at byte j)
//   0xC00  C        R   C[i][j] as int32 at word index i*N + j
//
// Storing A column-by-column means one buffer read per cycle feeds the whole
// left edge of the array - the data layout is chosen to suit the hardware.
`timescale 1ns/1ps
`default_nettype none

module accel #(
    parameter integer N    = 4,     // array size (multiple of 4)
    parameter integer KMAX = 64     // max inner dimension
) (
    input  wire        clk,
    input  wire        rst_n,
    // bus (single-cycle; reads are combinational)
    input  wire        sel,
    input  wire        we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [11:0] addr,        // byte address; bits [1:0] ignored (word access only)
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        busy,
    output reg         done
);
    localparam integer DW    = 8;
    localparam integer AW    = 32;
    localparam integer WPV   = N / 4;               // 32-bit words per N-element vector
    localparam integer BUFW  = KMAX * WPV;          // words per buffer
    localparam integer KW    = $clog2(KMAX + 1);
    localparam integer DRAIN = 2 * N - 2;           // cycles after the last input
    localparam integer DCW   = $clog2(DRAIN + 1);
    localparam integer BIW   = $clog2(BUFW);             // buffer index width

    // ---------------------------------------------------------------- buffers
    reg [31:0] abuf [0:BUFW-1];
    reg [31:0] bbuf [0:BUFW-1];

    // ---------------------------------------------------------------- control
    localparam [1:0] S_IDLE = 2'd0, S_FEED = 2'd1, S_DRAIN = 2'd2;
    reg [1:0]     state;
    reg [KW-1:0]  kreg;           // programmed K
    reg [KW-1:0]  kcnt;           // current column/row being fed
    reg [DCW-1:0] dcnt;
    reg [31:0]    cycles;
    reg           clear;

    assign busy = (state != S_IDLE) || clear;

    wire [7:0] widx   = addr[9:2];                      // word index inside a 1 KiB region
    wire [1:0] region = addr[11:10];                    // 0 regs, 1 A, 2 B, 3 C
    wire       wr     = sel && we;

    // which buffer word / result an address selects, and whether it exists
    localparam [8:0] BUFW_9 = BUFW[8:0];
    localparam integer NN     = N * N;
    localparam [8:0] NN_9   = NN[8:0];
    wire [BIW-1:0] bidx   = widx[BIW-1:0];
    wire           in_buf = ({1'b0, widx} < BUFW_9);
    wire           in_c   = ({1'b0, widx} < NN_9);
    wire       start  = wr && region == 2'd0 && widx == 8'd0 && wdata[0] && !busy;

    // ---------------------------------------------------------------- array
    reg  [N*DW-1:0]   a_col, b_row;
    wire [N*N*AW-1:0] c_flat;
    wire              feeding = (state == S_FEED);

    integer w;
    always @(*) begin
        for (w = 0; w < WPV; w = w + 1) begin
            a_col[w*32 +: 32] = abuf[kcnt * WPV + w];
            b_row[w*32 +: 32] = bbuf[kcnt * WPV + w];
        end
    end

    systolic_array #(.N(N), .DW(DW), .AW(AW)) u_array (
        .clk(clk), .rst_n(rst_n), .clear(clear), .in_valid(feeding),
        .a_col(a_col), .b_row(b_row), .c_flat(c_flat)
    );

    // ---------------------------------------------------------------- FSM
    localparam [KW-1:0]  KMAX_K = KMAX[KW-1:0];
    localparam [DCW-1:0] DRAIN_C = DRAIN[DCW-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            kreg   <= {{(KW-1){1'b0}}, 1'b1};
            kcnt   <= {KW{1'b0}};
            dcnt   <= {DCW{1'b0}};
            cycles <= 32'd0;
            clear  <= 1'b0;
            done   <= 1'b0;
        end else begin
            clear <= 1'b0;
            if (state != S_IDLE || clear) cycles <= cycles + 32'd1;

            // K register (ignored while busy); clamp to 1..KMAX
            if (wr && region == 2'd0 && widx == 8'd2 && !busy) begin
                if (wdata == 32'd0)              kreg <= {{(KW-1){1'b0}}, 1'b1};
                else if (wdata > KMAX)           kreg <= KMAX_K;
                else                             kreg <= wdata[KW-1:0];
            end

            case (state)
                S_IDLE: begin
                    if (start) begin
                        clear  <= 1'b1;             // zero accumulators this cycle
                        done   <= 1'b0;
                        cycles <= 32'd1;
                        kcnt   <= {KW{1'b0}};
                    end else if (clear) begin
                        state <= S_FEED;            // accumulators are now zero
                    end
                end
                S_FEED: begin                       // one column of A + row of B per cycle
                    if (kcnt == kreg - 1'b1) begin
                        state <= (DRAIN == 0) ? S_IDLE : S_DRAIN;
                        done  <= (DRAIN == 0);
                        dcnt  <= {DCW{1'b0}};
                    end else begin
                        kcnt <= kcnt + 1'b1;
                    end
                end
                S_DRAIN: begin                      // let the last inputs reach PE(N-1,N-1)
                    if (dcnt == DRAIN_C - 1'b1) begin
                        state <= S_IDLE;
                        done  <= 1'b1;
                    end else begin
                        dcnt <= dcnt + 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- buffer writes
    always @(posedge clk) begin
        if (wr && !busy && in_buf) begin
            if (region == 2'd1) abuf[bidx] <= wdata;
            if (region == 2'd2) bbuf[bidx] <= wdata;
        end
    end

    // ---------------------------------------------------------------- bus reads
    always @(*) begin
        rdata = 32'd0;
        case (region)
            2'd0: case (widx)
                      8'd1:    rdata = {30'd0, done, busy};
                      8'd2:    rdata = {{(32-KW){1'b0}}, kreg};
                      8'd3:    rdata = cycles;
                      8'd4:    rdata = {KMAX[15:0], N[15:0]};
                      default: rdata = 32'd0;
                  endcase
            2'd1:    rdata = in_buf ? abuf[bidx] : 32'd0;
            2'd2:    rdata = in_buf ? bbuf[bidx] : 32'd0;
            default: rdata = in_c   ? c_flat[widx * AW +: AW] : 32'd0;
        endcase
    end
endmodule

`default_nettype wire
