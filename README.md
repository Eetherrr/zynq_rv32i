# zynq_rv32i

基于 **Xilinx Zynq-7000（xc7z010clg400-1）**、使用 **SystemVerilog** 实现的 **RV32I** 处理器工程。

CPU 本体采用经典**五级流水线**（IF / ID / EX / MEM / WB），通过自研的 **RIB（RISC-V Internal Bus）** 片上总线连接指令 ROM、数据 RAM 以及后续要扩展的外设（UART / Timer / GPIO 等）。

> 架构框图见 [`doc/structure/cpu.dio.png`](doc/structure/cpu.dio.png) 与 [`doc/structure/RIB.dio.png`](doc/structure/RIB.dio.png)。

---

## 目录

- [1. 项目概览](#1-项目概览)
- [2. 目录结构](#2-目录结构)
- [3. 整体框架](#3-整体框架)
- [4. 数据流](#4-数据流)
- [5. 开发流程](#5-开发流程)
- [6. 设计要点](#6-设计要点)
- [7. 当前进度](#7-当前进度)
- [8. 许可证](#8-许可证)

---

## 1. 项目概览

| 项目 | 说明 |
| --- | --- |
| 指令集 | RV32I（不含 M / A / F / D 扩展，CSR 未实现） |
| 微架构 | 经典五级流水线，顺序发射、顺序写回 |
| 数据通路 | 32 bit 数据 / 地址，PC 复位向量 `0x0000_0000` |
| 冒险处理 | 全前递（EX/MEM、MEM/WB）+ load-use 停顿一拍 |
| 控制转移 | EX 阶段解析分支 / 跳转，重定向并冲刷错误路径 |
| 片上总线 | RIB：4 主（用 2 预留 2）+ 6 从，固定优先级仲裁 |
| 外设 | ROM / RAM / TIMER / SPI / UART / GPIO（各为独立模块） |
| 目标器件 | `xc7z010clg400-1`（Zynq-7010，CLG400 封装） |
| 顶层模块 | `CPU_SOC_top` |
| 仿真顶层 | `tb_top`（待补充） |
| 开发工具 | Vivado 2022.2 + Makefile + Tcl 脚本 |

---

## 2. 目录结构

```text
zynq_rv32i/
├── Makefile                  # 统一入口：建工程 / 综合 / 实现 / 出位流 / 仿真
├── README.md
├── LICENSE
├── .gitignore                # prj/ 与仿真产物不入库，可由 make 重建
├── constrs/                  # 约束
│   ├── pins.csv              #   引脚表（make pins 生成模板，手工填 Pin 号）
│   └── pins.xdc              #   由 pins.csv 自动生成（勿手改）
├── doc/structure/            # 架构框图（cpu.dio.png / RIB.dio.png）
├── prj/                      # Vivado 工程与运行产物（gitignore，可重建）
├── rtl/                      # 可综合 RTL
│   ├── sys_define.svh        #   全局宏：位宽、指令编码、ALU 编码、控制选择
│   ├── CPU_SOC_top.sv        #   SoC 顶层：CPU + 总线 + 外设
│   ├── Core/                 #   CPU 本体
│   │   ├── CPU_top.sv        #     流水线顶层，连接各级与流水寄存器
│   │   ├── Control.sv        #     冒险检测 / 冲刷 / 停顿 / 重定向
│   │   ├── IF/               #     IF.sv, PCReg.sv, IF2ID.sv
│   │   ├── ID/               #     Decoder.sv, Regs.sv, ID.sv, ID2EX.sv
│   │   ├── EX/               #     EX.sv, ALU.sv, Branch.sv, Jump.sv, EX2MEM.sv
│   │   ├── MEM/              #     MEM.sv, MEM2WB.sv
│   │   └── WB/               #     WB.sv
│   ├── Bus/                  #   片上总线
│   │   ├── RIB_top.sv        #     RIB 顶层（仲裁 + 地址译码 + 从机读回 MUX）
│   │   └── Arbiter.sv        #     固定优先级仲裁器
│   └── Peripheral/           #   外设（每个从机一个模块）
│       ├── ROM.sv            #     指令 ROM   16 KiB @ 0x0000_0000
│       ├── RAM.sv            #     数据 RAM   64 KiB @ 0x1000_0000
│       ├── TIMER.sv          #     定时器            @ 0x2000_0000
│       ├── SPI.sv            #     SPI 主机          @ 0x2000_1000
│       ├── UART.sv           #     串口 8N1          @ 0x2000_2000
│       └── GPIO.sv           #     通用 IO           @ 0x2000_3000
├── scripts/                  # 支撑 Makefile 的 Tcl 脚本
│   ├── create_project.tcl    #   建工程 / 刷新源文件列表 / 由 pins.csv 生成 pins.xdc
│   ├── gen_pins_csv.tcl      #   从顶层端口生成 / 增量更新 pins.csv
│   ├── gen_slang_config.tcl  #   生成 .slang/server.json（LSP 用）
│   ├── build.tcl             #   综合 / 实现 / Bitstream
│   ├── check_rtl.tcl         #   非工程模式的 RTL 语法 / 详细阐述检查
│   ├── run_tb.tcl            #   非工程模式用 xsim 运行测试平台
│   └── sim.tcl               #   工程模式仿真（批处理出 VCD 或 GUI 看波形）
├── sim/                      # 仿真输出（waveform.vcd 等）
├── tb/                       # 测试平台
│   └── tb_rib_periph.sv      #   RIB + 外设集成测试（不含 CPU）
└── .slang/                   # slang-server LSP 配置（gitignore）
```

---

## 3. 整体框架

### 3.1 层次结构

```text
CPU_SOC_top                     ← 顶层：时钟复位、引脚、外设互联
├── CPU_top                     ← 五级流水线 CPU
│   ├── IF   : PCReg, IF, IF2ID
│   ├── ID   : Decoder, Regs, ID, ID2EX
│   ├── EX   : EX, ALU, Branch, Jump, EX2MEM
│   ├── MEM  : MEM, MEM2WB
│   ├── WB   : WB
│   └── Control                 ← 横跨各级的冒险 / 控制单元
├── RIB_top                     ← 片上总线（仲裁 / 译码 / 从机选择）
│   └── Arbiter
└── Peripheral
    ├── ROM  （指令存储器，映射低地址）
    └── RAM  （数据存储器）
```

### 3.2 五级流水线职责

| 级 | 模块 | 职责 | 主要输出 |
| --- | --- | --- | --- |
| **IF** | `PCReg` / `IF` | 产生 PC，取出指令 | `if_pc`、`if_instr` |
| **ID** | `Decoder` / `Regs` / `ID` | 译码、读寄存器堆、生成立即数、选操作数 | 全套控制信号、`id_op1` / `id_op2` |
| **EX** | `EX` / `ALU` / `Branch` / `Jump` | 前递选源、ALU 运算、分支与跳转解析 | `ex_alu_result`、分支/跳转结果与目标 |
| **MEM** | `MEM` | 访存地址对齐、字节通道对齐、字节使能、加载数据扩展 | `mem_addr/wdata/be`、`mem_rdata_ext` |
| **WB** | `WB` | 按 `wb_sel` 选择写回源，写寄存器堆 | `wb_wdata` → `Regs` |

### 3.3 流水线寄存器

| 寄存器 | 功能 | 支持 flush | 支持 stall |
| --- | --- | --- | --- |
| `IF2ID` | 传递 PC 与指令 | ✅（清为 NOP） | ✅（保持） |
| `ID2EX` | 传递控制信号、操作数、立即数、PC | ✅ | 预留 |
| `EX2MEM` | 传递 ALU 结果、store 数据、PC+4、写回控制 | ✅ | 预留 |
| `MEM2WB` | 传递 ALU 结果、加载数据、PC+4、写回控制 | ✅ | 预留 |

flush 时统一写入 `INST_NOP`（`32'h0000_0013`，即 `addi x0,x0,0`），不额外引入 valid 位。

### 3.4 RIB 总线

RIB 采用「多主多从 + 集中仲裁 + 统一地址译码」结构。当前接入 **2 个主机**、**6 个从机**，另预留 2 个主机端口给 DMA / 调试用。

```text
                        ┌──────────────────────────────────────────────┐
  m0 取指端口 ─────────►│                                              │
  m1 数据端口 ─────────►│  Arbiter      主机侧 MUX      地址译码        │──► s_rom   ──► ROM
  m2 预留     ─────────►│ (固定优先级)   (grant 选择)   (BASE/MASK)     │──► s_ram   ──► RAM
  m3 预留     ─────────►│                                              │──► s_timer ──► TIMER
                        │        ▲                   从机读回 MUX      │──► s_spi   ──► SPI
                        │        └──────────── grant_id ───────────────│──► s_uart  ──► UART
                        └──────────────────────────────────────────────┘──► s_gpio  ──► GPIO
```

**主机端口**（每个主机一组）

| 信号 | 方向 | 说明 |
| --- | --- | --- |
| `mN_addr` | → RIB | 字节地址 |
| `mN_wdata` | → RIB | 写数据（已按字节通道对齐） |
| `mN_req` | → RIB | 总线请求 |
| `mN_we` / `mN_re` | → RIB | 写 / 读使能 |
| `mN_size` | → RIB | 访问宽度（`MSZ_B` / `MSZ_H` / `MSZ_W`） |
| `mN_rdata` | ← RIB | 读回数据 |

**从机端口**（每个从机一组）：`s_X_sel` 片选、`s_X_req` 门控后的请求、`s_X_addr/wdata/size/we/re`，以及回送的 `s_X_rdata`。

**工作过程**

1. **仲裁**（`Arbiter.sv`）：收集 `{m3_req, m2_req, m1_req, m0_req}`，按固定优先级 `m0 > m1 > m2 > m3` 扫描，命中即停，输出独热 `grant`、`valid` 与二进制 `grant_id`；无请求时 `grant = 0`、`valid = 0`。
2. **主机侧 MUX**：按 `grant` 把被授权主机的 `addr / wdata / we / re / size` 送到共享从机通路。**同一时刻只有一路主机驱动总线**，无需三态。
3. **地址译码**：`s_X_sel = ((addr & X_MASK) == X_BASE)`，掩码与基址集中在 `sys_define.svh`。
4. **请求门控**：`s_X_req = valid & s_X_sel`，保证只有被选中的从机收到请求，避免未命中从机被误写。
5. **读回 MUX**：先按片选从 6 个从机中选出 `bus_rdata`，再按 `grant_id` 回送给被授权的主机。

**时序模型**：全组合读通路，取指与访存都在**单周期**内完成，与 `MEM` 阶段「读写同拍返回」的假设一致。若将来某个从机需要多个周期，应由该从机拉高 CPU 的 `hold_flag_i` 冻结流水线，而不是在 RIB 内引入 `valid/ready` 状态机。

> 实现现状：`CPU_top` 未把 `mem_size` 引出到端口，`CPU_SOC_top` 由 `ram_be_o`
> （4 位字节使能）反推出访问宽度——`MEM` 保证 `be` 是连续若干位（B → 1 位、
> H → 2 位、W → 4 位），因此可无歧义还原为 `MSZ_B / MSZ_H / MSZ_W`，字节与
> 半字访问已是完整功能。待 `CPU_top` 增加 `size` 输出后，把 `cpu_size` 换成
> 该端口即可省掉这层推导。

**地址映射**（定义于 `rtl/sys_define.svh`）

| 从机 | 基址 | 掩码 | 容量 | 内部偏移掩码 | 典型访问者 |
| --- | --- | --- | --- | --- | --- |
| ROM | `0x0000_0000` | `0xFFFF_C000` | 16 KiB | `0x0000_3FFF` | m0（取指），也可由 m1 读常量 |
| RAM | `0x1000_0000` | `0xFFFF_0000` | 64 KiB | `0x0000_FFFF` | m1（数据） |
| TIMER | `0x2000_0000` | `0xFFFF_FC00` | 1 KiB | `0x0000_03FF` | m1 |
| SPI | `0x2000_0400` | `0xFFFF_FC00` | 1 KiB | `0x0000_03FF` | m1 |
| UART | `0x2000_0800` | `0xFFFF_FC00` | 1 KiB | `0x0000_03FF` | m1 |
| GPIO | `0x2000_0C00` | `0xFFFF_FC00` | 1 KiB | `0x0000_03FF` | m1 |

**为什么需要「内部偏移掩码」**：如果从机直接用总线地址索引存储（例如
`mem[addr[31:2]]`），那么挂在 `0x1000_0000` 的 RAM 就需要 64 MB 存储才能覆盖
自己的地址窗口。RIB 因此把地址裁成从机内部偏移后再送下去：

```text
   总线地址 0x1000_0010  →  (addr & RAM_ALIAS_MASK) = 0x0000_0010  →  mem[4]
```

这样从机只需实现真实容量（RAM 16K 字），基址可以任意放置。

> 未映射地址读回 `0`，写被丢弃。后续新增从机只需：在 `sys_define.svh` 加一组
> `BASE / MASK / ALIAS_MASK`，在 RIB 加一组端口与译码，并在顶层例化。

### 3.5 地址空间总览

```text
0x0000_0000 ┌──────────────────────────┐
            │ ROM  16 KiB（指令）       │
0x0000_4000 ├──────────────────────────┤
            │          未映射           │
0x1000_0000 ├──────────────────────────┤
            │ RAM  64 KiB（数据）       │
0x1001_0000 ├──────────────────────────┤
            │          未映射           │
0x2000_0000 ├──────────────────────────┤
            │ TIMER 1 KiB              │
0x2000_0400 ├──────────────────────────┤
            │ SPI   1 KiB              │
0x2000_0800 ├──────────────────────────┤
            │ UART  1 KiB              │
0x2000_0C00 ├──────────────────────────┤
            │ GPIO  1 KiB              │
0x2000_1000 └──────────────────────────┘
```

### 3.6 外设寄存器映射

各外设按字对齐编址，偏移相对各自基址；`sel` 为片选，`we` / `re` 由 RIB 给出。

#### TIMER — `0x2000_0000`（偏移 0x00 ~ 0x0C）

| 偏移 | 名称 | 属性 | 说明 |
| --- | --- | --- | --- |
| `0x00` | `LOAD` | RW | 计数初值 / 重载值 |
| `0x04` | `COUNT` | R | 当前计数值 |
| `0x08` | `CTRL` | RW | bit0 `EN` 使能，bit1 `IRQ_EN` 溢出中断使能，bit2 `ONESHOT` 单次模式 |
| `0x0C` | `STATUS` | RW | bit0 `OVERFLOW` 溢出标志（写 1 清除） |

计数器从 `LOAD` 递减，减到 0 时置 `OVERFLOW` 并产生中断（`irq_o`），随后按 `ONESHOT` 决定停止或自动重载。写入 `CTRL` 且 `EN` 由 0 变 1 时，把 `LOAD` 装入 `COUNT`。

#### SPI — `0x2000_0400`（偏移 0x00 ~ 0x10）

| 偏移 | 名称 | 属性 | 说明 |
| --- | --- | --- | --- |
| `0x00` | `TXDATA` | RW | 发送数据（低 8 位） |
| `0x04` | `RXDATA` | R | bit[7:0] 接收数据，bit8 `READY`，bit9 `TX_BUSY` |
| `0x08` | `CTRL` | RW | bit0 `EN`，bit1 `START` 启动传输，bit2 `CPOL`，bit3 `CPHA`，bit4 `CS` |
| `0x0C` | `DIV` | RW | SCLK 半周期 = `DIV+1` 个 `clk_sys` |
| `0x10` | `STATUS` | RW | bit0 `BUSY`，bit1 `DONE`（写 1 清除） |

8 bit、MSB first，支持 Mode 0~3（由 `CPOL` / `CPHA` 决定采样与移位边沿）。`SS_N` 在传输期间必拉低，空闲时跟随 `CTRL[4]`。

#### UART — `0x2000_0800`（偏移 0x00 ~ 0x0C）

| 偏移 | 名称 | 属性 | 说明 |
| --- | --- | --- | --- |
| `0x00` | `TXDATA` | RW | 写低 8 位即启动一次发送；读回上次发送数据 |
| `0x04` | `RXDATA` | R | bit[7:0] 接收数据，bit8 `READY`，bit9 `TX_BUSY` |
| `0x08` | `STATUS` | RW | bit0 `TX_BUSY`，bit1 `RX_READY`（写 1 清除） |
| `0x0C` | `BAUD` | RW | 位周期 = `BAUD+1` 个 `clk_sys`，`BAUD = clk/baud - 1` |

8N1、无校验、无流控。复位默认 `BAUD = 867`（对应 100 MHz / 115200 bps）。

#### GPIO — `0x2000_0C00`（偏移 0x00 ~ 0x10）

| 偏移 | 名称 | 属性 | 说明 |
| --- | --- | --- | --- |
| `0x00` | `DATA` | RW | 读引脚电平；写输出数据寄存器（仅对输出引脚生效） |
| `0x04` | `DIR` | RW | 1 = 输出，0 = 输入（复位后全为输入） |
| `0x08` | `SET` | W | 写 1 置位对应输出位（原子操作，读回 0） |
| `0x0C` | `CLR` | W | 写 1 清零对应输出位（原子操作，读回 0） |
| `0x10` | `IN` | R | 只读引脚电平 |

顶层把 `gpio_t`（方向）作为三态门使能引出，由 `IOBUF` 等实现真正的双向引脚。所有寄存器写入都按 `size` 做字节使能掩码，支持 `SB` / `SH` / `SW`。

---

## 4. 数据流

### 4.1 指令数据流（主通路）

```text
        ┌──────────────────────────────── 重定向 / 冲刷 ────────────────────────────────┐
        │                                                                              │
        ▼                                                                              │
   ┌─────────┐  ┌────────┐  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   │
   │  PCReg  │─►│ IF2ID  │─►│   ID    │──►│  ID2EX   │──►│  EX2MEM  │──►│  MEM2WB  │   │
   │   PC    │  │        │  │ Decoder │   │          │   │          │   │          │   │
   └─────────┘  └────────┘  │  Regs   │   │   EX     │   │   MEM    │   │    WB    │   │
        ▲                   └─────────┘   │ ALU/Br/  │   │ 对齐/扩展 │   │ 写回选择  │   │
        │                                 │  Jump    │   └────┬─────┘   └────┬─────┘   │
        │                                 └────┬─────┘        │              │         │
        │                                      │              ▼              ▼         │
        │                                      │         RIB / RAM      Regs 写端口    │
        │                                      │              │              │         │
        │                                      └──────────────┼──────────────┘         │
        │                                        分支/跳转目标 │                        │
        └──────────────────────────────────────────────────────┴────────────────────────┘
```

**逐级说明：**

1. **IF**：`PCReg` 输出 `pc`，`IF` 将其直接作为 ROM 地址；ROM 返回的指令与 PC 一起锁入 `IF2ID`。
2. **ID**：`Decoder` 从指令译出寄存器号、立即数、ALU 操作、访存控制、分支/跳转类型及异常标志；`Regs` 组合读出 `rs1/rs2`（对 x0 恒为 0，且支持与 WB 同拍写读穿透）；`ID` 按 `op1_sel` / `op2_sel` 选出 `op1` / `op2`。
3. **EX**：`EX` 先做前递选源（EX/MEM 优先，其次 MEM/WB），再送入 `ALU` 运算、`Branch` 判条件、`Jump` 算目标。分支条件与跳转在该级**解析完毕**。
4. **MEM**：`MEM` 用 ALU 结果作访存地址，完成对齐检查、store 数据搬移到正确字节通道、生成 `be`；读回数据按 `mem_size` + `mem_unsigned` 做截取与符号/零扩展。
5. **WB**：`WB` 按 `wb_sel` 在 ALU 结果 / 加载数据 / PC+4（JAL、JALR 的返回地址）中选择，写回 `Regs`。

### 4.2 操作数前递路径

```text
   EX/MEM 级 ─── alu_result ──┐
                              ├─► 前递 MUX ─► ALU / Branch / Jump 操作数
   MEM/WB 级 ─── wb_wdata ────┘
                    ▲
                    └── 也直接进入 Regs 写端口（WB）
```

- 优先级：**EX/MEM > MEM/WB > 寄存器堆读出值**。
- `ex_mem_mem_read` 为 1（EX/MEM 是 load）时**禁止**该路前递，因为此时 `alu_result` 是地址而非数据。
- `rd_addr == x0` 或 `rd_we == 0` 时前递不生效。

### 4.3 冒险与控制流

`Control` 单元集中产生冲刷、停顿与重定向信号：

| 事件 | 检测 | 动作 |
| --- | --- | --- |
| load-use 冒险 | EX 级是 load 且目的寄存器被 ID 级指令使用 | `stall_pc` + `stall_if2id` 一拍；`flush_id2ex` 插入气泡 |
| 分支/跳转 | EX 级 `branch_taken` 或 `jump_taken` | 冲刷 IF/ID、ID/EX、EX/MEM；`redirect_en` 装载目标 PC |
| 异常 | EX 级 `illegal` / `ecall` / `ebreak` | 与分支同样冲刷重定向；`exception_en` 置起（异常处理待接入） |

- 冲刷下游流水寄存器为 NOP，保证错误路径指令不写回、不访存。
- WB 级不需要 flush（`flush_mem2wb` 恒 0）。
- `hold_flag_i` 由外设（如 UART）拉高时冻结 PC，实现总线等待。

### 4.4 访存数据流（经 RIB）

```text
   MEM 产生 mem_addr / mem_wdata / mem_be / mem_req / mem_we
        │
        ▼
   CPU_top 映射为 RAM 端口（ram_addr_o / ram_data_o / ram_be_o / ram_we_o / ram_re_o）
        │
        ▼
   RIB：仲裁 → 地址译码 → 选中从机 → 读数据 MUX 回送
        │
        ▼
   ram_data_i 回到 MEM → mem_rdata_ext → MEM2WB → WB → Regs
```

- 当前 `MEM` 假定**单周期数据存储器**（读写同拍返回）；若对接带 `valid/ready` 的 RIB 从机，需在顶层做握手适配，并在未就绪时用 `hold_flag_i` 冻结流水线。

---

## 5. 开发流程

### 5.1 环境要求

- **Vivado 2022.2**（`vivado` 需在 `PATH` 中，可用 `VIVADO=...` 覆盖）
- GNU Make
- 可选：slang-server（VS Code / 编辑器 LSP 语法检查，由 `make slang` 生成配置）

### 5.2 快速开始

```bash
# 1) 创建 Vivado 工程（仅首次，之后可跳过）
make project

# 2) 生成引脚模板并填写实际引脚
make pins
vim constrs/pins.csv        # 把 Pin 列的 TODO 换成实际管脚号

# 3) 综合 + 实现 + 生成 Bitstream
make bitstream              # 等价于 make / make all
```

> `make refresh` 会重新扫描 `rtl/`、`constrs/`、`tb/` 并刷新源文件列表，同时由 `pins.csv` 生成 `pins.xdc`。`synth` / `impl` / `bitstream` / `sim` 都会先自动执行 `refresh`。

### 5.3 常用命令

| 命令 | 说明 |
| --- | --- |
| `make` / `make all` / `make bitstream` | 综合 + 实现 + Bitstream |
| `make project` | 仅在 `.xpr` 不存在时创建 Vivado 工程 |
| `make refresh` | 刷新源文件列表，并由 `pins.csv` 生成 `pins.xdc` |
| `make check` | 非工程模式的 RTL 语法 / 详细阐述检查（快速） |
| `make tb` | 非工程模式用 xsim 运行测试平台（默认 `tb_rib_periph`） |
| `make pins` | 从顶层端口生成 / 增量更新 `constrs/pins.csv` |
| `make synth` | 仅综合 |
| `make impl` | 仅实现 |
| `make sim` | 仿真，输出 `sim/waveform.vcd` |
| `make sim WAVE=1` | 仿真并打开波形查看器（GUI） |
| `make sim SIM_RUN=10us` | 指定仿真时长（默认 `all`） |
| `make gui` | 用 Vivado GUI 打开工程 |
| `make slang` | 生成 `.slang/server.json`（LSP 配置） |
| `make clean` | 清理仿真产物 |
| `make distclean` | 清理全部产物（含 Vivado 工程） |
| `make help` | 查看目标列表 |

### 5.4 可覆盖变量

```bash
make bitstream DEVICE=xc7z020clg400-1   # 换器件
make bitstream TOP=CPU_SOC_top          # 换综合顶层
make sim TB_TOP=tb_top                  # 换仿真顶层（工程模式）
make tb TB=tb_rib_periph                # 换测试平台（非工程模式）
make bitstream JOBS=16                  # 并行任务数（默认 8）
make bitstream VIVADO=/path/to/vivado   # 指定 Vivado 可执行文件
```

### 5.5 引脚约束工作流

```text
make pins                       →  从顶层端口生成 constrs/pins.csv（Pin 列填 TODO）
        ↓
编辑 constrs/pins.csv            →  填入实际管脚号与 IOSTANDARD
        ↓
make synth（自动 refresh）       →  create_project.tcl 由 CSV 生成 pins.xdc 并加入工程
```

- `pins.xdc` **自动生成，请勿手动编辑**；所有引脚改动都改 `pins.csv`。
- `gen_pins_csv.tcl` 是**增量**的：已有引脚值会被保留，只增删端口对应的行。
- 总线的 CSV 写法为逐位展开，例如 `data[7:0]` → `data[7] … data[0]`。
- `Pin` 列留 `TODO` 的端口不会生成约束，仅在 `pins.xdc` 中留一条注释。

### 5.6 验证方式

本项目提供两级、互不依赖的快速验证手段，写 RTL 时可以先用它们自检，不必每次都跑综合。

#### 1）RTL 语法 / 详细阐述检查

```bash
make check
```

`scripts/check_rtl.tcl` 在**内存工程**里读入 `rtl/` 下全部源文件并 elaborate
`CPU_SOC_top`，几秒内就能发现语法错误、端口不匹配、位宽不符、多重驱动等问题。
输出以 `0 Errors encountered` 结尾即为通过。

#### 2）单元 / 集成测试平台

```bash
make tb                      # 默认运行 tb_rib_periph（RIB + 外设，不含 CPU）
make tb TB=<其它测试平台名>
```

`scripts/run_tb.tcl` 会把 `rtl/` 与 `tb/` 一起交给 xsim 运行到 `$finish`，
`$display` 直接打印到终端，便于脚本化回归。

现有测试平台 `tb_rib_periph.sv` 用一个「假主机」驱动 RIB 的 m1 端口，覆盖：

| 分组 | 覆盖点 |
| --- | --- |
| 地址译码 | 6 个从机各自片选、未映射地址无片选 |
| RAM | 字写 + 读回、字节写（仅改目标字节通道）、半字写 |
| GPIO | DIR 复位值 / 写、DATA 回环、SET / CLR 原子操作 |
| TIMER | 启动装载、计数递减、溢出置位、写 1 清除 |
| UART / SPI | BAUD / DIV / TXDATA 寄存器写读 |
| SPI | `EN|START` 启动一次 8 bit 传输、BUSY 归零、DONE 置位 |

共 25 项检查，预期输出以 `==> ALL TESTS PASSED` 结尾。

> 注意：`make tb` 使用 xsim，xsim 需要可写的 `/dev/shm`；在容器等受限环境中
> 若报 `shm_open: Permission denied`，需放开该目录权限或改用其它仿真器。

### 5.7 工程模式仿真流程

```bash
make sim                # 批处理：跑完输出 sim/waveform.vcd，可用 GTKWave 打开
make sim WAVE=1         # GUI：启动 Vivado 波形查看器交互调试
```

1. 在 `tb/` 下编写测试平台，顶层模块名需为 `tb_top`（可用 `TB_TOP=` 覆盖）。
2. `make sim` 会先 `refresh` 把 TB 加入 `sim_1` 文件集。
3. Vivado 以 `xsim` 运行，`SIM_RUN` 控制运行时长（默认 `all`）。
4. 批处理模式下通过 `xsim.simulate.xsim.more_options = -vcd <path>` 导出 VCD。

### 5.8 典型开发迭代

```text
改 RTL  →  make check         （秒级语法 / 连线自检）
        →  make tb            （功能回归，看 $display）
        →  make synth         （综合，看时序与资源报告）
        →  make impl          （布局布线）
        →  make bitstream     （出 .bit，下载到板子）
```

> 位流路径：`prj/zynq_rv32i.runs/impl_1/CPU_SOC_top.bit`

---

## 6. 设计要点

- **宏集中管理**：所有位宽、指令编码、ALU 操作码、`op1_sel` / `op2_sel` / `wb_sel`、寄存器号别名均定义在 `rtl/sys_define.svh`，各模块通过相对路径 `` `include `` 引入，**新增文件请沿用相对路径**。
- **x0 处理**：寄存器堆写入忽略 x0，读出恒为 0；前递逻辑同样排除 x0。
- **流水寄存器风格**：`if (rst) … else if (flush) … else if (!stall) …`，优先级固定为「复位 > 冲刷 > 停顿」。
- **分支在 EX 解析**：不采用 ID 级提前解析，因此分支代价为 2 个气泡（冲刷 IF/ID 与 ID/EX）；后续可优化到 ID 级。
- **复位极性**：`rst_async` 低有效，经 `CPU_SOC_top` 同步为 `rst_sys`（`RESET_EN = 1'b0` 表示复位有效）。
- **PC 复位向量**：`PC_RESET = 32'h0000_0000`，可按需调整。
- **代码风格**：RTL 使用 SystemVerilog（`logic` / `always_comb` / `always_ff`），Vivado 工程 `target_language` 设为 Verilog，但 `.sv` / `.svh` 单独指定为 SystemVerilog 文件类型。

---

## 7. 当前进度

### ✅ 已完成

**CPU 本体**

- 五级流水线骨架：IF / ID / EX / MEM / WB 各级与全部流水寄存器。
- 完整 RV32I 译码：R / I / S / B / U / J 型，`LUI`、`AUIPC`、`JAL`、`JALR`、`FENCE`、`ECALL`、`EBREAK` 及非法指令标志。
- ALU 十种运算、分支六种条件、跳转目标计算。
- 全前递 + load-use 停顿的冒险处理，分支/跳转/异常冲刷重定向。
- 寄存器堆（x0 硬连线、写穿透读）。
- 访存对齐检查、字节通道对齐、字节使能生成、加载数据符号/零扩展。

**总线与外设**

- `rtl/Bus/Arbiter.sv`：固定优先级仲裁器（`m0 > m1 > m2 > m3`），输出独热 `grant` 与 `grant_id`。
- `rtl/Bus/RIB_top.sv`：4 主机 / 6 从机互联——仲裁、主机侧 MUX、地址译码、请求门控、读数据 MUX、内部偏移裁剪全部完成。
- 6 个从机模块：`ROM`（16 KiB）、`RAM`（64 KiB）、`TIMER`、`SPI`（Mode 0~3）、`UART`（8N1）、`GPIO`（双向 + SET/CLR 原子操作）；RAM/ROM 按 `size` 做 B/H/W 字节通道选择，外设寄存器写入按 `size` 做字节使能掩码。
- `rtl/CPU_SOC_top.sv`：CPU 与 RIB / 外设 / 引脚的完整连线，含复位同步与定时器中断接入。
- 地址映射与 `*_ALIAS_MASK` 内部偏移机制（见 3.4 节）。

**流程与验证**

- Makefile + Tcl 脚本：建工程 / 引脚 CSV 增量生成 / 综合实现 / 仿真 / LSP 配置。
- `make check`：非工程模式 RTL 详细阐述检查，当前 **0 Errors**。
- `make tb`：非工程模式 xsim 回归；`tb/tb_rib_periph.sv` 覆盖地址译码、RAM（含字节/半字写）、GPIO、TIMER、SPI、UART 共 **25 项检查，全部通过**。

### 🚧 进行中 / 待完成

- **CPU 测试平台**：`tb/` 目前只有外设测试。尚缺 CPU 功能测试（需要指令 ROM 镜像 + `tb_top`），指令级回归尚未建立。
- **单周期访存模型**：RIB 与从机均为组合读通路，假设访存/取指同拍返回。若接入需要等待的从机（或使用块 RAM 的同步读），需要拉高 `hold_flag_i` 冻结流水线，并相应改造 `MEM` 阶段的握手。
- **`mem_size` 未引出**：`CPU_SOC_top` 目前由 `ram_be_o` 反推访问宽度；建议后续在 `CPU_top` 增加 `size` 输出端口并直接使用。
- **异常与中断**：`exception_en` 已产生但未接入异常处理（无 mcause/mepc/CSR）；`mem_align_err` 未上报到 `Control`；`int_i` 已接定时器中断，但 CPU 侧尚无中断响应逻辑，CSR 未实现。
- **外设增强**：UART 接收未做多数表决与起始位二次确认；SPI 为单字节、单从机、无 FIFO/DMA；GPIO 宽度固定 8 位；尚无 I²C、PWM、SD 等。
- **CPU 微架构优化**：分支在 EX 解析（代价 2 气泡），可前移到 ID；无分支预测；无总线超时/错误响应。
- **板级**：`constrs/pins.csv` 与 `pins.xdc` 尚未生成（需要按实际开发板填引脚），时序收敛与上板验证未做。
- **占位端口**：`CPU_SOC_top` 中 RIB 的 m2 / m3 主机端口已预留但未使用（规划给 DMA / 调试）。

---

## 8. 许可证

本项目采用 [MIT License](LICENSE) 开源。
