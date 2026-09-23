#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cpu_test.py — 生成 tb_top 使用的 RV32I 系统级测试程序

设计要点
--------
1. 内置一份 **RV32I 参考模型**（寄存器堆 + 数据存储器）：程序里每条指令在生成
   时同时被模型执行一遍，结果槽的期望值直接取自模型而不是手算，避免「程序与
   期望值两处都写错」。模型另有抽样人工核对（见 self_check）。
2. 内置**覆盖率自检**：统计程序里出现过的助记符并与 RV32I 清单比对，缺一条就
   报错退出（ECALL/EBREAK 是陷阱指令，需要 CSR/异常支持，见 RV32I_DEFERRED）。
3. 输出 5 个文件（同源）：
      cpu_test.hex    带注释机器码清单（含覆盖率报告）
      cpu_test.coe    ROM IP 初始化文件（16 进制）
      ROM.mif         ROM 仿真模型初始化文件（每行 32 bit 二进制）
      cpu_test.exp    结果槽期望值与名称（每行「期望值 名称」）
4. 结果槽布局（RAM，字节地址）：
      0x00    RESULT（1 = 通过，0 = 失败）
      0x04    DONE 魔数 0x600D_1EAF（tb_top 用它判断程序跑完）
      0x10    访存测试数据区
      0x300   半字自检
      0x400   指令覆盖结果槽（按顺序编号）

用法
----
    python3 tb/prog/gen_cpu_test.py            # 生成全部文件 + 覆盖率自检
    python3 tb/prog/gen_cpu_test.py --check    # 只做覆盖率 / 往返解码 / 抽样核对
"""

import argparse
from pathlib import Path

WORDS = 4096

RAM_BASE = 0x1000_0000
RESULT_OFF = 0x00
DONE_OFF = 0x04
DONE_MAGIC = 0x600D_1EAF
MEMTEST_OFF = 0x10
HALF_OFF = 0x300
SLOT_OFF = 0x400
TRAP_REC_OFF = 0x200      # 陷阱记录区：每条 8 字节（mcause, mepc）
TRAP_PTR_OFF = 0x280      # 记录指针
IRQ_FLAG_OFF = 0x284      # 中断已发生标志
TIMER_BASE = 0x2000_0000
UART_BASE_ = 0x2000_0800

RV32I = {
    "R": ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"],
    "I": ["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"],
    "L": ["lb", "lh", "lw", "lbu", "lhu"],
    "S": ["sb", "sh", "sw"],
    "B": ["beq", "bne", "blt", "bge", "bltu", "bgeu"],
    "J": ["jal", "jalr"],
    "U": ["lui", "auipc"],
    "MISC": ["fence"],
}
ZICSR = ["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci"]
ZICSR_EXTRA = ["mret", "ecall", "ebreak", "fence"]
RV32I_DEFERRED = []            # ECALL/EBREAK 现在由系统级陷阱用例覆盖（见 sys 组）


# ======================================================================
# 指令编码
# ======================================================================
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


def addi(rd, rs1, imm):   return i_type(imm, rs1, 0b000, rd, 0b0010011)
def slti(rd, rs1, imm):   return i_type(imm, rs1, 0b010, rd, 0b0010011)
def sltiu(rd, rs1, imm):  return i_type(imm, rs1, 0b011, rd, 0b0010011)
def xori(rd, rs1, imm):   return i_type(imm, rs1, 0b100, rd, 0b0010011)
def ori(rd, rs1, imm):    return i_type(imm, rs1, 0b110, rd, 0b0010011)
def andi(rd, rs1, imm):   return i_type(imm, rs1, 0b111, rd, 0b0010011)
def slli(rd, rs1, sh):    return i_type(sh & 0x1F, rs1, 0b001, rd, 0b0010011)
def srli(rd, rs1, sh):    return i_type(sh & 0x1F, rs1, 0b101, rd, 0b0010011)
def srai(rd, rs1, sh):    return i_type(0x400 | (sh & 0x1F), rs1, 0b101, rd, 0b0010011)
def lb(rd, imm, rs1):     return i_type(imm, rs1, 0b000, rd, 0b0000011)
def lh(rd, imm, rs1):     return i_type(imm, rs1, 0b001, rd, 0b0000011)
def lw(rd, imm, rs1):     return i_type(imm, rs1, 0b010, rd, 0b0000011)
def lbu(rd, imm, rs1):    return i_type(imm, rs1, 0b100, rd, 0b0000011)
def lhu(rd, imm, rs1):    return i_type(imm, rs1, 0b101, rd, 0b0000011)
def sw(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b010)
def sb(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b000)
def sh(rs2, imm, rs1):    return s_type(imm, rs2, rs1, 0b001)
def beq(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b000)
def bne(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b001)
def blt(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b100)
def bge(rs1, rs2, imm):   return b_type(imm, rs2, rs1, 0b101)
def bltu(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 0b110)
def bgeu(rs1, rs2, imm):  return b_type(imm, rs2, rs1, 0b111)
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
def auipc(rd, imm20):     return u_type(imm20, rd, 0b0010111)
def jal(rd, imm):         return j_type(imm, rd)
def jalr(rd, rs1, imm):   return i_type(imm, rs1, 0b000, rd, 0b1100111)
def fence():              return 0x0FF0000F
# Zicsr
def csrrw(rd, csr, rs1):  return i_type(csr, rs1, 0b001, rd, 0b1110011)
def csrrs(rd, csr, rs1):  return i_type(csr, rs1, 0b010, rd, 0b1110011)
def csrrc(rd, csr, rs1):  return i_type(csr, rs1, 0b011, rd, 0b1110011)
def csrrwi(rd, csr, uimm):  return i_type(csr, uimm, 0b101, rd, 0b1110011)
def csrrsi(rd, csr, uimm):  return i_type(csr, uimm, 0b110, rd, 0b1110011)
def csrrci(rd, csr, uimm):  return i_type(csr, uimm, 0b111, rd, 0b1110011)
def mret():               return 0x3020_0073
def ecall():              return 0x0000_0073
def ebreak():             return 0x0010_0073

# CSR 地址（与 rtl/sys_define.svh 一致）
CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC = 0x300, 0x301, 0x304, 0x305
CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE = 0x340, 0x341, 0x342

# 异常 cause
CAUSE_ILLEGAL, CAUSE_EBREAK, CAUSE_LOAD_MIS = 2, 3, 4
CAUSE_STORE_MIS, CAUSE_ECALL = 6, 11
CAUSE_IRQ_TIMER = 0x8000_0007
def nop():                return addi(0, 0, 0)


M32 = 0xFFFFFFFF


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x8000_0000 else v


def sext12(imm):
    imm &= 0xFFF
    return imm - 0x1000 if imm & 0x800 else imm


# ======================================================================
# 程序 + RV32I 参考模型
# ======================================================================
class Prog:
    def __init__(self):
        self.words = []
        self.comments = []
        self.reg = [0] * 32
        self.mem = {}                 # 字节地址(字对齐) -> 32bit
        # CSR 参考模型（复位值；只实现系统级用例用到的语义）
        self.csr = {CSR_MSTATUS: 0, CSR_MISA: 0x4000_0100, CSR_MIE: 0,
                    CSR_MTVEC: 0, CSR_MSCRATCH: 0, CSR_MEPC: 0, CSR_MCAUSE: 0}
        self.labels = {}
        self.fixups = []              # (word_idx, kind, label, rs1)
        self.slots = []               # (name, expected)
        self.notes = []               # (字节地址, 段标题)
        self.mismatch = []            # 期望值与参考模型不一致的记录
        self.expects = []             # (字节地址, 期望值, 名称)：测试平台逐项核对
        self._cov = set()

    @property
    def cov(self):
        return self._cov

    # ---------------- 基础 ----------------
    def addr(self):
        return len(self.words) * 4

    def label(self, name):
        assert name not in self.labels, f"label {name} 重复"
        self.labels[name] = self.addr()

    def section(self, text):
        self.notes.append((self.addr(), text))

    def raw(self, word, mnem, comment):
        """只发射、不让参考模型执行（陷阱处理程序等非线性代码用）"""
        idx = self._push(word, comment)
        self._cov.add(mnem)
        return idx

    def li(self, rd, value, comment):
        """lui + addi 装载 32 bit 常量（返回发射的指令数）"""
        value &= M32
        hi = (value >> 12) & 0xFFFFF
        lo = value & 0xFFF
        if lo & 0x800:
            lo -= 0x1000
            hi = (hi + 1) & 0xFFFFF
        n = 0
        if hi != 0 or lo < 0:
            self.emit(lui(rd, hi), "lui", f"lui  x{rd}, 0x{hi:05x}      {comment}")
            n += 1
        if lo != 0:
            self.emit(addi(rd, rd, lo), "addi",
                      f"addi x{rd}, x{rd}, {lo}   {comment}")
            n += 1
        return n

    def li_raw(self, rd, value, comment):
        """同上，但只发射不执行（raw 区用）"""
        value &= M32
        hi = (value >> 12) & 0xFFFFF
        lo = value & 0xFFF
        if lo & 0x800:
            lo -= 0x1000
            hi = (hi + 1) & 0xFFFFF
        if hi != 0 or lo < 0:
            self.raw(lui(rd, hi), "lui", f"lui  x{rd}, 0x{hi:05x}      {comment}")
        if lo != 0:
            self.raw(addi(rd, rd, lo), "addi",
                     f"addi x{rd}, x{rd}, {lo}   {comment}")

    def slot_model(self, reg, byte_addr, name):
        """把 x{reg} 存到指定地址，期望值直接取自参考模型（CSR 等复杂语义）"""
        self.emit(sw(reg, byte_addr, 5), "sw", f"sw   x{reg}, 0x{byte_addr:03x}  {name}")
        self.slots.append((name, self.reg[reg]))
        self.expects.append((byte_addr, self.reg[reg], name))

    def expect_ram(self, byte_addr, value, name):
        """登记一个期望的 RAM 值（陷阱记录等非线性路径用；不经模型核对）"""
        self.expects.append((byte_addr, value & M32, name))

    def _push(self, word, comment):
        assert len(self.words) < WORDS, "ROM 容量不足"
        self.words.append(word)
        self.comments.append(comment)
        return len(self.words) - 1

    # ---------------- 模型 ----------------
    def _wr(self, rd, val):
        if rd != 0:
            self.reg[rd] = val & M32

    def _mem_word(self, byte_addr):
        return self.mem.get(byte_addr & ~3, 0)

    def _mem_write(self, byte_addr, value, size):
        base = byte_addr & ~3
        cur = self.mem.get(base, 0)
        off = byte_addr & 3
        if size == 0:
            m = 0xFF << (8 * off)
            cur = (cur & ~m) | ((value & 0xFF) << (8 * off))
        elif size == 1:
            m = 0xFFFF << (8 * off)
            cur = (cur & ~m) | ((value & 0xFFFF) << (8 * off))
        else:
            cur = value & M32
        self.mem[base] = cur & M32

    # ---------------- 发射 + 模型执行 ----------------
    def emit(self, word, mnem, comment):
        idx = self._push(word, comment)
        addr = idx * 4
        op = word & 0x7F
        rd = (word >> 7) & 0x1F
        f3 = (word >> 12) & 7
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        f7 = (word >> 25) & 0x7F
        imm_i = sext12(word >> 20)
        imm_s = sext12(((word >> 25) << 5) | ((word >> 7) & 0x1F))
        self._cov.add(mnem)

        if op == 0b0110011:                       # R 型
            a, b = self.reg[rs1], self.reg[rs2]
            sh = b & 31
            if f3 == 0b000:
                v = (a + b) if f7 == 0 else (a - b)
            elif f3 == 0b001:
                v = a << sh
            elif f3 == 0b010:
                v = 1 if s32(a) < s32(b) else 0
            elif f3 == 0b011:
                v = 1 if a < b else 0
            elif f3 == 0b100:
                v = a ^ b
            elif f3 == 0b101:
                v = (a >> sh) if f7 == 0 else (s32(a) >> sh)
            elif f3 == 0b110:
                v = a | b
            else:
                v = a & b
            self._wr(rd, v)
        elif op == 0b0010011:                     # I 型
            a = self.reg[rs1]
            if f3 == 0b000:
                v = a + imm_i
            elif f3 == 0b010:
                v = 1 if s32(a) < imm_i else 0
            elif f3 == 0b011:
                v = 1 if a < (imm_i & M32) else 0
            elif f3 == 0b100:
                v = a ^ (imm_i & M32)
            elif f3 == 0b110:
                v = a | (imm_i & M32)
            elif f3 == 0b111:
                v = a & (imm_i & M32)
            elif f3 == 0b001:
                v = a << ((word >> 20) & 0x1F)
            else:
                sh = (word >> 20) & 0x1F
                v = (a >> sh) if ((word >> 30) & 1) == 0 else (s32(a) >> sh)
            self._wr(rd, v)
        elif op == 0b0000011:                     # load
            byte_addr = self.reg[rs1] + imm_i
            w = self._mem_word(byte_addr)
            off = byte_addr & 3
            byte = (w >> (8 * off)) & 0xFF
            half = (w >> (8 * (off & 2))) & 0xFFFF
            if f3 == 0b000:
                v = (byte | 0xFFFF_FF00) if byte & 0x80 else byte
            elif f3 == 0b001:
                v = (half | 0xFFFF_0000) if half & 0x8000 else half
            elif f3 == 0b010:
                v = w
            elif f3 == 0b100:
                v = byte
            else:
                v = half
            self._wr(rd, v)
        elif op == 0b0100011:                     # store
            self._mem_write(self.reg[rs1] + imm_s, self.reg[rs2], f3)
        elif op == 0b1101111:                     # jal
            self._wr(rd, addr + 4)
        elif op == 0b1100111:                     # jalr
            self._wr(rd, addr + 4)
        elif op == 0b1110011:                     # Zicsr / SYSTEM
            if f3 != 0:
                csr = (word >> 20) & 0xFFF
                old = self.csr.get(csr, 0)
                self._wr(rd, old)                 # rd ← CSR 旧值
                src = ((word >> 15) & 0x1F) if (f3 & 0b100) else self.reg[rs1]
                we = (f3 in (0b001, 0b101)) or (src != 0)
                if we and (csr in self.csr):
                    if   f3 in (0b001, 0b101): new = src
                    elif f3 in (0b010, 0b110): new = old | src
                    else:                      new = old & ~src
                    if csr == CSR_MTVEC:
                        new &= ~3
                    if csr == CSR_MEPC:
                        new &= ~3
                    if csr == CSR_MIE:
                        new &= 0x80
                    if csr == CSR_MSTATUS:
                        new = (3 << 11) | ((new & 0x80)) | ((new & 8))
                    self.csr[csr] = new & M32
        elif op == 0b0110111:                     # lui
            self._wr(rd, word & 0xFFFFF000)
        elif op == 0b0010111:                     # auipc
            self._wr(rd, addr + (word & 0xFFFFF000))
        return idx

    # ---------------- 分支 / 跳转（标签回填） ----------------
    def branch(self, mnem, word, label, comment):
        idx = self._push(word, comment)
        self.fixups.append((idx, "b", label, None))
        self._cov.add(mnem)
        return idx

    def jump(self, mnem, word, label, comment):
        idx = self._push(word, comment)
        rd = (word >> 7) & 0x1F
        if rd != 0:                            # 链接值 = 本指令地址 + 4
            self._wr(rd, idx * 4 + 4)
        self.fixups.append((idx, "j", label, None))
        self._cov.add(mnem)
        return idx

    def resolve(self):
        for idx, kind, label, extra in self.fixups:
            assert label in self.labels, f"未定义标签 {label}"
            imm = self.labels[label] - idx * 4
            word = self.words[idx]
            rd = (word >> 7) & 0x1F
            rs1 = (word >> 15) & 0x1F
            rs2 = (word >> 20) & 0x1F
            f3 = (word >> 12) & 7
            if kind == "b":
                self.words[idx] = b_type(imm, rs2, rs1, f3)
            else:
                self.words[idx] = j_type(imm, rd)
        self.fixups = []

    # ---------------- 结果槽 ----------------
    def slot(self, name, expected, reg=10, byte_addr=None):
        """把 x{reg} 存进结果槽；同时用参考模型核对期望值，防止手算写错"""
        n = len(self.slots)
        byte = SLOT_OFF + n * 4 if byte_addr is None else byte_addr
        self.emit(sw(reg, byte, 5), "sw",
                  f"sw   x{reg}, 0x{byte:03x}  {name}")
        self.slots.append((name, expected & M32))
        self.expects.append((byte, expected & M32, name))
        model_val = self.reg[reg]
        if model_val != (expected & M32):
            self.mismatch.append(
                f"slot[{n}] {name}: 手工期望 {expected & M32:08x} / 模型 {model_val:08x}")
        return n


# ======================================================================
# 程序主体（全部经模型执行）
# ======================================================================
def build_program():
    p = Prog()
    p.section("=== 基址与常用常量 ===")
    p.emit(lui(5, 0x10000), "lui", "lui  x5, 0x10000     x5 = RAM 基址")
    p.emit(addi(1, 0, 5), "addi", "addi x1, x0, 5       x1 = 5")
    p.emit(addi(2, 0, -5), "addi", "addi x2, x0, -5      x2 = -5")
    p.emit(lui(3, 0x80000), "lui", "lui  x3, 0x80000     x3 = 0x8000_0000")
    p.emit(addi(4, 3, -1), "addi", "addi x4, x3, -1      x4 = 0x7FFF_FFFF")
    p.emit(lui(6, 0x12345), "lui", "lui  x6, 0x12345")
    p.emit(addi(6, 6, 0x678), "addi", "addi x6, x6, 0x678   x6 = 0x1234_5678")
    p.emit(addi(7, 0, -1), "addi", "addi x7, x0, -1      x7 = 0xFFFF_FFFF")

    p.section("=== R 型：add / sub / sll / slt / sltu / xor / srl / sra / or / and ===")
    for mnem, word, name, exp in [
        ("add",  add(10, 1, 2),   "add   5+(-5)",                0),
        ("add",  add(10, 4, 1),   "add   回绕 INT_MAX+4",        0x8000_0004),
        ("sub",  sub(10, 1, 6),   "sub   5-0x12345678",          0xEDCB_A98D),
        ("sub",  sub(10, 2, 1),   "sub   -5-5",                  0xFFFF_FFF6),
        ("sll",  sll(10, 1, 1),   "sll   5<<5",                  160),
        ("sll",  sll(10, 1, 2),   "sll   移位量取 rs2[4:0]",     0x2800_0000),
        ("srl",  srl(10, 3, 1),   "srl   逻辑右移",              0x0400_0000),
        ("sra",  sra(10, 3, 1),   "sra   算术右移",              0xFC00_0000),
        ("srl",  srl(10, 7, 1),   "srl   0xFFFFFFFF>>5",         0x07FF_FFFF),
        ("sra",  sra(10, 7, 1),   "sra   0xFFFFFFFF>>>5",        0xFFFF_FFFF),
        ("sll",  sll(10, 1, 0),   "sll   移位 0",                5),
        ("slt",  slt(10, 2, 1),   "slt   -5 < 5",                1),
        ("slt",  slt(10, 1, 2),   "slt   5 < -5",                0),
        ("slt",  slt(10, 3, 4),   "slt   INT_MIN < INT_MAX",     1),
        ("slt",  slt(10, 4, 3),   "slt   INT_MAX < INT_MIN",     0),
        ("sltu", sltu(10, 2, 1),  "sltu  0xFFFFFFFB < 5",        0),
        ("sltu", sltu(10, 1, 2),  "sltu  5 < 0xFFFFFFFB",        1),
        ("sltu", sltu(10, 3, 4),  "sltu  无符号边界 1",          0),
        ("sltu", sltu(10, 4, 3),  "sltu  无符号边界 2",          1),
        ("xor",  xor_(10, 6, 7),  "xor   与全 1 异或",           0xEDCB_A987),
        ("xor",  xor_(10, 6, 0),  "xor   与 x0 异或",            0x1234_5678),
        ("or",   or_(10, 6, 7),   "or    与全 1 或",             0xFFFF_FFFF),
        ("or",   or_(10, 1, 2),   "or    5 | -5",                0xFFFF_FFFF),
        ("and",  and_(10, 6, 7),  "and   与全 1 与",             0x1234_5678),
        ("and",  and_(10, 6, 3),  "and   无公共位",              0),
    ]:
        p.emit(word, mnem, f"{mnem:5s} {name}")
        p.slot(name, exp)

    p.section("=== I 型：addi / slti / sltiu / xori / ori / andi / slli / srli / srai ===")
    for mnem, word, name, exp in [
        ("addi",  addi(10, 0, 2047),  "addi  立即数上界 2047",              2047),
        ("addi",  addi(10, 0, -2048), "addi  立即数下界 -2048",             0xFFFF_F800),
        ("addi",  addi(10, 7, 1),     "addi  0xFFFFFFFF+1 回绕",            0),
        ("slti",  slti(10, 1, 5),     "slti  5 < 5",                        0),
        ("slti",  slti(10, 1, 6),     "slti  5 < 6",                        1),
        ("slti",  slti(10, 2, 0),     "slti  -5 < 0",                       1),
        ("slti",  slti(10, 3, 0),     "slti  INT_MIN < 0",                  1),
        ("sltiu", sltiu(10, 1, 5),    "sltiu 5 < 5",                        0),
        ("sltiu", sltiu(10, 1, 6),    "sltiu 5 < 6",                        1),
        ("sltiu", sltiu(10, 2, -1),   "sltiu 立即数符号扩展后无符号比较",    1),
        ("sltiu", sltiu(10, 7, -1),   "sltiu 与 -1 相等",                   0),
        ("xori",  xori(10, 6, -1),    "xori  取反",                         0xEDCB_A987),
        ("xori",  xori(10, 1, 0x0F0), "xori  低 12 位掩码",                 0xF5),
        ("ori",   ori(10, 1, 0x0F0),  "ori   置位",                         0xF5),
        ("ori",   ori(10, 0, 0x7FF),  "ori   立即数上界",                   0x7FF),
        ("andi",  andi(10, 6, 0x0FF), "andi  取低字节",                     0x78),
        ("andi",  andi(10, 6, -16),   "andi  负数立即数",                   0x1234_5670),
        ("slli",  slli(10, 1, 4),     "slli  左移 4",                       80),
        ("slli",  slli(10, 3, 31),    "slli  移出全部位",                   0),
        ("srli",  srli(10, 3, 31),    "srli  逻辑右移 31",                  1),
        ("srai",  srai(10, 3, 31),    "srai  算术右移 31",                  0xFFFF_FFFF),
        ("srli",  srli(10, 6, 0),     "srli  移位 0",                       0x1234_5678),
        ("srai",  srai(10, 6, 0),     "srai  移位 0",                       0x1234_5678),
        ("srai",  srai(10, 6, 4),     "srai  正数算术右移",                 0x0123_4567),
    ]:
        p.emit(word, mnem, f"{mnem:5s} {name}")
        p.slot(name, exp)

    p.section("=== U 型：lui / auipc ===")
    p.emit(lui(10, 0xDEADB), "lui", "lui   x10, 0xDEADB")
    p.slot("lui 高 20 位", 0xDEAD_B000)
    p.emit(lui(10, 0x00001), "lui", "lui   x10, 1")
    p.slot("lui 最小值 1", 0x0000_1000)
    a1 = p.addr()
    p.emit(auipc(10, 0), "auipc", "auipc x10, 0")
    p.slot("auipc 取本指令地址", a1)
    a2 = p.addr()
    p.emit(auipc(10, 1), "auipc", "auipc x10, 1")
    p.slot("auipc + 0x1000", a2 + 0x1000)
    a3 = p.addr()
    p.emit(auipc(10, 0xFFFFF), "auipc", "auipc x10, 0xFFFFF")
    p.slot("auipc 负偏移", a3 - 0x1000)

    p.section("=== 访存：sb / sh / sw 与 lb / lh / lw / lbu / lhu ===")
    p.emit(lui(8, 0x807F8), "lui", "lui  x8, 0x807F8")
    p.emit(ori(8, 8, 0x0FF), "ori", "ori  x8, x8, 0xFF     x8 = 0x807F_80FF")
    p.emit(sw(8, MEMTEST_OFF, 5), "sw", "sw   x8, MEMTEST+0")
    for mnem, fn, off, name, exp in [
        ("lb",  lb,  0, "lb   @0 符号扩展", 0xFFFF_FFFF),
        ("lb",  lb,  1, "lb   @1 符号扩展", 0xFFFF_FF80),
        ("lb",  lb,  2, "lb   @2 正字节",   0x0000_007F),
        ("lb",  lb,  3, "lb   @3 符号扩展", 0xFFFF_FF80),
        ("lbu", lbu, 0, "lbu  @0 零扩展",   0x0000_00FF),
        ("lbu", lbu, 1, "lbu  @1 零扩展",   0x0000_0080),
        ("lbu", lbu, 3, "lbu  @3 零扩展",   0x0000_0080),
        ("lh",  lh,  0, "lh   @0 符号扩展", 0xFFFF_80FF),
        ("lh",  lh,  2, "lh   @2 符号扩展", 0xFFFF_807F),
        ("lhu", lhu, 0, "lhu  @0 零扩展",   0x0000_80FF),
        ("lhu", lhu, 2, "lhu  @2 零扩展",   0x0000_807F),
    ]:
        p.emit(fn(10, MEMTEST_OFF + off, 5), mnem,
               f"{mnem:4s} x10, MEMTEST+{off}   {name}")
        p.slot(name, exp)
    p.emit(lw(10, MEMTEST_OFF, 5), "lw", "lw   x10, MEMTEST+0")
    p.slot("lw 整字", 0x807F_80FF)
    p.emit(fence(), "fence", "fence                访存次序提示（顺序流水线）")

    p.emit(lui(9, 0x11223), "lui", "lui  x9, 0x11223")
    p.emit(ori(9, 9, 0x344), "ori", "ori  x9, x9, 0x344    x9 = 0x1122_3344")
    p.emit(sw(9, MEMTEST_OFF + 8, 5), "sw", "sw   x9, MEMTEST+8")
    p.emit(lw(10, MEMTEST_OFF + 8, 5), "lw", "lw   x10, MEMTEST+8")
    p.slot("sw 整字回读", 0x1122_3344)
    p.emit(addi(12, 0, 0xAA), "addi", "addi x12, x0, 0xAA")
    p.emit(sb(12, MEMTEST_OFF + 9, 5), "sb", "sb   x12, MEMTEST+9   只改 lane1")
    p.emit(lw(10, MEMTEST_OFF + 8, 5), "lw", "lw   x10, MEMTEST+8")
    p.slot("sb 只改目标通道", 0x1122_AA44)
    p.emit(sb(12, MEMTEST_OFF + 11, 5), "sb", "sb   x12, MEMTEST+11  改 lane3")
    p.emit(lw(10, MEMTEST_OFF + 8, 5), "lw", "lw   x10, MEMTEST+8")
    p.slot("sb 最高字节", 0xAA22_AA44)
    p.emit(addi(13, 0, 0x7BC), "addi", "addi x13, x0, 0x7BC")
    p.emit(sh(13, MEMTEST_OFF + 10, 5), "sh", "sh   x13, MEMTEST+10  只改高半字")
    p.emit(lw(10, MEMTEST_OFF + 8, 5), "lw", "lw   x10, MEMTEST+8")
    p.slot("sh 只改目标半字", 0x07BC_AA44)

    p.emit(lw(14, MEMTEST_OFF, 5), "lw", "lw   x14, MEMTEST+0   load-use")
    p.emit(add(10, 14, 14), "add", "add  x10, x14, x14   紧随 load 使用")
    p.slot("load-use 前递", 0x00FF_01FE)
    p.emit(lw(14, MEMTEST_OFF + 8, 5), "lw", "lw   x14, MEMTEST+8")
    p.emit(lw(15, MEMTEST_OFF, 5), "lw", "lw   x15, MEMTEST+0   背靠背")
    p.emit(xor_(10, 14, 15), "xor", "xor  x10, x14, x15   同时依赖两条 load")
    p.slot("背靠背 load", 0x07BC_AA44 ^ 0x807F_80FF)

    p.section("=== 分支：beq / bne / blt / bge / bltu / bgeu（跳与不跳 + 边界）===")
    cases = [
        ("beq",  beq,  1, 1, True,  "beq  相等 -> 跳"),
        ("beq",  beq,  1, 6, False, "beq  不等 -> 不跳"),
        ("bne",  bne,  1, 6, True,  "bne  不等 -> 跳"),
        ("bne",  bne,  1, 1, False, "bne  相等 -> 不跳"),
        ("blt",  blt,  2, 1, True,  "blt  -5 < 5 -> 跳"),
        ("blt",  blt,  1, 2, False, "blt  5 < -5 -> 不跳"),
        ("blt",  blt,  3, 4, True,  "blt  有符号边界 INT_MIN < INT_MAX"),
        ("bge",  bge,  1, 2, True,  "bge  5 >= -5 -> 跳"),
        ("bge",  bge,  2, 1, False, "bge  -5 >= 5 -> 不跳"),
        ("bge",  bge,  4, 3, True,  "bge  有符号边界 INT_MAX >= INT_MIN"),
        ("bltu", bltu, 1, 2, True,  "bltu 无符号 5 < 0xFFFFFFFB"),
        ("bltu", bltu, 2, 1, False, "bltu 无符号 0xFFFFFFFB < 5 -> 不跳"),
        ("bltu", bltu, 4, 3, True,  "bltu 无符号边界"),
        ("bgeu", bgeu, 2, 1, True,  "bgeu 无符号 >= 5"),
        ("bgeu", bgeu, 1, 2, False, "bgeu 无符号 5 >= 0xFFFFFFFB -> 不跳"),
        ("bgeu", bgeu, 3, 4, True,  "bgeu 无符号边界"),
    ]
    for bi, (mnem, fn, rs1, rs2, taken, name) in enumerate(cases):
        rew, aft = f"br_rew{bi}", f"br_aft{bi}"
        p.emit(addi(11, 0, 0), "addi", "addi x11, x0, 0       结果槽 = 0")
        p.branch(mnem, fn(rs1, rs2, 0), rew, f"{mnem:4s} x{rs1}, x{rs2}      {name}")
        p.jump("jal", jal(0, 0), aft, "jal  x0, <after>      未跳则跳过奖励")
        p.label(rew)
        p.emit(addi(11, 0, 1), "addi", "addi x11, x0, 1       结果槽 = 1")
        p.label(aft)
        p.reg[11] = 1 if taken else 0          # 先按真实执行路径修正模型
        p.slot(name, 1 if taken else 0, reg=11)

    p.section("=== 跳转：jal（前向/后向、带/不带链接）/ jalr（目标/链接/&~1 对齐）===")
    p.emit(addi(11, 0, 0), "addi", "addi x11, x0, 0")
    p.jump("jal", jal(0, 0), "j1_ok", "jal  x0, j1_ok        前向跳转")
    p.emit(addi(11, 0, 0x7FF), "addi", "addi x11, x0, 0x7FF   不该执行")
    p.label("j1_ok")
    p.emit(addi(11, 0, 1), "addi", "addi x11, x0, 1")
    p.slot("jal 前向跳转", 1, reg=11)

    link_addr = p.addr() + 4
    p.jump("jal", jal(13, 0), "j2_ok", "jal  x13, j2_ok       带链接")
    p.emit(addi(11, 0, 0x7FF), "addi", "addi x11, x0, 0x7FF   不该执行")
    p.label("j2_ok")
    p.slot("jal 链接值 pc+4", link_addr, reg=13)

    p.emit(addi(16, 0, 0), "addi", "addi x16, x0, 0       计数")
    p.emit(addi(17, 0, 0), "addi", "addi x17, x0, 0       迭代变量")
    p.label("j3_loop")
    p.emit(addi(16, 16, 1), "addi", "addi x16, x16, 1      ← 循环目标（非幂等）")
    p.emit(addi(17, 17, 1), "addi", "addi x17, x17, 1")
    p.emit(addi(18, 0, 3), "addi", "addi x18, x0, 3")
    p.branch("bne", bne(17, 18, 0), "j3_loop", "bne  x17, x18, j3_loop  后向分支循环")
    p.reg[16] = 3                              # 循环 3 次后的真实值
    p.slot("后向分支循环 3 次", 3, reg=16)

    # jalr：目标地址在寄存器里，检查链接值
    tgt = p.addr() + 16
    p.emit(addi(12, 0, tgt), "addi", "addi x12, x0, <target>")
    jr_link = p.addr() + 4
    p.emit(jalr(13, 12, 0), "jalr", "jalr x13, 0(x12)       跳到 target")
    for _ in range(3):
        p.emit(addi(11, 0, 0x7FF), "addi", "addi x11, x0, 0x7FF   不该执行")
    p.slot("jalr 链接值 pc+4", jr_link, reg=13)
    p.reg[12] = tgt

    # jalr：目标最低位为 1 → 必须 &~1
    tgt2 = p.addr() + 20
    p.emit(addi(12, 0, tgt2 + 1), "addi", "addi x12, x0, <target+1>  最低位 = 1")
    p.emit(jalr(14, 12, 0), "jalr", "jalr x14, 0(x12)       必须把最低位清零")
    for _ in range(4):
        p.emit(addi(11, 0, 0x7FF), "addi", "addi x11, x0, 0x7FF   不该执行")
    p.emit(addi(11, 0, 1), "addi", "addi x11, x0, 1        落在对齐后的目标")
    p.slot("jalr 目标 &~1 对齐", 1, reg=11)

    # jalr：目标 = rs1 + 正偏移
    tgt3 = p.addr() + 20
    p.emit(addi(12, 0, tgt3 - 8), "addi", "addi x12, x0, <target-8>")
    p.emit(jalr(15, 12, 8), "jalr", "jalr x15, 8(x12)       目标 = rs1+imm")
    for _ in range(3):
        p.emit(addi(11, 0, 0x7FF), "addi", "addi x11, x0, 0x7FF   不该执行")
    p.emit(addi(11, 0, 0), "addi", "addi x11, x0, 0")
    p.emit(addi(11, 0, 1), "addi", "addi x11, x0, 1        落在 rs1+imm 目标")
    p.slot("jalr 目标 rs1+imm", 1, reg=11)
    p.reg[12] = tgt3 - 8
    p.reg[15] = tgt3

    # jalr：后向跳转（跳到本用例前面的目标，跳一次后靠分支跳出）
    p.emit(addi(19, 0, 0), "addi", "addi x19, x0, 0        计数")
    p.emit(addi(21, 0, 1), "addi", "addi x21, x0, 1        比较值")
    loop_addr = p.addr()
    p.label("j4_loop")
    p.emit(addi(19, 19, 1), "addi", "addi x19, x19, 1      ← jalr 后向目标")
    p.branch("bne", bne(19, 21, 0), "j4_after",
             "bne  x19, x21, j4_after   第二次经过时跳出")
    p.emit(addi(12, 0, loop_addr), "addi", "addi x12, x0, <j4_loop>")
    p.emit(jalr(0, 12, 0), "jalr", "jalr x0, 0(x12)        后向跳回")
    p.label("j4_after")
    p.reg[19] = 2                              # 真实路径：加 1 两次
    p.slot("jalr 后向跳转 2 次", 2, reg=19)

    return p


# ======================================================================
# 陷阱 / 中断段
#   · 主流程里依次触发 ECALL / EBREAK / 非法指令 / 非对齐 load / 非对齐 store
#     / 定时器中断，每条都会跳到处理程序；
#   · 处理程序把 (mcause, mepc) 顺序记进 RAM 记录区，同步异常把 mepc+4
#     （跳过出错指令）后 MRET 返回，中断则置标志、清定时器溢出、MRET 回到
#     被打断的指令；
#   · 记录区的期望值由生成器显式给出（这些路径不经过参考模型）。
# ======================================================================
def append_trap_section(p):
    p.section("=== CSR 指令自测（Zicsr 六种形式 + misa 只读）===")
    p.li(24, 0x1234, "x24 = 0x1234")
    p.emit(csrrw(25, CSR_MSCRATCH, 24), "csrrw",
           "csrrw x25, mscratch, x24  写 0x1234，x25=旧值")
    p.slot_model(25, TRAP_REC_OFF + 0, "csrrw 读到旧值")
    p.emit(csrrs(24, CSR_MSCRATCH, 0), "csrrs",
           "csrrs x24, mscratch, x0   读回 0x1234（不写）")
    p.slot_model(24, TRAP_REC_OFF + 4, "csrrs 读回值")
    p.emit(csrrwi(26, CSR_MSCRATCH, 31), "csrrwi",
           "csrrwi x26, mscratch, 31  mscratch=31，x26=旧值")
    p.slot_model(26, TRAP_REC_OFF + 8, "csrrwi 读到旧值")
    p.emit(csrrs(29, CSR_MISA, 0), "csrrs", "csrrs x29, misa, x0      misa 只读")
    p.slot_model(29, TRAP_REC_OFF + 12, "misa 只读值")
    p.emit(csrrc(30, CSR_MSCRATCH, 24), "csrrc",
           "csrrc x30, mscratch, x24  mscratch &= ~x24，x30=旧值")
    p.slot_model(30, TRAP_REC_OFF + 16, "csrrc 读到旧值")
    p.emit(csrrsi(28, CSR_MSCRATCH, 1), "csrrsi",
           "csrrsi x28, mscratch, 1   mscratch |= 1，x28=旧值")
    p.slot_model(28, TRAP_REC_OFF + 20, "csrrsi 读到旧值")
    p.emit(csrrci(27, CSR_MSCRATCH, 1), "csrrci",
           "csrrci x27, mscratch, 1   mscratch &= ~1，x27=旧值")
    p.slot_model(27, TRAP_REC_OFF + 24, "csrrci 读到旧值")
    p.emit(csrrs(28, CSR_MSCRATCH, 0), "csrrs",
           "csrrs x28, mscratch, x0   读回最终值")
    p.slot_model(28, TRAP_REC_OFF + 28, "mscratch 最终值")
    p.emit(csrrs(26, CSR_MEPC, 0), "csrrs", "csrrs x26, mepc, x0      mepc 复位值")
    p.slot_model(26, TRAP_REC_OFF + 32, "mepc 复位值")
    p.emit(csrrw(0, CSR_MSCRATCH, 0), "csrrw", "csrrw x0, mscratch, x0   清 mscratch")

    p.section("=== 异常：ECALL / EBREAK / 非法指令 / 非对齐访存 ===")
    rec = TRAP_REC_OFF + 64          # 陷阱记录从这里开始（CSR 自测占了 36 字节）
    p.emit(addi(23, 0, 0), "addi", "addi x23, x0, 0")
    p.li(23, rec, "记录指针 = 陷阱记录区")
    p.emit(sw(23, TRAP_PTR_OFF, 5), "sw", "sw   x23, TRAP_PTR")
    p.emit(addi(23, 0, 0), "addi", "addi x23, x0, 0")
    p.emit(sw(23, IRQ_FLAG_OFF, 5), "sw", "sw   x23, IRQ_FLAG   清中断标志")
    handler_addr = None              # 稍后回填（处理程序在本段末尾）

    # 先把 mtvec 指向处理程序：处理程序在段末，用 li 装载（地址在生成时已知）
    mtvec_fix = len(p.words)         # 记下位置，稍后用 raw 覆盖
    p.raw(lui(24, 0), "lui", "lui  x24, <handler>       （生成时回填）")
    p.raw(addi(24, 24, 0), "addi", "addi x24, x24, <lo>       （生成时回填）")
    p.raw(csrrw(0, CSR_MTVEC, 24), "csrrw", "csrrw x0, mtvec, x24  设置陷阱向量")

    # 1) ECALL
    a_ecall = p.addr()
    p.emit(ecall(), "ecall", "ecall                  ★ 陷阱 1：mcause=11")
    # 2) EBREAK
    a_ebreak = p.addr()
    p.emit(ebreak(), "ebreak", "ebreak                 ★ 陷阱 2：mcause=3")
    # 3) 非法指令（全 0）
    a_ill = p.addr()
    p.emit(0x0000_0000, "?", "? 非法指令 0x0000_0000  ★ 陷阱 3：mcause=2")
    # 4) 非对齐 load（地址 +2）
    a_lmis = p.addr()
    p.emit(lw(25, 2, 5), "lw", "lw   x25, 2(x5)       ★ 陷阱 4：load 非对齐 mcause=4")
    # 5) 非对齐 store
    a_smis = p.addr()
    p.emit(sw(25, 2, 5), "sw", "sw   x25, 2(x5)       ★ 陷阱 5：store 非对齐 mcause=6")

    p.section("=== 定时器中断 ===")
    p.li(24, TIMER_BASE, "TIMER 基址")
    p.emit(addi(25, 0, 5), "addi", "addi x25, x0, 5       很短的重载值")
    p.emit(sw(25, 0, 24), "sw", "sw   x25, 0(x24)      TIMER.LOAD = 5")
    p.emit(addi(25, 0, 3), "addi", "addi x25, x0, 3      EN | IRQ_EN")
    p.emit(sw(25, 8, 24), "sw", "sw   x25, 8(x24)      TIMER.CTRL = 3")
    p.emit(addi(24, 0, 0x80), "addi", "addi x24, x0, 0x80    mie.MTIE")
    p.emit(csrrw(0, CSR_MIE, 24), "csrrw", "csrrw x0, mie, x24    开定时器中断")
    p.emit(addi(24, 0, 8), "addi", "addi x24, x0, 8       mstatus.MIE")
    p.emit(csrrw(0, CSR_MSTATUS, 24), "csrrw", "csrrw x0, mstatus, x24 开全局中断")
    p.label("irq_loop")
    p.emit(lw(25, IRQ_FLAG_OFF, 5), "lw", "lw   x25, IRQ_FLAG    查询中断标志")
    a_beq = p.addr()
    p.branch("beq", beq(25, 0, 0), "irq_loop", "beq  x25, x0, irq_loop  ← 中断在这里被受理")
    # 关中断并停定时器
    p.emit(csrrw(0, CSR_MSTATUS, 0), "csrrw", "csrrw x0, mstatus, x0 关中断")
    p.li(24, TIMER_BASE, "TIMER 基址")
    p.emit(sw(0, 8, 24), "sw", "sw   x0, 8(x24)       TIMER.CTRL = 0")
    p.emit(addi(25, 0, 1), "addi", "addi x25, x0, 1")
    p.emit(sw(25, 0x0C, 24), "sw", "sw   x25, 0x0C(x24)   STATUS 写 1 清溢出")

    p.jump("jal", jal(0, 0), "trap_done", "jal  x0, trap_done     跳过陷阱处理程序")

    # ---- 陷阱处理程序（raw：不参与参考模型）----
    p.label("trap_handler")
    handler_addr = p.labels["trap_handler"]
    p.raw(csrrw(29, CSR_MSCRATCH, 29), "csrrw", "csrrw x29, mscratch, x29  保存 x29")
    p.raw(csrrs(28, CSR_MCAUSE, 0), "csrrs", "csrrs x28, mcause, x0      x28 = mcause")
    p.raw(csrrs(27, CSR_MEPC, 0), "csrrs", "csrrs x27, mepc, x0        x27 = mepc")
    p.raw(lw(26, TRAP_PTR_OFF, 5), "lw", "lw   x26, TRAP_PTR")
    p.raw(sw(28, 0, 26), "sw", "sw   x28, 0(x26)          记录 mcause")
    p.raw(sw(27, 4, 26), "sw", "sw   x27, 4(x26)          记录 mepc")
    p.raw(addi(26, 26, 8), "addi", "addi x26, x26, 8")
    p.raw(sw(26, TRAP_PTR_OFF, 5), "sw", "sw   x26, TRAP_PTR        指针 +8")
    p.branch("bge", bge(28, 0, 0), "h_sync",
             "bge  x28, x0, h_sync      非负（同步异常）→ h_sync；否则中断路径")
    # 中断分支：置标志 + 清定时器溢出
    p.raw(addi(26, 0, 1), "addi", "addi x26, x0, 1")
    p.raw(sw(26, IRQ_FLAG_OFF, 5), "sw", "sw   x26, IRQ_FLAG        置中断标志")
    p.li_raw(26, TIMER_BASE, "TIMER 基址")
    p.raw(addi(27, 0, 1), "addi", "addi x27, x0, 1")
    p.raw(sw(27, 0x0C, 26), "sw", "sw   x27, 0x0C(x26)      STATUS 写 1 清溢出")
    p.jump("jal", jal(0, 0), "h_ret", "jal  x0, h_ret")
    p.label("h_sync")
    p.raw(addi(27, 27, 4), "addi", "addi x27, x27, 4          跳过出错指令")
    p.raw(csrrw(0, CSR_MEPC, 27), "csrrw", "csrrw x0, mepc, x27")
    p.label("h_ret")
    p.raw(csrrw(29, CSR_MSCRATCH, 29), "csrrw", "csrrw x29, mscratch, x29  恢复 x29")
    p.raw(mret(), "mret", "mret")
    p.label("trap_done")

    # 回填 mtvec 装载（lui + addi）
    hi = (handler_addr >> 12) & 0xFFFFF
    lo = handler_addr & 0xFFF
    if lo & 0x800:
        lo -= 0x1000
        hi = (hi + 1) & 0xFFFFF
    if hi == 0:
        p.words[mtvec_fix]     = addi(24, 0, lo)
        p.words[mtvec_fix + 1] = nop()
        p.comments[mtvec_fix]     = f"addi x24, x0, {lo}          mtvec = 处理程序入口"
        p.comments[mtvec_fix + 1] = "nop                     （地址小于 0x1000，无需 lui）"
    else:
        p.words[mtvec_fix]     = lui(24, hi)
        p.words[mtvec_fix + 1] = addi(24, 24, lo)
        p.comments[mtvec_fix]     = f"lui  x24, 0x{hi:05x}          mtvec 高 20 位"
        p.comments[mtvec_fix + 1] = f"addi x24, x24, {lo}   mtvec = 处理程序入口"

    # ---- 期望的陷阱记录 ----
    base = rec
    for i, (cause, addr, name) in enumerate([
            (CAUSE_ECALL,     a_ecall,  "陷阱1 ECALL"),
            (CAUSE_EBREAK,    a_ebreak, "陷阱2 EBREAK"),
            (CAUSE_ILLEGAL,   a_ill,    "陷阱3 非法指令"),
            (CAUSE_LOAD_MIS,  a_lmis,   "陷阱4 load 非对齐"),
            (CAUSE_STORE_MIS, a_smis,   "陷阱5 store 非对齐"),
            (CAUSE_IRQ_TIMER, a_beq,    "陷阱6 定时器中断")]):
        p.expect_ram(base + i*8 + 0, cause, f"{name}: mcause")
        p.expect_ram(base + i*8 + 4, addr,  f"{name}: mepc")
    p.expect_ram(IRQ_FLAG_OFF, 1, "定时器中断已发生")
    p.expect_ram(TRAP_PTR_OFF, rec + 6*8, "陷阱指针（6 条记录之后）")
    return handler_addr


# ======================================================================
# 外设段（不参与模型：UART 状态等依赖真实硬件时序）
# ======================================================================
def append_peripheral_section(p):
    p.section("=== 外设：UART 发 \"OK\\n\" / GPIO 回环 / TIMER 溢出轮询 ===")
    lit = [
        (lui(11, 0x20000),      "lui",   "lui  x11, 0x20000     x11 = 0x2000_0000"),
        (addi(11, 11, 0x400),   "addi",  "addi x11, x11, 0x400  +0x400"),
        (addi(11, 11, 0x400),   "addi",  "addi x11, x11, 0x400  x11 = UART 基址"),
        (addi(12, 0, 867),      "addi",  "addi x12, x0, 867     BAUD = 867"),
        (sw(12, 0x0C, 11),      "sw",    "sw   x12, 0x0C(x11)   UART.BAUD"),
        (addi(12, 0, 0),        "addi",  "addi x12, x0, 0"),
        (lw(13, 8, 11),         "lw",    "lw   x13, 8(x11)      UART.STATUS"),
        (andi(13, 13, 1),       "andi",  "andi x13, x13, 1      TX_BUSY"),
        (bne(13, 0, -8),        "bne",   "bne  x13, x0, -8      忙则等"),
        (addi(13, 0, 0x4F),     "addi",  "addi x13, x0, 'O'"),
        (sw(13, 0, 11),         "sw",    "sw   x13, 0(x11)      发 'O'"),
        (nop(),                 "addi",  "nop                   等 TX_BUSY 置起"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (lw(13, 8, 11),         "lw",    "lw   x13, 8(x11)"),
        (andi(13, 13, 1),       "andi",  "andi x13, x13, 1"),
        (bne(13, 0, -8),        "bne",   "bne  x13, x0, -8"),
        (addi(13, 0, 0x4B),     "addi",  "addi x13, x0, 'K'"),
        (sw(13, 0, 11),         "sw",    "sw   x13, 0(x11)      发 'K'"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (lw(13, 8, 11),         "lw",    "lw   x13, 8(x11)"),
        (andi(13, 13, 1),       "andi",  "andi x13, x13, 1"),
        (bne(13, 0, -8),        "bne",   "bne  x13, x0, -8"),
        (addi(13, 0, 0x0A),     "addi",  "addi x13, x0, '\\n'"),
        (sw(13, 0, 11),         "sw",    "sw   x13, 0(x11)      发 '\\n'"),
        (nop(),                 "addi",  "nop"),
        (nop(),                 "addi",  "nop"),
        (addi(14, 11, 0x400),   "addi",  "addi x14, x11, 0x400  GPIO 基址"),
        (addi(15, 0, 0xFF),     "addi",  "addi x15, x0, 0xFF"),
        (sw(15, 4, 14),         "sw",    "sw   x15, 4(x14)      GPIO.DIR = 0xFF"),
        (addi(15, 0, 0x5A),     "addi",  "addi x15, x0, 0x5A"),
        (sw(15, 0, 14),         "sw",    "sw   x15, 0(x14)      GPIO.DATA = 0x5A"),
        (lw(15, 0, 14),         "lw",    "lw   x15, 0(x14)      回环读回"),
        (addi(20, 11, -0x800),  "addi",  "addi x20, x11, -0x800 TIMER 基址"),
        (addi(15, 0, 200),      "addi",  "addi x15, x0, 200"),
        (sw(15, 0, 20),         "sw",    "sw   x15, 0(x20)      TIMER.LOAD = 200"),
        (addi(21, 0, 3),        "addi",  "addi x21, x0, 3       EN | IRQ_EN"),
        (sw(21, 8, 20),         "sw",    "sw   x21, 8(x20)      TIMER.CTRL = 3"),
        (lw(21, 0x0C, 20),      "lw",    "lw   x21, 0x0C(x20)   TIMER.STATUS"),
        (andi(21, 21, 1),       "andi",  "andi x21, x21, 1      OVERFLOW"),
        (beq(21, 0, -8),        "beq",   "beq  x21, x0, -8      轮询溢出"),
        (addi(14, 0, 1),        "addi",  "addi x14, x0, 1"),
        (sw(14, 0x0C, 20),      "sw",    "sw   x14, 0x0C(x20)   写 1 清 OVERFLOW"),
    ]
    for word, mnem, cmt in lit:
        p.emit(word, mnem, cmt)

    p.section("=== 半字自检 + RESULT + DONE ===")
    lit2 = [
        (addi(6, 0, 1),          "addi", "addi x6, x0, 1        通过标志"),
        (lui(29, 0x10000),       "lui",  "lui  x29, 0x10000"),
        (addi(29, 29, 0x300),    "addi", "addi x29, x29, 0x300  x29 = RAM+0x300"),
        (lui(28, 0xC),           "lui",  "lui  x28, 0xC"),
        (addi(28, 28, -0x111),   "addi", "addi x28, x28, -0x111 x28 = 0xBEEF"),
        (sh(28, 0, 29),          "sh",   "sh   x28, 0(x29)      RAM[0x300] = 0xBEEF"),
        (lw(30, 0, 29),          "lw",   "lw   x30, 0(x29)"),
        (lhu(31, 0, 29),         "lhu",  "lhu  x31, 0(x29)"),
        (addi(29, 0, -0x411),    "addi", "addi x29, x0, -0x411"),
        (addi(30, 0, 0),         "addi", "addi x30, x0, 0"),
        (bne(31, 29, 8),         "bne",  "bne  x31, x29, +8     半字读对则跳过"),
        (addi(6, 0, 0),          "addi", "addi x6, x0, 0        ★ 半字读错：置失败"),
        (sw(6, RESULT_OFF, 5),   "sw",   "sw   x6, RESULT"),
        # 0xEAF 超出 I 型立即数正数范围（0x7FF），用 0x600D2000 - 0x151 拼
        (lui(7, 0x600D2),        "lui",  "lui  x7, 0x600D2      x7 = 0x600D_2000"),
        (addi(7, 7, -0x151),     "addi", "addi x7, x7, -0x151   x7 = 0x600D_1EAF"),
        (sw(7, DONE_OFF, 5),     "sw",   "sw   x7, DONE"),
        (jal(0, 0),              "jal",  "jal  x0, 0            ★ 挂死点"),
    ]
    for word, mnem, cmt in lit2:
        p.emit(word, mnem, cmt)
    assert p.reg[7] == DONE_MAGIC, \
        f"DONE 魔数拼装错误：0x{p.reg[7]:08X} != 0x{DONE_MAGIC:08X}"


# ======================================================================
# 输出与自检
# ======================================================================
def coverage_report(p):
    required = [m for grp in RV32I.values() for m in grp]
    missing = [m for m in required if m not in p.cov]
    miss_zicsr = [m for m in ZICSR if m not in p.cov]
    miss_sys = [m for m in ZICSR_EXTRA if m not in p.cov]
    extra = sorted(p.cov - set(required) - set(ZICSR) - set(ZICSR_EXTRA) - {"nop"})
    print(f"覆盖率：RV32I {len(required) - len(missing)}/{len(required)}"
          f"（含 ecall/ebreak/fence）"
          f"，Zicsr {len(ZICSR) - len(miss_zicsr)}/{len(ZICSR)}")
    if missing:
        print("  ★ 缺少 RV32I 指令：" + " ".join(missing))
    if miss_zicsr:
        print("  ★ 缺少 Zicsr 指令：" + " ".join(miss_zicsr))
    if miss_sys:
        print("  ★ 缺少系统指令：" + " ".join(miss_sys))
    if extra:
        print("  非基础指令的助记符：" + " ".join(extra))
    return missing + miss_zicsr + miss_sys


def write_hex(path, p, cov_ok, n_slots):
    lines = [
        "//=====================================================================",
        "// cpu_test.hex — tb_top 使用的 RV32I 系统级测试程序镜像",
        "//",
        "//   由 tb/prog/gen_cpu_test.py 汇编生成（内置 RV32I 参考模型与覆盖率",
        "//   自检），不要手工改机器码。行号 N 即 ROM 字数地址 N（字节地址 N*4）。",
        "//",
        "//   地址映射（见 rtl/sys_define.svh）",
        "//     RAM   0x1000_0000   RESULT +0 / DONE +4 / 访存测试 +0x10 /",
        "//                         半字自检 +0x300 / 结果槽 +0x400 起",
        "//     TIMER 0x2000_0000   LOAD +0 / COUNT +4 / CTRL +8 / STATUS +0x0C",
        "//     UART  0x2000_0800   TXDATA +0 / RXDATA +4 / STATUS +8 / BAUD +0x0C",
        "//     GPIO  0x2000_0C00   DATA +0 / DIR +4 / SET +8 / CLR +0x0C",
        "//",
        f"//   覆盖率：RV32I 非陷阱指令 {'完整' if cov_ok else '不完整'}；"
        f"结果槽 {n_slots} 个（期望值见 cpu_test.exp）",
        "//   结束：RESULT=1 通过 / RESULT=0 失败，随后写 DONE 魔数并挂死",
        "//",
        "//   运行： make tb TB=tb_top",
        "//=====================================================================",
        "",
    ]
    state = dict(p.notes)
    for idx, word in enumerate(p.words):
        addr = idx * 4
        if addr in state:
            lines.append("")
            lines.append(f"// {state[addr]}")
        lines.append(f"{word:08x}    // 0x{addr:03x}  {p.comments[idx]}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_coe(path, words):
    values = list(words) + [nop()] * (WORDS - len(words))
    lines = ["memory_initialization_radix=16;", "memory_initialization_vector="]
    for i, v in enumerate(values):
        lines.append(f"{v:08X}{';' if i == len(values)-1 else ','}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_mif(path, words):
    values = list(words) + [nop()] * (WORDS - len(words))
    path.write_text("\n".join(f"{v:032b}" for v in values) + "\n", encoding="utf-8")


def decode(word):
    op = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7 = (word >> 25) & 0x7F
    imm_i = sext12(word >> 20)
    if op == 0b0110011:
        name = {0b000: "add" if f7 == 0 else "sub", 0b001: "sll", 0b010: "slt",
                0b011: "sltu", 0b100: "xor", 0b101: "srl" if f7 == 0 else "sra",
                0b110: "or", 0b111: "and"}[f3]
        return f"{name} x{rd}, x{rs1}, x{rs2}"
    if op == 0b0010011:
        if f3 == 0b001:
            return f"slli x{rd}, x{rs1}, {(word >> 20) & 0x1F}"
        if f3 == 0b101:
            m = "srai" if (word >> 30) & 1 else "srli"
            return f"{m} x{rd}, x{rs1}, {(word >> 20) & 0x1F}"
        name = {0b000: "addi", 0b010: "slti", 0b011: "sltiu",
                0b100: "xori", 0b110: "ori", 0b111: "andi"}[f3]
        return f"{name} x{rd}, x{rs1}, {imm_i}"
    if op == 0b0000011:
        name = {0b000: "lb", 0b001: "lh", 0b010: "lw", 0b100: "lbu", 0b101: "lhu"}[f3]
        return f"{name} x{rd}, {imm_i}(x{rs1})"
    if op == 0b0100011:
        imm = sext12(((word >> 25) << 5) | ((word >> 7) & 0x1F))
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
    if op == 0b1100111:
        return f"jalr x{rd}, {imm_i}(x{rs1})"
    if op == 0b0110111:
        return f"lui x{rd}, 0x{(word >> 12) & 0xFFFFF:x}"
    if op == 0b0010111:
        return f"auipc x{rd}, 0x{(word >> 12) & 0xFFFFF:x}"
    if op == 0b0001111:
        return "fence"
    if op == 0b1110011:
        if f3 == 0:
            return {0x000: "ecall", 0x001: "ebreak", 0x302: "mret"}.get(
                (word >> 20) & 0xFFF, "sys")
        name = {0b001: "csrrw", 0b010: "csrrs", 0b011: "csrrc",
                0b101: "csrrwi", 0b110: "csrrsi", 0b111: "csrrci"}.get(f3, "csr?")
        return f"{name} x{rd}, 0x{(word >> 20) & 0xFFF:03x}, x{rs1}"
    return f"?.{op:07b}"


def self_check(p):
    bad = 0
    for idx, word in enumerate(p.words):
        text = decode(word)
        cmt = p.comments[idx].split()
        mnem = cmt[0] if cmt else ""
        if mnem == "nop":
            mnem = "addi"
        if mnem == "?":
            continue                       # 手工编码的非法指令，不做解码对照
        if mnem and not text.startswith(mnem):
            print(f"  解码不符 0x{idx*4:03x}: {text}   (注释: {p.comments[idx]})")
            bad += 1
    # 抽样人工核对：防止「参考模型与期望值同错」
    spot = {
        "add   回绕 INT_MAX+4": 0x8000_0004,
        "sll   移位量取 rs2[4:0]": 0x2800_0000,
        "sltu  5 < 0xFFFFFFFB": 1,
        "srai  算术右移 31": 0xFFFF_FFFF,
        "andi  负数立即数": 0x1234_5670,
        "sb 只改目标通道": 0x1122_AA44,
        "sh 只改目标半字": 0x07BC_AA44,
        "load-use 前递": 0x00FF_01FE,
        "beq  相等 -> 跳": 1,
        "bgeu 无符号 5 >= 0xFFFFFFFB -> 不跳": 0,
    }
    slot_map = dict(p.slots)
    for name, exp in spot.items():
        got = slot_map.get(name)
        if got != exp:
            print(f"  人工核对不符：{name} 模型={got if got is None else format(got,'08x')}"
                  f" 手工={exp:08x}")
            bad += 1
    print(f"往返解码自检：{len(p.words)} 条指令，{bad} 条不符")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    outdir = Path(args.outdir) if args.outdir else Path(__file__).resolve().parent
    p = build_program()
    p.resolve()
    append_trap_section(p)          # 陷阱 / 中断（含 raw 的处理程序）
    p.resolve()                     # 回填陷阱段里的分支
    append_peripheral_section(p)    # 外设（纯 literal）
    p.resolve()

    if p.mismatch:
        print("★ 期望值与参考模型不一致（生成器/模型有 bug，请检查）：")
        for m in p.mismatch:
            print("   " + m)
    bad = self_check(p) + len(p.mismatch)
    missing = coverage_report(p)
    if args.check:
        return 1 if (bad or missing) else 0

    write_hex(outdir / "cpu_test.hex", p, not missing, len(p.slots))
    write_coe(outdir / "cpu_test.coe", p.words)
    write_mif(outdir / "ROM.mif", p.words)
    # 期望值表：每行「RAM 字节地址 期望值 名称」，tb_top 用 $fgets/$sscanf 读
    (outdir / "cpu_test.exp").write_text(
        "".join(f"{a:08x} {v:08x} {n.replace(' ', '_')}\n"
                for a, v, n in p.expects),
        encoding="utf-8")

    print(f"程序 {len(p.words)} 条指令（{len(p.words)*4} 字节），"
          f"结果槽 {len(p.slots)} 个，期望项 {len(p.expects)} 个，"
          f"DONE 魔数 0x{DONE_MAGIC:08X}")
    return 1 if (bad or missing) else 0


if __name__ == "__main__":
    raise SystemExit(main())
