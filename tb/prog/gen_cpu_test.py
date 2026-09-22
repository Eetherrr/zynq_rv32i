#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cpu_test.py — 生成 tb_top 使用的 RV32I 测试程序镜像

输出（默认写到本文件所在目录）：
    cpu_test.hex    带注释的机器码清单（tb_top 读它做参考 / 打印）
    cpu_test.coe    ROM IP 的初始化文件（16 进制、8 位宽）
    ROM.mif         ROM IP 仿真模型用的初始化文件（每行 32 bit 二进制）

用法：
    python3 tb/prog/gen_cpu_test.py            # 生成 hex / coe / mif
    python3 tb/prog/gen_cpu_test.py --check    # 只做往返解码自检

地址映射（见 rtl/sys_define.svh）：
    RAM    0x1000_0000   RESULT 在 0x1000_0000，半字测试在 0x1000_0300
    TIMER  0x2000_0000   LOAD +0 / COUNT +4 / CTRL +8 / STATUS +0x0C
    SPI    0x2000_0400
    UART   0x2000_0800   TXDATA +0 / RXDATA +4 / STATUS +8 / BAUD +0x0C
    GPIO   0x2000_0C00   DATA +0 / DIR +4 / SET +8 / CLR +0x0C

结束：RESULT=1 通过 / RESULT=0 失败，随后停在 0x138 的 `jal x0,0`。
"""

import argparse
import struct
from pathlib import Path

WORDS = 4096


# ----------------------------------------------------------------------
# 指令编码
# ----------------------------------------------------------------------
def r_type(f7, rs2, rs1, f3, rd):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0b0110011


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((imm & 0x1F) << 7) | 0b0100011


def b_type(imm, rs2, rs1, f3):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0b1100011


def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def j_type(imm, rd):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0b1101111


# 便捷助记符
def addi(rd, rs1, imm):   return i_type(imm, rs1, 0b000, rd, 0b0010011)
def andi(rd, rs1, imm):   return i_type(imm, rs1, 0b111, rd, 0b0010011)
def lw(rd, imm, rs1):     return i_type(imm, rs1, 0b010, rd, 0b0000011)
def lbu(rd, imm, rs1):    return i_type(imm, rs1, 0b100, rd, 0b0000011)
def lhu(rd, imm, rs1):    return i_type(imm, rs1, 0b101, rd, 0b0000011)
def sw(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b010)
def sb(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b000)
def sh(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b001)
def beq(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b000)
def bne(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b001)
def add(rd, rs1, rs2):    return r_type(0x00, rs2, rs1, 0b000, rd)
def sub(rd, rs1, rs2):    return r_type(0x20, rs2, rs1, 0b000, rd)
def sll(rd, rs1, rs2):    return r_type(0x00, rs2, rs1, 0b001, rd)
def slt(rd, rs1, rs2):    return r_type(0x00, rs2, rs1, 0b010, rd)
def sltu(rd, rs1, rs2):   return r_type(0x00, rs2, rs1, 0b011, rd)
def xor_(rd, rs1, rs2):   return r_type(0x00, rs2, rs1, 0b100, rd)
def srl(rd, rs1, rs2):    return r_type(0x00, rs2, rs1, 0b101, rd)
def sra(rd, rs1, rs2):    return r_type(0x20, rs2, rs1, 0b101, rd)
def or_(rd, rs1, rs2):    return r_type(0x00, rs2, rs1, 0b110, rd)
def and_(rd, rs1, rs2):   return r_type(0x00, rs2, rs1, 0b111, rd)
def lui(rd, imm20):       return u_type(imm20, rd, 0b0110111)
def jal(rd, imm):         return j_type(imm, rd)
def nop():                return addi(0, 0, 0)


# ----------------------------------------------------------------------
# 程序：返回 [(字节地址, 机器码, 注释), ...]
# ----------------------------------------------------------------------
def build_program():
    prog = []

    def emit(word, comment=""):
        addr = len(prog) * 4
        prog.append((addr, word, comment))
        return addr

    # === 算术 / 逻辑 ===
    emit(addi(1, 0, 0),        "addi x1, x0, 0        x1=0")
    emit(addi(2, 0, 10),       "addi x2, x0, 10       x2=10")
    emit(addi(3, 0, 20),       "addi x3, x0, 20       x3=20")
    emit(add(4, 1, 2),         "add  x4, x1, x2       x4=10 (RAW 前递)")
    emit(sub(3, 3, 2),         "sub  x3, x3, x2       x3=10")
    emit(and_(5, 1, 2),        "and  x5, x1, x2       x5=0")
    emit(or_(6, 1, 2),         "or   x6, x1, x2       x6=10")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    # === 分支 / 跳转 ===
    emit(beq(0, 0, 8),         "beq  x0, x0, +8       -> 0x02C")
    emit(lui(6, 0),            "lui  x6, 0            分支失败则破坏 x6")
    emit(jal(0, 12),           "jal  x0, +12          -> 0x038")
    emit(lui(6, 0),            "lui  x6, 0            跳转失败则破坏 x6")
    emit(nop(),                "nop")
    # === 访存（RAM）===
    emit(lui(5, 0x10000),      "lui  x5, 0x10000      x5=RAM 基址")
    emit(lw(6, 0, 5),          "lw   x6, 0(x5)")
    emit(addi(6, 0, 1),        "addi x6, x0, 1        x6=1")
    emit(sw(6, 0, 5),          "sw   x6, 0(x5)        RAM[base]=1")
    emit(lw(7, 0, 5),          "lw   x7, 0(x5)        x7=1 (load-use)")
    emit(addi(8, 0, 0x7F),     "addi x8, x0, 0x7F")
    emit(sb(8, 1, 5),          "sb   x8, 1(x5)        RAM 字节写")
    emit(addi(9, 5, 1),        "addi x9, x5, 1")
    emit(lbu(10, 0, 9),        "lbu  x10, 0(x9)       x10=0x7F")
    emit(addi(10, 0, 0x7F),    "addi x10, x0, 0x7F")
    emit(bne(10, 10, 8),       "bne  x10, x10, +8     永不跳转")
    emit(addi(11, 0, 0x6F),    "addi x11, x0, 0x6F    占位")
    emit(addi(11, 0, 1),       "addi x11, x0, 1       占位")
    # === UART：BAUD + 等 TX 空闲 + 发 "OK\\n" ===
    # 注意：I 型立即数会符号扩展，0x800 是 -2048，所以 +0x800 要拆成两次 +0x400
    emit(lui(11, 0x20000),     "lui  x11, 0x20000     x11=0x2000_0000")
    emit(addi(11, 11, 0x400),  "addi x11, x11, 0x400  +0x400")
    emit(addi(11, 11, 0x400),  "addi x11, x11, 0x400  x11=0x2000_0800 UART 基址")
    emit(addi(12, 0, 867),     "addi x12, x0, 867     100MHz/115200-1")
    emit(sw(12, 0x0C, 11),     "sw   x12, 0x0C(x11)   UART.BAUD=867")
    emit(addi(12, 0, 0),       "addi x12, x0, 0")
    emit(lw(13, 8, 11),        "lw   x13, 8(x11)      UART.STATUS")
    emit(andi(13, 13, 1),      "andi x13, x13, 1      取 TX_BUSY")
    emit(bne(13, 0, -8),       "bne  x13, x0, -8      忙则等 -> 0x080")
    emit(addi(13, 0, 0x4F),    "addi x13, x0, 'O'")
    emit(sw(13, 0, 11),        "sw   x13, 0(x11)      UART.TXDATA='O'")
    emit(nop(),                "nop                   等 tx_busy 置起")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    emit(lw(13, 8, 11),        "lw   x13, 8(x11)      UART.STATUS")
    emit(andi(13, 13, 1),      "andi x13, x13, 1")
    emit(bne(13, 0, -8),       "bne  x13, x0, -8      忙则等")
    emit(addi(13, 0, 0x4B),    "addi x13, x0, 'K'")
    emit(sw(13, 0, 11),        "sw   x13, 0(x11)      UART.TXDATA='K'")
    emit(nop(),                "nop                   等 tx_busy 置起")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    emit(lw(13, 8, 11),        "lw   x13, 8(x11)      UART.STATUS")
    emit(andi(13, 13, 1),      "andi x13, x13, 1")
    emit(bne(13, 0, -8),       "bne  x13, x0, -8      忙则等")
    emit(addi(13, 0, 0x0A),    "addi x13, x0, '\\n'")
    emit(sw(13, 0, 11),        "sw   x13, 0(x11)      UART.TXDATA='\\n'")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    # === GPIO：DIR / DATA（输出回环到输入）===
    emit(addi(14, 11, 0x400),  "addi x14, x11, 0x400  x14=GPIO 基址")
    emit(addi(15, 0, 0xFF),    "addi x15, x0, 0xFF")
    emit(sw(15, 4, 14),        "sw   x15, 4(x14)      GPIO.DIR=0xFF")
    emit(addi(15, 0, 0x5A),    "addi x15, x0, 0x5A")
    emit(sw(15, 0, 14),        "sw   x15, 0(x14)      GPIO.DATA=0x5A")
    emit(lw(15, 0, 14),        "lw   x15, 0(x14)      x15=读回 DATA")
    # === TIMER：LOAD + 启动 + 轮询 OVERFLOW + 写 1 清 ===
    emit(addi(20, 11, -0x800), "addi x20, x11, -0x800 x20=TIMER 基址")
    emit(addi(15, 0, 200),     "addi x15, x0, 200     定时器装载值")
    emit(sw(15, 0, 20),        "sw   x15, 0(x20)      TIMER.LOAD=200")
    emit(addi(21, 0, 3),       "addi x21, x0, 3       EN=1, IRQ_EN=1")
    emit(sw(21, 8, 20),        "sw   x21, 8(x20)      TIMER.CTRL=3 启动")
    emit(lw(21, 0x0C, 20),     "lw   x21, 0x0C(x20)   TIMER.STATUS")
    emit(andi(21, 21, 1),      "andi x21, x21, 1      取 OVERFLOW")
    emit(beq(21, 0, -8),       "beq  x21, x0, -8      轮询溢出")
    emit(addi(14, 0, 1),       "addi x14, x0, 1")
    emit(sw(14, 0x0C, 20),     "sw   x14, 0x0C(x20)   STATUS 写 1 清 OVERFLOW")
    # === 半字访存自检 ===
    emit(addi(6, 0, 1),        "addi x6, x0, 1        通过标志")
    emit(nop(),                "nop")
    emit(nop(),                "nop")
    emit(lui(29, 0x10000),     "lui  x29, 0x10000     x29=RAM 基址")
    emit(addi(29, 29, 0x300),  "addi x29, x29, 0x300  x29=0x1000_0300")
    # 立即数会符号扩展：0xBEF 是 -1041，因此 0xBEEF 用 lui+addi 拼
    emit(lui(28, 0xC),         "lui  x28, 0xC         x28=0x0000_C000")
    emit(addi(28, 28, -0x111), "addi x28, x28, -0x111 x28=0x0000_BEEF")
    emit(sh(28, 0, 29),        "sh   x28, 0(x29)      RAM[0x300]=0xBEEF")
    emit(lw(30, 0, 29),        "lw   x30, 0(x29)      x30=0xBEEF")
    emit(lhu(31, 0, 29),       "lhu  x31, 0(x29)      x31=0xBEEF")
    emit(addi(29, 0, -0x411),  "addi x29, x0, -0x411  x29=0xFFFFFBEF")
    emit(addi(30, 0, 0),       "addi x30, x0, 0")
    emit(bne(31, 29, 8),       "bne  x31, x29, +8     半字读错则落到失败路径")
    fail_addr = len(prog) * 4
    emit(lui(6, 0),            "lui  x6, 0            ★ 失败路径：x6=0")
    pass_addr = len(prog) * 4
    emit(lui(5, 0x10000),      "lui  x5, 0x10000")
    emit(sw(6, 0, 5),          "sw   x6, 0(x5)        RESULT = 1(通过) / 0(失败)")
    hang_addr = len(prog) * 4
    emit(jal(0, 0),            "jal  x0, 0            ★ 挂死点")
    return prog, {"fail": fail_addr, "pass": pass_addr, "hang": hang_addr}


# ----------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------
def write_hex(path, prog):
    lines = [
        "//=====================================================================",
        "// cpu_test.hex — tb_top 使用的 RV32I 测试程序镜像",
        "//",
        "//   本文件由 tb/prog/gen_cpu_test.py 汇编生成，不要手工改机器码。",
        "//   行号 N 对应 ROM 字数地址 N，即字节地址 N*4。",
        "//",
        "//   地址映射（见 rtl/sys_define.svh）",
        "//     RAM   0x1000_0000    RESULT 在 0x1000_0000，半字测试在 0x1000_0300",
        "//     TIMER 0x2000_0000    LOAD +0 / COUNT +4 / CTRL +8 / STATUS +0x0C",
        "//     SPI   0x2000_0400",
        "//     UART  0x2000_0800    TXDATA +0 / RXDATA +4 / STATUS +8 / BAUD +0x0C",
        "//     GPIO  0x2000_0C00    DATA +0 / DIR +4 / SET +8 / CLR +0x0C",
        "//",
        "//   结束：RESULT=1 通过 / RESULT=0 失败，随后停在末尾的 jal x0,0",
        "//",
        "//   运行： make tb TB=tb_top",
        "//=====================================================================",
        "",
    ]
    for addr, word, comment in prog:
        lines.append(f"{word:08x}    // 0x{addr:03x}  {comment}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_coe(path, prog):
    values = [w for _, w, _ in prog]
    values += [nop()] * (WORDS - len(values))
    lines = ["memory_initialization_radix=16;",
             "memory_initialization_vector="]
    for i, v in enumerate(values):
        sep = ";" if i == len(values) - 1 else ","
        lines.append(f"{v:08X}{sep}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_mif(path, prog):
    values = [w for _, w, _ in prog]
    values += [nop()] * (WORDS - len(values))
    lines = [f"{v:032b}" for v in values]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# ----------------------------------------------------------------------
# 往返解码自检
# ----------------------------------------------------------------------
def decode(word):
    op = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7 = (word >> 25) & 0x7F
    imm_i = (word >> 20) & 0xFFF
    if imm_i & 0x800:
        imm_i -= 0x1000
    if op == 0b0110011:
        name = {0b000: "add" if f7 == 0 else "sub", 0b001: "sll", 0b010: "slt",
                0b011: "sltu", 0b100: "xor", 0b101: "srl" if f7 == 0 else "sra",
                0b110: "or", 0b111: "and"}[f3]
        return f"{name} x{rd}, x{rs1}, x{rs2}"
    if op == 0b0010011:
        name = {0b000: "addi", 0b111: "andi", 0b010: "slti", 0b011: "sltiu",
                0b100: "xori", 0b110: "ori"}.get(f3, f"opi{f3}")
        return f"{name} x{rd}, x{rs1}, {imm_i}"
    if op == 0b0000011:
        name = {0b000: "lb", 0b001: "lh", 0b010: "lw", 0b100: "lbu", 0b101: "lhu"}[f3]
        return f"{name} x{rd}, {imm_i}(x{rs1})"
    if op == 0b0100011:
        imm = ((word >> 25) << 5) | ((word >> 7) & 0x1F)
        if imm & 0x800:
            imm -= 0x1000
        name = {0b000: "sb", 0b001: "sh", 0b010: "sw"}[f3]
        return f"{name} x{rs2}, {imm}(x{rs1})"
    if op == 0b1100011:
        imm = (((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11) | \
              (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1)
        if imm & 0x1000:
            imm -= 0x2000
        name = {0b000: "beq", 0b001: "bne", 0b100: "blt", 0b101: "bge",
                0b110: "bltu", 0b111: "bgeu"}[f3]
        return f"{name} x{rs1}, x{rs2}, {imm:+d}"
    if op == 0b1101111:
        imm = (((word >> 31) & 1) << 20) | (((word >> 12) & 0xFF) << 12) | \
              (((word >> 20) & 1) << 11) | (((word >> 21) & 0x3FF) << 1)
        if imm & 0x100000:
            imm -= 0x200000
        return f"jal x{rd}, {imm:+d}"
    if op == 0b0110111:
        return f"lui x{rd}, 0x{(word >> 12) & 0xFFFFF:x}"
    return f"?.{op:07b}"


def self_check(prog):
    """往返解码：把每条机器码解回来与注释里的助记符首词对照（粗检）"""
    bad = 0
    for addr, word, comment in prog:
        text = decode(word)
        mnem = comment.split()[0] if comment else ""
        if mnem == "nop":                 # nop == addi x0, x0, 0
            mnem = "addi"
        if mnem and not text.startswith(mnem):
            print(f"  解码不符 0x{addr:03x}: {text}  (注释: {comment})")
            bad += 1
    print(f"往返解码自检：{len(prog)} 条，{bad} 条不符")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=None, help="输出目录（默认脚本所在目录）")
    ap.add_argument("--check", action="store_true", help="只做解码自检")
    args = ap.parse_args()

    outdir = Path(args.outdir) if args.outdir else Path(__file__).resolve().parent
    prog, marks = build_program()

    bad = self_check(prog)
    if args.check:
        return 1 if bad else 0

    write_hex(outdir / "cpu_test.hex", prog)
    write_coe(outdir / "cpu_test.coe", prog)
    write_mif(outdir / "ROM.mif", prog)
    print(f"已生成 {len(prog)} 条指令（{len(prog)*4} 字节）")
    print(f"  失败路径 0x{marks['fail']:03x} / 通过路径 0x{marks['pass']:03x}"
          f" / 挂死点 0x{marks['hang']:03x}")
    print(f"  {outdir/'cpu_test.hex'}")
    print(f"  {outdir/'cpu_test.coe'}")
    print(f"  {outdir/'ROM.mif'}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
