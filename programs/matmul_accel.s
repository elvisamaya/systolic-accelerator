# matmul_accel.s - C = A x B using the accelerator.
#
# Memory layout (prepared by scripts/soc_data.py):
#   0x000  A, column by column: word k = {A[3][k], A[2][k], A[1][k], A[0][k]}
#   0x100  B, row by row:       word k = {B[k][3], B[k][2], B[k][1], B[k][0]}
#   0x200  C, 16 int32 words, row-major (written by this program)
#   0x300  K
# A is stored transposed on purpose: one 32-bit word is then exactly one
# column of A, which is what the accelerator consumes each cycle.

        li   s0, 0x40000000     # accelerator base address
        li   t0, 0x400
        add  s3, s0, t0         # A buffer
        li   t0, 0x800
        add  s4, s0, t0         # B buffer
        li   t0, 0xC00
        add  s5, s0, t0         # C results

        lw   s1, 0x300(zero)    # K
        slli s2, s1, 2          # bytes per matrix = 4 * K

        # copy A and B into the accelerator (one word = one column / row)
        li   t0, 0
copy:   lw   t1, 0(t0)
        add  t2, s3, t0
        sw   t1, 0(t2)
        lw   t1, 0x100(t0)
        add  t2, s4, t0
        sw   t1, 0(t2)
        addi t0, t0, 4
        bne  t0, s2, copy

        sw   s1, 8(s0)          # K
        li   t1, 1
        sw   t1, 0(s0)          # START

wait:   lw   t1, 4(s0)          # STATUS
        andi t1, t1, 2          # done bit
        beqz t1, wait

        # read the 16 results back into RAM
        li   t0, 0
        li   t3, 64
rd:     add  t2, s5, t0
        lw   t1, 0(t2)
        sw   t1, 0x200(t0)
        addi t0, t0, 4
        bne  t0, t3, rd

        lw   a0, 12(s0)         # accelerator's own cycle count
        ecall
