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
| 结构 | **哈佛结构**：指令 ROM 与数据 RAM 分离 |
| 数据通路 | 32 bit 数据 / 地址，PC 复位向量 `0x0000_0000` |
| 冒险处理 | 全前递：EX/MEM（load 直接前递数据）+ MEM/WB，**load-use 无需停顿** |
| 控制转移 | EX 阶段解析分支 / 跳转，重定向并冲刷错误路径 |
| 片上总线 | RIB：4 主（用 2 预留 2）+ 6 从，固定优先级仲裁 |
| 存储器 | **Block Memory Generator IP**：ROM 16 KiB / RAM 64 KiB，读延迟 1 拍（地址在 EX 级提前发起） |
| 外设 | TIMER / SPI / UART / GPIO（各为独立模块） |
| 目标器件 | `xc7z010clg400-1`（Zynq-7010，CLG400 封装） |
| 顶层模块 | `CPU_SOC_top` |
| 验证状态 | 模块级 9 个测试平台 **333 项** + RIB/外设 **25 项** + SoC 顶层 **26 项**，全部通过（见 [5.6](#56-验证方式) / [7](#7-当前进度)） |
| 开发工具 | Vivado 2022.2 + Makefile + Tcl 脚本 |

---

## 2. 目录结构

```text
zynq_rv32i/
├── Makefile                  # 统一入口：建工程 / 综合 / 实现 / 出位流 / 仿真 / 单模块验证
├── README.md
├── LICENSE
├── .gitignore                # prj/ 与仿真产物不入库，可由 make 重建
├── constrs/                  # 约束
│   ├── pins.csv              #   引脚表（make pins 生成模板，手工填 Pin 号）
│   └── pins.xdc              #   由 pins.csv 自动生成（勿手改）
├── doc/structure/            # 架构框图（cpu / RIB / instruction_fetch）
├── prj/                      # Vivado 工程与运行产物（gitignore，可重建）
│   └── *.srcs/sources_1/ip/  #   Block Memory Generator IP（ROM / RAM）
├── rtl/                      # 可综合 RTL
│   ├── sys_define.svh        #   全局宏：位宽、指令编码、ALU 编码、地址映射
│   ├── CPU_SOC_top.sv        #   SoC 顶层：CPU + 总线 + 外设
│   ├── Core/                 #   CPU 本体
│   │   ├── CPU_top.sv        #     流水线顶层，连接各级与流水寄存器
│   │   ├── Control.sv        #     冒险检测 / 冲刷 / 停顿 / 重定向
│   │   ├── IF/               #     IF.sv, PCReg.sv, IF2ID.sv
│   │   ├── ID/               #     Decoder.sv, Regs.sv, ID.sv, ID2EX.sv
│   │   ├── EX/               #     EX.sv, ALU.sv, Branch.sv, Jump.sv, EX2MEM.sv
│   │   ├── MEM/              #     MEM_req.sv（EX 级发起访存）, MEM_load.sv（MEM 级取数）, MEM2WB.sv
│   │   └── WB/               #     WB.sv
│   ├── Bus/                  #   片上总线
│   │   ├── RIB_top.sv        #     RIB 顶层（仲裁 + 地址译码 + 从机读回 MUX）
│   │   └── Arbiter.sv        #     固定优先级仲裁器
│   └── Peripheral/           #   外设（每个从机一个模块）
│       ├── ROM.sv            #     指令 ROM 封装（ROM_Ctrl，内含 IP）
│       ├── RAM.sv            #     数据 RAM 封装（RAM_Ctrl，内含 IP）
│       ├── TIMER.sv          #     定时器      @ 0x2000_0000
│       ├── SPI.sv            #     SPI 主机    @ 0x2000_0400
│       ├── UART.sv           #     串口 8N1    @ 0x2000_0800
│       └── GPIO.sv           #     通用 IO     @ 0x2000_0C00
├── scripts/                  # 支撑 Makefile 的 Tcl 脚本
│   ├── create_project.tcl    #   建工程 / 刷新源文件列表 / 由 pins.csv 生成 pins.xdc
│   ├── gen_pins_csv.tcl      #   从顶层端口生成 / 增量更新 pins.csv
│   ├── gen_slang_config.tcl  #   生成 .slang/server.json（LSP 用）
│   ├── build.tcl             #   综合 / 实现 / Bitstream
│   ├── check_rtl.tcl         #   非工程模式的 RTL 语法 / 详细阐述检查
│   ├── run_tb.tcl            #   非工程模式用 xsim 运行测试平台（含 IP）
│   ├── run_unit.tcl          #   ★ 单模块验证脚本（不涉及 IP，可独立运行）
│   └── sim.tcl               #   工程模式仿真（批处理出 VCD 或 GUI 看波形）
├── sim/                      # 仿真输出（waveform.vcd、unit/ 单元测试运行目录）
├── tb/                       # 测试平台
│   ├── prog/                 #   测试程序镜像
│   │   ├── gen_cpu_test.py   #     ★ 汇编生成器：hex + coe + ROM.mif
│   │   ├── cpu_test.hex      #     机器码清单（含注释，只读参考）
│   │   ├── cpu_test.coe      #     ROM IP 初始化文件（生成物）
│   │   └── ROM.mif           #     仿真用 ROM 初始化文件（生成物，run_tb.tcl 会覆盖 IP 的同名文件）
│   ├── tb_decoder.sv         #   ★ 译码器全指令集
│   ├── tb_alu.sv             #   ★ ALU 全运算
│   ├── tb_branch.sv          #   ★ 分支条件与目标
│   ├── tb_jump.sv            #   ★ JAL / JALR
│   ├── tb_regs.sv            #   ★ 寄存器堆
│   ├── tb_ex.sv              #   ★ EX 前递
│   ├── tb_mem.sv             #   ★ 访存对齐 / 字节通道 / 扩展
│   ├── tb_control.sv         #   ★ 冒险 / 冲刷 / 重定向
│   ├── tb_cpu.sv             #   ★ 完整 CPU（行为级存储器，可独立运行）
│   ├── tb_rib_periph.sv      #   RIB + 外设集成测试
│   └── tb_top.sv             #   SoC 顶层测试（使用 IP）
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
| **EX** | `MEM_req` | **访存请求提前一拍发起**：地址、store 数据对齐、字节使能 | `mem_addr/wdata/be/req/we` |
| **MEM** | `MEM_load` | 读数据通道提取、符号/零扩展、地址对齐检查 | `mem_rdata_ext`、`mem_align_err` |
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

**时序模型**：RIB 本身是全组合的，但**从机读延迟统一为 1 拍**（ROM/RAM 是 BMG 寄存输出，外设的读回也寄存一拍）：

```text
      T 拍：主机给 addr、req 有效
      T+1 拍：从机 rdata 才是该地址的数据
```

因此 RIB 的**读回按「该主机上一拍获得授权时选中的从机」回送**，而不是按当前片选（`RIB_top.sv` 的 `m_sel_q` / `m_sel_eff`）：

- 取指口持续请求，上一拍片选就是当前片选，行为与旧版一致；
- 数据口一次读只占「地址拍」，数据在下一拍才回来 —— 若不记住上一拍片选，
  下一拍总线已还给取指口，读回就会丢（这正是数据侧读通路必须解决的一环）。

CPU 侧与之配套：**访存地址在 EX 级发起**（`MEM_req`），BRAM 的 1 拍延迟正好落在 MEM 级，于是 MEM 级拿到的 `ram_data_i` 就是 `mem_alu_result` 这个地址的数据（详见 [6.1](#61-存储器时序重点)）。

若将来某个从机需要更多周期，应由该从机拉高 CPU 的 `hold_flag_i` 冻结流水线，而不是在 RIB 内引入 `valid/ready` 状态机。

> 实现现状：`CPU_top` 未把 `mem_size` 引出到端口，`CPU_SOC_top` 由 `ram_be_o`
> （4 位字节使能）反推出访问宽度——`MEM_req` 保证 `be` 是连续若干位（B → 1 位、
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
| RAW（普通） | EX 级目的寄存器被 ID 级指令使用 | 不停顿，EX/MEM、MEM/WB 前递 |
| load-use | EX 级是 load 且目的寄存器被 ID 级指令使用 | **不停顿**：访存地址在 EX 级发起，BRAM 1 拍延迟落在 MEM 级，MEM 级组合提取出的 load 数据直接前递给紧随其后的指令（`EX.sv` 的 `ex_mem_load_data`） |
| 分支/跳转 | EX 级 `branch_taken` 或 `jump_taken` | 冲刷 IF/ID、ID/EX、EX/MEM；`redirect_en` 装载目标 PC |
| 异常 | EX 级 `illegal` / `ecall` / `ebreak` | 与分支同样冲刷重定向；`exception_en` 置起（异常处理待接入） |

- 冲刷下游流水寄存器为 NOP，保证错误路径指令不写回、不访存。
- WB 级不需要 flush（`flush_mem2wb` 恒 0）。
- `hold_flag_i` 由外设拉高时冻结 PC，实现总线等待（当前无外设使用）。
- **取指与数据访问抢总线**：数据口（m0）优先级高于取指口（m1）。数据访问那一拍
  ROM 的地址输入被换成数据地址，于是「本拍要取的地址没送进 ROM」→ 冻结 PC 让
  下一拍重发；「下一拍 ROM 输出的是数据地址的内容」→ 注入一个 NOP 丢掉。
  **冻结比注入早一拍**，两者同拍会把指令流弄乱（见 [6.1](#61-存储器时序重点)）。

### 4.4 访存数据流（经 RIB）

```text
   EX 级：MEM_req 由 ALU 结果产生 mem_addr / mem_wdata / mem_be / req / we
        │              （★ 地址比旧设计提前一拍发起）
        ▼
   CPU_top 映射为 RAM 端口（ram_addr_o / ram_data_o / ram_be_o / ram_we_o / ram_re_o）
        │
        ▼
   RIB：仲裁 → 地址译码 → 选中从机
        │
        ▼
   RAM_Ctrl → Block Memory Generator IP（T 拍给地址，T+1 拍数据有效）
        │
        ▼
   T+1 拍（指令已到 MEM 级）：rib 按「上一拍片选」把该从机的 rdata 回送
        │
        ▼
   MEM_load 组合提取/符号扩展 → MEM2WB（与写回控制同拍）→ WB → Regs
                               └→ 同时前递给 EX 级（load-use 免停顿）
```

- **读通路对齐**：地址在 EX 拍发出，BRAM 在 EX→MEM 沿寄存该地址，于是
  **MEM 拍 `douta` 就是 `mem_alu_result` 这个地址的数据** —— 通道选择位
  （`mem_alu_result[1:0]`）与数据同拍，天然对齐，无需任何延迟寄存器或停顿。
- **写通路**：`wea`/`dina`/`addra` 在 EX 拍有效、EX→MEM 沿写入，仍严格按程序序
  提交（同一拍内 `addra` 与 `wea` 同源，且地址与数据来自同一条指令）。
- **总线占用**：一次数据访问只占总线一拍；数据访问那一拍取指口被抢，
  由 CPU 冻结 PC 并补一个 NOP 处理。

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
| `make unit` | **单模块验证（免 IP）**：`make unit TB=tb_decoder RTL="rtl/Core/ID/Decoder.sv"` |
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

单模块验证（推荐用于 CPU 本体调试，**免 IP 依赖**）：

```bash
make unit TB=tb_decoder RTL="rtl/Core/ID/Decoder.sv"
```

访存通路（两个模块一起编）：

```bash
make unit TB=tb_mem RTL="rtl/Core/MEM/MEM_req.sv rtl/Core/MEM/MEM_load.sv"
```

完整 CPU 回归需要列出全部核心 RTL：

```bash
make unit TB=tb_cpu RTL="rtl/Core/CPU_top.sv rtl/Core/Control.sv \
  rtl/Core/IF/IF.sv rtl/Core/IF/PCReg.sv rtl/Core/IF/IF2ID.sv \
  rtl/Core/ID/Decoder.sv rtl/Core/ID/Regs.sv rtl/Core/ID/ID.sv rtl/Core/ID/ID2EX.sv \
  rtl/Core/EX/ALU.sv rtl/Core/EX/Branch.sv rtl/Core/EX/Jump.sv \
  rtl/Core/EX/EX.sv rtl/Core/EX/EX2MEM.sv \
  rtl/Core/MEM/MEM_req.sv rtl/Core/MEM/MEM_load.sv rtl/Core/MEM/MEM2WB.sv rtl/Core/WB/WB.sv"
```

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

本项目提供**三级**递进的验证手段，写 RTL 时可以先用前两级自检，不必每次都跑综合或上板。

#### 1）单模块验证（推荐，不涉及 IP，可独立运行）

```bash
vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
       -tclargs <tb_top> <rtl_file1> [rtl_file2 ...]
```

`scripts/run_unit.tcl` **只编译显式给出的文件**，不扫描 `rtl/` 全目录，因此
**完全绕开 ROM/RAM 的 Block Memory Generator IP**，无需任何 IP 库即可运行。
这是排查 CPU 本体问题时最快的手段。

现有 9 个测试平台，共 **333 项检查，全部通过**：

| 测试平台 | 覆盖内容 | 项数 |
| --- | --- | :-: |
| `tb_decoder` | **全指令集译码**：R/I/S/B/U/J 型、系统指令、各类非法编码 | 116 |
| `tb_alu` | 十种运算 + 溢出回绕 + 移位量掩码 + 有/无符号边界 | 34 |
| `tb_branch` | 六种分支条件 + 有符号 vs 无符号边界 + 目标地址回绕 | 27 |
| `tb_jump` | JAL/JALR 目标计算、`&~1` 对齐、"与 PC 无关"特性 | 14 |
| `tb_regs` | x0 硬连线、写使能门控、同拍写穿透、复位 | 11 |
| `tb_ex` | 前递优先级（EX/MEM > MEM/WB）、**load 前递数据而非地址**、store 数据取原始 rs2、x0/rd_we 屏蔽 | 22 |
| `tb_mem` | `MEM_req` 的请求/字节使能/store 通道搬移 + `MEM_load` 的对齐检查/通道提取/符号扩展 | 38 |
| `tb_control` | 冲刷、重定向、异常、优先级；**load-use 不停顿**（改由前递解决） | 35 |
| `tb_cpu` | **完整 CPU**：取指→执行→写回全通路（行为级存储器替代 IP），含 load-use、背靠背 load、store 的 rs2 无前递、store→load 同址、LB/LH/LBU/LHU 扩展、循环（分支目标非幂等） | 36 |

运行示例：

```bash
# 译码器
vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
       -tclargs tb_decoder rtl/Core/ID/Decoder.sv

# 完整 CPU（需列出全部核心 RTL 文件）
vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
       -tclargs tb_cpu rtl/Core/CPU_top.sv rtl/Core/Control.sv \
         rtl/Core/IF/IF.sv rtl/Core/IF/PCReg.sv rtl/Core/IF/IF2ID.sv \
         rtl/Core/ID/Decoder.sv rtl/Core/ID/Regs.sv rtl/Core/ID/ID.sv \
         rtl/Core/ID/ID2EX.sv rtl/Core/EX/ALU.sv rtl/Core/EX/Branch.sv \
         rtl/Core/EX/Jump.sv rtl/Core/EX/EX.sv rtl/Core/EX/EX2MEM.sv \
         rtl/Core/MEM/MEM.sv rtl/Core/MEM/MEM2WB.sv rtl/Core/WB/WB.sv
```

`tb_cpu` 用两个**行为级存储器模型**（`beh_rom` / `beh_ram`，与 IP 语义一致：
寄存输出、1 拍读延迟、RAM 支持字节写）替代 IP，因此可独立运行；
程序镜像由测试平台内部逐条编码生成，不依赖 `tb/prog/*.hex`。

#### 2）RTL 语法 / 详细阐述检查

```bash
make check
```

`scripts/check_rtl.tcl` 在**内存工程**里读入 `rtl/` 下全部源文件并 elaborate
`CPU_SOC_top`，几秒内就能发现语法错误、端口不匹配、位宽不符、多重驱动等问题。
输出以 `0 Errors encountered` 结尾即为通过。

> `check_rtl.tcl` 现在分两步：先 elaborate **`CPU_top`**（纯 RTL，不依赖 IP，
> 必须通过），再尝试 `CPU_SOC_top`；后者在内存工程里没有 BMG IP 模型，会打印
> 「需要 IP 模型，本次跳过」但**不算失败**。带 IP 的完整检查走 `make synth`
> 或 `make tb TB=tb_top`（仿真脚本会带上 IP 行为模型）。

#### 3）集成测试（含 IP）

```bash
make tb TB=tb_top            # SoC 顶层（使用 IP，需 unisims_ver）
make tb TB=tb_rib_periph     # RIB + 外设
```

`scripts/run_tb.tcl` 会自动收集 IP 仿真模型、Vivado 安装目录下的
**Block Memory Generator 行为模型**（`blk_mem_gen_v8_4.v`，缺了它 xelab 会报
`Module <blk_mem_gen_v8_4_5> not found`），并把 `tb/prog/ROM.mif`
（由 `tb/prog/gen_cpu_test.py` 生成）复制到运行目录覆盖 IP 的同名文件 ——
因此**改测试程序不需要重新生成 IP**。

`tb_rib_periph.sv` 用一个「假主机」驱动 RIB 的 m1 端口：

| 分组 | 覆盖点 |
| --- | --- |
| 地址译码 | 6 个从机各自片选、未映射地址无片选 |
| RAM | 字写 + 读回、字节写（仅改目标字节通道）、半字写 |
| GPIO | DIR 复位值 / 写、DATA 回环、SET / CLR 原子操作 |
| TIMER | 启动装载、计数递减、溢出置位、写 1 清除 |
| UART / SPI | BAUD / DIV / TXDATA 寄存器写读 |
| SPI | `EN|START` 启动一次 8 bit 传输、BUSY 归零、DONE 置位 |

共 **25 项**，全部通过。`tb_top`（SoC 顶层 + ROM/RAM IP）另有 **26 项**：
CPU 寄存器/存储器副作用、GPIO 引脚、UART 实际发出的 `"OK\n"`（含停止位校验）、
TIMER 溢出、程序流是否走错分支，全部通过。测试程序镜像由
`tb/prog/gen_cpu_test.py` 汇编生成（`hex` / `coe` / `ROM.mif` 三者同源）：

```bash
python3 tb/prog/gen_cpu_test.py      # 重新生成程序镜像（自带往返解码自检）
make tb TB=tb_top                    # 用新镜像跑 SoC 顶层测试
```

> 限制：xsim 需要可写的 `/dev/shm`；在容器等受限环境中若报
> `shm_open: Permission denied`，需放开该目录权限。

#### 4）波形与参考模型

`tb_cpu.sv` 内置 VCD 导出与诊断探针，排查问题时很有效：

```systemverilog
$dumpfile("cpu_wave.vcd");   // 输出到 sim/unit/
$dumpvars(0, tb_cpu);
```

探针可逐拍打印 `EX 级 PC`、`IF2ID 锁存的指令`、`访存事务`、`各寄存器值`。
**注意**：比较信号时务必取**同一流水级**的值（`id_ex_pc` 配 `id_instr` 会因
跨级而错位一拍，产生误导性结论）。

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

- **宏集中管理**：所有位宽、指令编码、ALU 操作码、`op1_sel` / `op2_sel` / `wb_sel`、寄存器号别名、RIB 地址映射均定义在 `rtl/sys_define.svh`，各模块通过相对路径 `` `include `` 引入，**新增文件请沿用相对路径**。
- **访存请求在 EX 级发起**：`MEM_req` 在 EX 级产生 `addr/wdata/be/req/we`，`MEM_load` 在 MEM 级取数 —— 这是让 BRAM 的 1 拍读延迟与流水线对齐的关键（见 6.1），也是 `load-use` 免停顿的原因。
- **x0 处理**：寄存器堆写入忽略 x0，读出恒为 0；前递逻辑同样排除 x0。
- **流水寄存器风格**：`if (rst) … else if (flush) … else if (!stall) …`，优先级固定为「复位 > 冲刷 > 停顿」。
- **分支在 EX 解析**：不采用 ID 级提前解析，因此分支代价为 2 个气泡（冲刷 IF/ID 与 ID/EX）；后续可优化到 ID 级。
- **复位极性**：`rst_async` 低有效，经 `CPU_SOC_top` 同步为 `rst_sys`（`RESET_EN = 1'b0` 表示复位有效）。
- **PC 复位向量**：`PC_RESET = 32'h0000_0000`，可按需调整。
- **代码风格**：RTL 使用 SystemVerilog（`logic` / `always_comb` / `always_ff`），Vivado 工程 `target_language` 设为 Verilog，但 `.sv` / `.svh` 单独指定为 SystemVerilog 文件类型。

### 6.1 存储器时序（重点）

ROM / RAM 使用 **Block Memory Generator IP**，二者均为 **`Total Port A Read Latency = 1`**：

| 项目 | ROM | RAM |
| --- | --- | --- |
| 类型 | 单口 ROM | 单口 RAM |
| 容量 | 4096 × 32（16 KiB） | 16384 × 32（64 KiB） |
| 使能 | 无 `ena` | 有 `ena` |
| 字节写 | 1 位 `wea` | **4 位 `wea`**（按字节） |
| 读延迟 | **1 拍** | **1 拍** |

**IP 配置要点**：`Primitives Output Register` / `Core Output Register` / `MUX Pipeline Stages`
**全部取消**，使总读延迟保持 1。勾选任何一项都会变成 2 拍，流水线需重新安排。

BRAM 是同步读，"T 拍给地址、T+1 拍数据有效"，因此**必须把地址提前安排好**，
让这 1 拍延迟恰好落在流水线的某个阶段里（见 `doc/structure/instruction_fetch.dio.png`）：

**BRAM 是同步读**："T 拍给地址、T+1 拍数据有效"，因此**必须把地址提前安排好**，让这 1 拍延迟恰好落在流水线的某个阶段里。

#### 取指侧（`if_pc_d1` + 两条控制规则）

ROM 是寄存输出：T 拍给出地址 `A(T)`，T+1 拍 `douta = I(A(T))`。于是 `CPU_top` 里：

- **`if_pc_d1`**（PC 延后一拍）使 `IF2ID` 锁存到的 (指令, 地址) 配成同一条指令。
  **若直接用 `if_pc`，EX 级 `pc+imm` 算出的所有分支/跳转目标会整体偏移 4 字节。**
- 由此派生出两条取指控制规则：
  - **注入 NOP**：让「本拍 ROM 输出」作废 —— 下一拍沿写入 `INST_NOP`；
  - **冻结 PC**：让同一地址连出两拍 —— 下一拍沿会再收到一次同样的指令
    （配合 `IF2ID` 保持，就是一次「停顿」）。

据此处理三种情况：

| 情况 | 动作 |
| --- | --- |
| 分支/跳转重定向 | 重定向当拍 + 下一拍**各注入一个 NOP**（丢掉错误路径上的一条指令 + 一条在途指令）。**绝不能冻结 PC**：冻结会让目标指令被锁进 `IF2ID` 两次 —— 现象就是分支目标指令重复执行（例如循环变量被多加一次） |
| 数据访问抢占总线 | 抢占当拍**冻结 PC**（下一拍重发该地址），**下一拍注入 NOP**（丢掉 ROM 输出的数据地址内容）。冻结与注入必须错开一拍 |
| 复位释放后第一拍 | 注入一个 NOP：复位期间 PC 停在复位向量上、ROM 反复寄存该地址，否则首条指令会被锁两次、执行两遍 |

#### 数据侧（本次解决的核心问题）

旧设计在 **MEM 级**才给出访存地址，于是 T 拍 `mem_alu_result` 是地址但数据还没回来，
T+1 拍数据回来了而 `mem_alu_result` 已前进 —— 提取用的字节通道位与数据**永远差一拍**
（`lw`/`lbu`/`lhu` 读回错误）。

现在把**地址连同 `we/be/wdata` 提前到 EX 级发起**（`MEM_req`），BRAM 的 1 拍延迟
正好落在 MEM 级：

```text
   EX 拍 ：mem_addr = ALU 结果  ──► BRAM 在本拍沿寄存该地址
   MEM 拍：ram_data_i = mem[mem_alu_result]   ← 与通道选择位同拍，天然对齐
           └─► MEM_load 组合提取/扩展 → MEM2WB（与写回控制同拍锁存）
```

这样做同时带来两个好处：

1. **不需要任何延迟寄存器**，也不会破坏 `Regs` 的同拍写穿透（写回控制信号始终与
   数据同拍，下面那两条硬约束依然成立）；
2. **load-use 不需要停顿**：依赖指令在 EX 级的那一拍，load 正在 MEM 级且数据已组合
   可用，`EX.sv` 直接把 `mem_rdata_ext` 当作 EX/MEM 前递源（`ex_mem_load_data`）。
   `Control` 因此不再产生数据冒险停顿（`stall_*` 恒为 0，端口留给将来的多周期外设）。

> **两条硬约束（踩过的坑，仍然成立）**：
> 1. **写回控制信号不可延迟** —— `Regs` 是**同拍写穿透**（WB 写与 ID 读同地址），
>    延迟控制会让 `addi` 与紧随其后的 `sub` 抢同一拍，产生错误的 RAW 结果。
> 2. **前递源 `ex_mem_*` 必须用当前 MEM 级原值**，不可接任何延迟版本。

> **写时序变化**：写现在在 EX 拍提交（EX→MEM 沿落盘），比旧设计早一拍；同一拍内
> 地址 / 数据 / 字节使能同源，仍是严格程序序，`sw`/`sb`/`sh` 实测正常。

> **外设读的一拍语义**：所有从机（含外设）读回都寄存一拍，因此「写寄存器 → 紧接着
> 读同一个寄存器」可见；但外设**内部状态位**（如 UART 的 `TX_BUSY`）在写之后要过
> 2 拍才置起，程序写完立刻轮询可能读到旧值 —— 需要像 `tb/prog` 那样写后插几条
> `nop` 再轮询。

> **时序提示**：地址通路变成「EX 级 ALU → BRAM addra」，读数据通路变成
> 「BRAM douta → 提取 → EX 前递 MUX → ALU」。100 MHz 下可收敛（本工程尚未加时钟
> 约束、未做时序收敛）；若将来提高频率，可考虑在 ID 级并行算出地址（`rs1 + imm`）
> 以缩短这条路径。

---

## 7. 当前进度

### ✅ 已完成并经仿真验证

**CPU 本体 —— 模块级 9 个测试平台、333 项检查全部通过**（命令见 5.6）

- 五级流水线骨架：IF / ID / EX / MEM / WB 各级与全部流水寄存器。
- **完整 RV32I 译码**（`tb_decoder` 116 项）：R / I / S / B / U / J 型，
  `LUI`、`AUIPC`、`JAL`、`JALR`、`FENCE`、`ECALL`、`EBREAK` 及各类非法编码。
- **ALU 十种运算**（`tb_alu` 34 项）：含溢出回绕、移位量掩码、有/无符号边界。
- **分支六种条件**（`tb_branch` 27 项）+ **JAL/JALR 目标**（`tb_jump` 14 项）。
- **寄存器堆**（`tb_regs` 11 项）：x0 硬连线、写使能门控、同拍写穿透、复位。
- **前递网络**（`tb_ex` 22 项）：EX/MEM 优先于 MEM/WB、**load 前递数据而非地址**、
  store 数据取寄存器堆原始 `rs2`、x0/`rd_we` 屏蔽。
- **访存通路**（`tb_mem` 38 项）：`MEM_req` 的请求/字节使能/store 通道搬移 +
  `MEM_load` 的对齐检查/通道提取/符号与零扩展。
- **控制单元**（`tb_control` 35 项）：冲刷、重定向、异常、优先级；数据冒险不停顿。
- **完整 CPU**（`tb_cpu` 36 项）：取指→执行→写回全通路，覆盖 load-use、
  背靠背 load、store 的 `rs2` 无前递、store→load 同址、LB/LH/LBU/LHU 扩展、
  以及**循环（分支目标为非幂等指令）**。

**★ 数据侧 BRAM 读延迟对齐（本次解决）**

问题：地址在 MEM 级才发出，BRAM 数据下一拍才回来，而字节通道选择位
（`mem_alu_result[1:0]`）那时已前进 —— 二者永远差一拍，`lw`/`lbu`/`lhu` 读回错误。

解决：把访存请求提前到 **EX 级**发起（新增 `rtl/Core/MEM/MEM_req.sv`，
MEM 级只保留取数通路 `MEM_load.sv`）：

```text
   EX 拍 ：MEM_req 用 ALU 结果给出 addr/be/wdata ──► BRAM 本拍沿寄存地址
   MEM 拍：ram_data_i = mem[mem_alu_result]      ──► 通道选择同拍，天然对齐
           └─► MEM_load 提取/扩展 → MEM2WB（与写回控制同拍）
```

配套改动（都是这次问题的连带项）：

| 改动 | 说明 |
| --- | --- |
| `RIB_top` 读回对齐 | 从机读延迟统一 1 拍，读回改为按「该主机上一拍授权时选中的从机」回送；上一拍无访问时退回当前授权（复位后第一拍） |
| 外设读数据寄存一拍 | `TIMER` / `SPI` / `UART` / `GPIO` 的读回寄存输出，与 ROM/RAM 统一为「T 拍给地址、T+1 拍数据」 |
| `EX` load 前递 | EX/MEM 是 load 时前递 **MEM 级组合提取出的数据**，`load-use` 不再需要停顿 |
| `EX` store 数据源 | `rs2` 的「无前递」来源改为寄存器堆读出的原始 `rs2`（原来取 `id_ex_op2`，S 型 `op2_sel=IMM` 会把立即数当数据写进内存 —— 这是个隐藏 bug，`tb_cpu` 现在有专门用例） |
| `Control` 简化 | 去掉 load-use 停顿逻辑（`stall_*` 恒 0），只保留冲刷 / 重定向 / 异常 |
| 取指控制修正 | 重定向改为「两个 NOP 注入」且**不冻结 PC**（原实现冻结 PC 会让分支目标指令执行两次）；总线抢占改为「当拍冻结 PC + 下一拍注入 NOP」；复位释放后第一拍注入 NOP（原实现首条指令会执行两遍） |
| `UART` 起始位修正 | 波特率计数器空闲停在 0，导致刚进入发送时 `baud_tick` 立刻有效、起始位只持续 1 拍（整帧短一个位周期，接收方错一位）。现在进入「忙」时先装一个完整位周期，且 `baud_tick` 只在计数器已在运行时有效 |

**总线与外设**

- `rtl/Bus/Arbiter.sv`：固定优先级仲裁器（`m0 > m1 > m2 > m3`）。
- `rtl/Bus/RIB_top.sv`：4 主机 / 6 从机互联——仲裁、主机侧 MUX、地址译码、
  请求门控、**按上一拍片选的主机读回**、内部偏移裁剪。
- 6 个从机模块：`ROM`、`RAM`、`TIMER`、`SPI`（Mode 0~3）、`UART`（8N1）、`GPIO`。
- `tb_rib_periph`：RIB + 外设集成测试 **25 项通过**。
- `tb_top`：**SoC 顶层（含 ROM/RAM IP）功能测试 26 项通过** —— 覆盖 CPU 寄存器、
  存储器副作用、GPIO 引脚、**UART 实际发出的 `"OK\n"`（含停止位校验）**、
  TIMER 溢出、程序流是否正确。测试程序由 `tb/prog/gen_cpu_test.py` 生成。

**流程**

- Makefile + Tcl 脚本：建工程 / 引脚 CSV 增量生成 / 综合实现 / 仿真 / LSP 配置。
- **三级验证体系**（见 5.6）：单模块（免 IP）→ RTL 检查（CPU_top 免 IP，SoC 可选）→ 集成测试（含 IP）。
- `make check` 不再因为缺 IP 模型而失败；`make tb` 会自动带上 BMG 行为模型，
  并用 `tb/prog/ROM.mif` 覆盖 IP 的初始化文件（改程序不必重新生成 IP）。

### 🚧 进行中 / 待完成

**① 微架构 / 时序**

- **地址通路变长**：现在是「EX 级 ALU → BRAM addra」+「BRAM douta → 提取 →
  前递 → ALU」两条组合路径。100 MHz 可收敛，但**尚未加时钟约束、未做时序收敛**；
  若提高频率，可把访存地址在 ID 级并行算出（`rs1 + imm`）。
- **失速路径保留**：`Control.stall_*` 目前恒 0，多周期从机的 `hold_flag_i` 冻结点
  在 `CPU_top` 侧（`if_stall`）—— 外设若需要等待周期，还需把 `hold_flag` 一并接到
  ID/EX 级，避免只冻结取指导致指令流错位。
- **分支机构**：分支在 EX 解析（2 气泡），可前移到 ID；无分支预测。

**② 异常与中断**

- `exception_en` 已产生但未接入异常处理（无 `mcause`/`mepc`/CSR）；
  `mem_align_err` 已算出但未上报到 `Control`；`int_i` 已接定时器中断，但 CPU 侧
  无中断响应。

**③ 外设增强**

- UART：接收未做多数表决与起始位二次确认；发送侧状态位（`TX_BUSY`）在写后
  2 拍才置起，软件需自行留出间隔。
- SPI：单字节、单从机、无 FIFO/DMA；GPIO 宽度固定 8 位。

**④ 板级**

- `constrs/pins.csv` 与 `pins.xdc` 尚未按实际开发板填写；时序收敛与上板验证未做。
- RIB 的 m2 / m3 预留（规划给 DMA / 调试）。
- 资源：ROM 用 4×36K BRAM、RAM 用 16×36K BRAM，共 20 块；Zynq-7010 共 60 块。

---

## 8. 许可证

本项目采用 [MIT License](LICENSE) 开源。
