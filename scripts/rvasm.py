#!/usr/bin/env python3
"""rvasm.py - a small two-pass RV32I assembler.

Turns a .s file into a hex file (one 32-bit word per line) that Verilog's
$readmemh can load straight into instruction memory.

    python3 scripts/rvasm.py programs/fib.s -o build/fib.hex

Supports every RV32I base instruction, labels, '#' comments, ABI register
names (zero, ra, sp, a0, t1, s2, ...) and common pseudo-instructions:
nop, li, mv, not, neg, seqz, snez, j, jr, ret, call, beqz, bnez, bltz, bgez,
blez, bgtz, bgt, ble, bgtu, bleu.
"""
import argparse
import re
import sys

ABI = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14,
    "a5": 15, "a6": 16, "a7": 17, "s2": 18, "s3": 19, "s4": 20, "s5": 21,
    "s6": 22, "s7": 23, "s8": 24, "s9": 25, "s10": 26, "s11": 27, "t3": 28,
    "t4": 29, "t5": 30, "t6": 31,
}

# name: (format, opcode, funct3, funct7)
OPS = {
    "lui":   ("U", 0b0110111, None, None),
    "auipc": ("U", 0b0010111, None, None),
    "jal":   ("J", 0b1101111, None, None),
    "jalr":  ("I", 0b1100111, 0b000, None),
    "beq":   ("B", 0b1100011, 0b000, None), "bne":  ("B", 0b1100011, 0b001, None),
    "blt":   ("B", 0b1100011, 0b100, None), "bge":  ("B", 0b1100011, 0b101, None),
    "bltu":  ("B", 0b1100011, 0b110, None), "bgeu": ("B", 0b1100011, 0b111, None),
    "lb":    ("L", 0b0000011, 0b000, None), "lh":   ("L", 0b0000011, 0b001, None),
    "lw":    ("L", 0b0000011, 0b010, None), "lbu":  ("L", 0b0000011, 0b100, None),
    "lhu":   ("L", 0b0000011, 0b101, None),
    "sb":    ("S", 0b0100011, 0b000, None), "sh":   ("S", 0b0100011, 0b001, None),
    "sw":    ("S", 0b0100011, 0b010, None),
    "addi":  ("I", 0b0010011, 0b000, None), "slti": ("I", 0b0010011, 0b010, None),
    "sltiu": ("I", 0b0010011, 0b011, None), "xori": ("I", 0b0010011, 0b100, None),
    "ori":   ("I", 0b0010011, 0b110, None), "andi": ("I", 0b0010011, 0b111, None),
    "slli":  ("SH", 0b0010011, 0b001, 0b0000000),
    "srli":  ("SH", 0b0010011, 0b101, 0b0000000),
    "srai":  ("SH", 0b0010011, 0b101, 0b0100000),
    "add":   ("R", 0b0110011, 0b000, 0b0000000), "sub":  ("R", 0b0110011, 0b000, 0b0100000),
    "sll":   ("R", 0b0110011, 0b001, 0b0000000), "slt":  ("R", 0b0110011, 0b010, 0b0000000),
    "sltu":  ("R", 0b0110011, 0b011, 0b0000000), "xor":  ("R", 0b0110011, 0b100, 0b0000000),
    "srl":   ("R", 0b0110011, 0b101, 0b0000000), "sra":  ("R", 0b0110011, 0b101, 0b0100000),
    "or":    ("R", 0b0110011, 0b110, 0b0000000), "and":  ("R", 0b0110011, 0b111, 0b0000000),
    "ecall": ("SYS", 0x00000073, None, None),
    "ebreak": ("SYS", 0x00100073, None, None),
    "fence": ("SYS", 0x0FF0000F, None, None),
}


class AsmError(Exception):
    pass


def reg(tok):
    tok = tok.strip().lower()
    if tok in ABI:
        return ABI[tok]
    m = re.fullmatch(r"x(\d+)", tok)
    if m and int(m.group(1)) < 32:
        return int(m.group(1))
    raise AsmError(f"bad register '{tok}'")


def num(tok):
    try:
        return int(tok.strip(), 0)
    except ValueError:
        raise AsmError(f"bad number '{tok}'")


def check_range(val, bits, signed=True, what="immediate"):
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    if not lo <= val <= hi:
        raise AsmError(f"{what} {val} out of range [{lo}, {hi}]")


def split_li(value):
    """Split a 32-bit constant into (upper20, lower12) for lui + addi."""
    value &= 0xFFFFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000                    # addi sign-extends its immediate
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


def expand(mn, args):
    """Expand pseudo-instructions into (mnemonic, args) base instructions."""
    a = args
    if mn == "nop":   return [("addi", ["x0", "x0", "0"])]
    if mn == "mv":    return [("addi", [a[0], a[1], "0"])]
    if mn == "not":   return [("xori", [a[0], a[1], "-1"])]
    if mn == "neg":   return [("sub", [a[0], "x0", a[1]])]
    if mn == "seqz":  return [("sltiu", [a[0], a[1], "1"])]
    if mn == "snez":  return [("sltu", [a[0], "x0", a[1]])]
    if mn == "j":     return [("jal", ["x0", a[0]])]
    if mn == "jr":    return [("jalr", ["x0", a[0], "0"])]
    if mn == "ret":   return [("jalr", ["x0", "ra", "0"])]
    if mn == "call":  return [("jal", ["ra", a[0]])]
    if mn == "jal" and len(a) == 1:  return [("jal", ["ra", a[0]])]
    if mn == "beqz":  return [("beq", [a[0], "x0", a[1]])]
    if mn == "bnez":  return [("bne", [a[0], "x0", a[1]])]
    if mn == "bltz":  return [("blt", [a[0], "x0", a[1]])]
    if mn == "bgez":  return [("bge", [a[0], "x0", a[1]])]
    if mn == "blez":  return [("bge", ["x0", a[0], a[1]])]
    if mn == "bgtz":  return [("blt", ["x0", a[0], a[1]])]
    if mn == "bgt":   return [("blt", [a[1], a[0], a[2]])]
    if mn == "ble":   return [("bge", [a[1], a[0], a[2]])]
    if mn == "bgtu":  return [("bltu", [a[1], a[0], a[2]])]
    if mn == "bleu":  return [("bgeu", [a[1], a[0], a[2]])]
    if mn == "li":
        value = num(a[1])
        if -2048 <= value <= 2047:
            return [("addi", [a[0], "x0", str(value)])]
        hi, lo = split_li(value)
        out = [("lui", [a[0], str(hi)])]
        if lo:
            out.append(("addi", [a[0], a[0], str(lo)]))
        return out
    return [(mn, a)]


def encode(mn, args, pc, labels):
    if mn not in OPS:
        raise AsmError(f"unknown instruction '{mn}'")
    fmt, opc, f3, f7 = OPS[mn]

    def target(tok):
        tok = tok.strip()
        if tok in labels:
            return labels[tok] - pc
        return num(tok)                 # numeric byte offset

    def mem_operand(tok):               # "imm(rs1)"
        m = re.fullmatch(r"\s*(-?\w*)\s*\(\s*(\w+)\s*\)\s*", tok)
        if not m:
            raise AsmError(f"expected offset(reg), got '{tok}'")
        return num(m.group(1) or "0"), reg(m.group(2))

    if fmt == "SYS":
        return opc
    if fmt == "R":
        rd, rs1, rs2 = (reg(x) for x in args)
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    if fmt == "I":
        if mn == "jalr" and len(args) == 2:         # jalr rd, imm(rs1)
            rd = reg(args[0]); imm, rs1 = mem_operand(args[1])
        elif mn == "jalr" and len(args) == 1:       # jalr rs1
            rd, rs1, imm = 1, reg(args[0]), 0
        else:
            rd, rs1, imm = reg(args[0]), reg(args[1]), num(args[2])
        check_range(imm, 12)
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    if fmt == "SH":
        rd, rs1, sh = reg(args[0]), reg(args[1]), num(args[2])
        check_range(sh, 5, signed=False, what="shift amount")
        return (f7 << 25) | (sh << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    if fmt == "L":
        rd = reg(args[0]); imm, rs1 = mem_operand(args[1])
        check_range(imm, 12)
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
    if fmt == "S":
        rs2 = reg(args[0]); imm, rs1 = mem_operand(args[1])
        check_range(imm, 12)
        imm &= 0xFFF
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | opc
    if fmt == "B":
        rs1, rs2 = reg(args[0]), reg(args[1])
        off = target(args[2])
        check_range(off, 13, what="branch offset")
        if off % 2:
            raise AsmError("branch offset must be even")
        o = off & 0x1FFF
        return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
               (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | opc
    if fmt == "U":
        rd, imm = reg(args[0]), num(args[1])
        check_range(imm, 20, signed=False, what="upper immediate")
        return (imm << 12) | (rd << 7) | opc
    if fmt == "J":
        rd = reg(args[0])
        off = target(args[1])
        check_range(off, 21, what="jump offset")
        o = off & 0x1FFFFF
        return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | \
               (((o >> 12) & 0xFF) << 12) | (rd << 7) | opc
    raise AsmError(f"unhandled format {fmt}")


def assemble(text):
    # pass 1: strip comments, collect labels, expand pseudo-instructions
    labels, items, pc = {}, [], 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#")[0].strip()
        while ":" in line:
            label, line = line.split(":", 1)
            label = label.strip()
            if label in labels:
                raise AsmError(f"line {lineno}: duplicate label '{label}'")
            labels[label] = pc
            line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mn = parts[0].lower()
        args = [x.strip() for x in parts[1].split(",")] if len(parts) > 1 else []
        try:
            for emn, eargs in expand(mn, args):
                items.append((pc, emn, eargs, lineno, raw.strip()))
                pc += 4
        except (AsmError, IndexError) as e:
            raise AsmError(f"line {lineno}: {e or 'missing operand'}: {raw.strip()}")

    # pass 2: encode with all labels known
    words = []
    for pc, mn, args, lineno, src in items:
        try:
            words.append((pc, encode(mn, args, pc, labels), src))
        except (AsmError, IndexError) as e:
            raise AsmError(f"line {lineno}: {e or 'missing operand'}: {src}")
    return words


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("-l", "--listing", action="store_true", help="print an address/hex/source listing")
    ap.add_argument("--pad", type=int, default=1024,
                    help="pad with NOPs to this many words (size of instruction memory)")
    a = ap.parse_args()

    try:
        words = assemble(open(a.source).read())
    except AsmError as e:
        sys.exit(f"{a.source}: {e}")

    if len(words) > a.pad:
        sys.exit(f"{a.source}: program is {len(words)} words, instruction memory holds {a.pad}")
    with open(a.output, "w") as f:
        for _, w, _ in words:
            f.write(f"{w:08x}\n")
        f.write("00000013\n" * (a.pad - len(words)))    # NOP padding
    if a.listing:
        for pc, w, src in words:
            print(f"{pc:04x}: {w:08x}   {src}")


if __name__ == "__main__":
    main()
