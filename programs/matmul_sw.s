# matmul_sw.s - C = A x B in software on the RISC-V core alone.
# Same memory layout as matmul_accel.s:
#   A[i][k] is the byte at 0x000 + 4k + i,   B[k][j] is the byte at 0x100 + 4k + j
#   C[i][j] goes to word 0x200 + 4(4i + j),  K is at 0x300
# RV32I has no multiply instruction, so products use shift-and-add
# (at most 8 iterations, since |b| <= 128).

        lw   s1, 0x300(zero)    # K
        li   s2, 0              # i
loop_i: li   s3, 0              # j
loop_j: li   s4, 0              # acc
        li   s5, 0              # k
loop_k: slli t0, s5, 2          # 4k
        add  t1, t0, s2
        lb   a0, 0(t1)          # A[i][k]
        add  t1, t0, s3
        lb   a1, 0x100(t1)      # B[k][j]

        # a2 = a0 * a1 (signed): make the multiplier non-negative first
        bgez a1, mul_pos
        neg  a1, a1
        neg  a0, a0
mul_pos: li  a2, 0
mul:    beqz a1, mul_done
        andi t2, a1, 1
        beqz t2, mul_skip
        add  a2, a2, a0
mul_skip: slli a0, a0, 1
        srli a1, a1, 1
        j    mul
mul_done:
        add  s4, s4, a2         # acc += A[i][k] * B[k][j]
        addi s5, s5, 1
        bne  s5, s1, loop_k

        slli t0, s2, 2          # store C[i][j] at 0x200 + 4*(4i + j)
        add  t0, t0, s3
        slli t0, t0, 2
        sw   s4, 0x200(t0)

        addi s3, s3, 1
        li   t3, 4
        bne  s3, t3, loop_j
        addi s2, s2, 1
        bne  s2, t3, loop_i

        ecall
