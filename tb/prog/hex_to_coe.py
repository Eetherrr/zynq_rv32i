#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hex_to_coe.py
将 HEX 文件转换为 Xilinx COE 文件。

支持：
1. 纯文本 HEX：
   例如：
      00
      01
      FF
   或：
      00 01 FF
      0x00, 0x01, 0xFF

2. Intel HEX：
   以 ':' 开头的标准 Intel HEX 文件。

用法：
   python hex_to_coe.py input.hex output.coe
   python hex_to_coe.py input.hex output.coe --width 8
   python hex_to_coe.py input.hex output.coe --radix 16
"""

import argparse
import re
from pathlib import Path


def parse_intel_hex(text: str):
    """解析 Intel HEX，返回按地址从 0 到最大地址排列的字节列表，空缺填 0。"""
    data = {}
    base = 0
    max_addr = -1

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue

        if not line.startswith(":"):
            raise ValueError(f"第 {lineno} 行不是有效的 Intel HEX 记录: {raw!r}")

        if len(line) < 11:
            raise ValueError(f"第 {lineno} 行太短: {raw!r}")

        try:
            raw_bytes = bytes.fromhex(line[1:])
        except ValueError as e:
            raise ValueError(f"第 {lineno} 行包含非法十六进制字符: {raw!r}") from e

        if len(raw_bytes) < 5:
            raise ValueError(f"第 {lineno} 行记录长度不足: {raw!r}")

        byte_count = raw_bytes[0]
        if len(raw_bytes) != 5 + byte_count:
            raise ValueError(f"第 {lineno} 行长度与字节数不匹配: {raw!r}")

        # Intel HEX 校验和：所有字节之和应为 0
        if (sum(raw_bytes) & 0xFF) != 0:
            raise ValueError(f"第 {lineno} 行校验和错误: {raw!r}")

        addr = (raw_bytes[1] << 8) | raw_bytes[2]
        rec_type = raw_bytes[3]
        payload = raw_bytes[4:4 + byte_count]

        if rec_type == 0x00:  # 数据记录
            full_addr = base + addr
            for i, b in enumerate(payload):
                data[full_addr + i] = b
                if full_addr + i > max_addr:
                    max_addr = full_addr + i

        elif rec_type == 0x01:  # EOF
            break

        elif rec_type == 0x02:  # 扩展段地址
            if len(payload) != 2:
                raise ValueError(f"第 {lineno} 行扩展段地址记录长度错误")
            base = int.from_bytes(payload, "big") << 4

        elif rec_type == 0x04:  # 扩展线性地址
            if len(payload) != 2:
                raise ValueError(f"第 {lineno} 行扩展线性地址记录长度错误")
            base = int.from_bytes(payload, "big") << 16

        elif rec_type in (0x03, 0x05):
            # 起始地址记录，忽略
            pass

        else:
            # 未知类型，忽略
            pass

    if max_addr < 0:
        return []

    return [data.get(i, 0) for i in range(max_addr + 1)]


def parse_text_hex(text: str):
    """解析纯文本 HEX，返回整数列表和最大十六进制位数。"""
    values = []
    max_digits = 0

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue

        # 去掉常见注释：#、//、;
        line = re.split(r"//|#|;", line, maxsplit=1)[0].strip()
        if not line:
            continue

        # 支持空格、逗号分隔
        tokens = re.split(r"[\s,]+", line)
        for token in tokens:
            token = token.strip()
            if not token:
                continue

            if token.lower().startswith("0x"):
                digits = token[2:]
            else:
                digits = token

            if not re.fullmatch(r"[0-9a-fA-F]+", digits):
                raise ValueError(f"第 {lineno} 行存在非法十六进制数: {token!r}")

            values.append(int(digits, 16))
            max_digits = max(max_digits, len(digits))

    return values, max_digits


def write_coe(path: str, values, width=None, radix=16):
    """写出 COE 文件。"""
    if radix == 16:
        radix_line = 16
        if width is None:
            max_val = max(values) if values else 0
            width = max(2, len(f"{max_val:X}"))
            if width % 2:
                width += 1
        fmt = f"{{:0{width}X}}"

    elif radix == 10:
        radix_line = 10
        fmt = "{}"

    elif radix == 2:
        radix_line = 2
        if width is None:
            max_val = max(values) if values else 0
            width = max(1, max_val.bit_length())
        fmt = f"{{:0{width}b}}"

    else:
        raise ValueError("radix 只支持 2、10、16")

    lines = [
        f"memory_initialization_radix={radix_line};",
        "memory_initialization_vector=",
    ]

    n = len(values)
    for i, v in enumerate(values):
        sep = ";" if i == n - 1 else ","
        lines.append(fmt.format(v) + sep)

    if n == 0:
        lines[-1] += ";"

    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="将 HEX 文件转换为 Xilinx COE 文件")
    parser.add_argument("input", help="输入 .hex 文件")
    parser.add_argument("output", help="输出 .coe 文件")
    parser.add_argument(
        "--width",
        type=int,
        default=None,
        help="输出每个值的位宽，例如 2、4、8。默认自动判断",
    )
    parser.add_argument(
        "--radix",
        type=int,
        choices=[2, 10, 16],
        default=16,
        help="COE 的 radix，默认 16",
    )
    parser.add_argument(
        "--force-text",
        action="store_true",
        help="强制按纯文本 HEX 解析",
    )
    parser.add_argument(
        "--force-intel",
        action="store_true",
        help="强制按 Intel HEX 解析",
    )

    args = parser.parse_args()

    text = Path(args.input).read_text(encoding="utf-8", errors="ignore")

    is_intel = args.force_intel or (
        not args.force_text
        and any(line.strip().startswith(":") for line in text.splitlines())
    )

    if is_intel:
        values = parse_intel_hex(text)
        if args.width is None:
            args.width = 2  # Intel HEX 按字节输出
    else:
        values, max_digits = parse_text_hex(text)
        if args.width is None:
            args.width = max(2, max_digits)
            if args.radix == 16 and args.width % 2:
                args.width += 1

    write_coe(args.output, values, width=args.width, radix=args.radix)
    print(f"已写入 {args.output}，共 {len(values)} 个值。")


if __name__ == "__main__":
    main()
