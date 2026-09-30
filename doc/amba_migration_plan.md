# SoC 总线架构迁移到 AMBA —— 方案讨论稿

> 状态：**讨论稿（仅方案，未动 RTL）**
> 目标读者：后续实现该迁移任务的会话/开发者
> 相关代码：`rtl/Bus/RIB_top.sv`、`rtl/Bus/Arbiter.sv`、`rtl/CPU_SOC_top.sv`、`rtl/Core/CPU_top.sv`

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
| --- | --- |
| 选哪个标准 | **系统总线用 AMBA 5 AHB 规范里的 AHB-Lite 子集（IHI0033）**；**外设用 APB4（IHI0024）**，中间加一个 **AHB→APB 桥** |
| 为什么不是 AXI4-Lite | 读写各需 AR/R、AW/W/B 两次握手，CPU 侧每次访问至少 2~3 拍，会打破现有「EX 发地址、MEM 取数据」的 1 拍延迟契约；从机侧每个都要实现 5 通道握手，工作量大而收益为 0 |
| 为什么不是纯 AHB（多主 AHB2） | HBUSREQ/HLOCK/HGRANT/SPLIT/RETRY 语义复杂且已过时；AHB-Lite + 互连（每主机一个 AHB-Lite 端口）是当今标准做法 |
| 为什么不是 APB 全局 | APB 无流水、每次传输 ≥2 拍，取指会退化到 2 拍/条，不可接受；APB 只适合挂在桥后面的慢速外设 |
| 最大收益 | AHB 的「地址相 / 数据相」流水与 BMG 的「T 给地址、T+1 出数据」**天然一一对应**，零等待从机下仍是 **1 拍/次传输**，性能与现状持平，但接口变成行业标准、可挂第三方 IP、可用 Xilinx 的 AXI/AHB 生态 |
| 最大代价 / 前置条件 | **CPU 必须补齐「整流水线停顿」通路**（现在 `hold_flag_i` 只冻结 PC，见 §1.2）——这是阶段 0 的前置任务，否则任何等待态都会打乱流水线 |
| 工作量粗估 | RTL 约 700~1100 行（新增/改造），TB 约 500~900 行；分 6 个阶段，阶段 5 的验收门禁是 **`tb_top` 系统级 RV32I 40/40 保持全绿** |
| 建议的推进方式 | 渐进：先把 **RIB 包一层 AHB-Lite 从机**保证中途可回归，再逐个替换从机与主机端口，最后删 RIB |

---

## 1. 现状与约束

### 1.1 现有 RIB

| 项目 | 现状 |
| --- | --- |
| 结构 | 4 主机（m0 数据 / m1 取指 / m2、m3 预留）× 6 从机（ROM / RAM / TIMER / SPI / UART / GPIO） |
| 仲裁 | `rtl/Bus/Arbiter.sv`，固定优先级 `m0 > m1 > m2 > m3`，输出独热 `grant`、`valid`、`grant_id` |
| 数据通路 | **全组合**：主机侧 MUX 按 `grant` 选地址/控制 → 6 个从机并行片选 → 读回 MUX |
| 读回语义 | **按「该主机上一拍获得授权时选中的从机」回送**（`m_sel_q` / `m_sel_eff`），因为从机读延迟统一 1 拍 |
| 地址译码 | `s_X_sel = ((addr & X_MASK) == X_BASE)`，另有 `X_ALIAS_MASK` 把总线地址裁成从机内部偏移 |
| 等待态 | **不存在**：所有从机都是 1 拍（BMG 寄存输出，外设读数据也寄存一拍）；`hold_flag_i` 预留未用 |
| 未映射地址 | 读回 0、写丢弃（宽容行为，无错误响应） |

### 1.2 CPU 侧的硬约束（迁移能否成立的关键）

| 约束 | 说明 |
| --- | --- |
| 访存地址在 **EX 级**发出 | `MEM_req` 在 EX 级产生 `addr/wdata/be/req/we`（为了让 BMG 的 1 拍读延迟落在 MEM 级） |
| 读数据在 **MEM 级**消费 | MEM 级用 `mem_alu_result[1:0]` 做字节通道选择，要求「T 发地址、T+1 数据有效」 |
| 取指 | ROM 每拍给新地址，IF2ID 用 `if_pc_d1` 配对；即**取指是流水化的、1 条/拍** |
| 总线争用处理 | `if_grant_i` / `bus_grant_valid_i`：数据口抢到总线的那一拍，CPU **冻结 PC 并注入 NOP**（`if_bus_stall` / `if_bus_stall_d1`） |
| 停顿通路 | `hold_flag_i` 已升级为**整流水线停顿**（阶段 0，见 §7）：冻 `PCReg`/`IF2ID`/`ID2EX`/`EX2MEM`/`MEM2WB`，并冻结送 ROM 的取指地址、锁存 MEM 级读数据、停顿中不提交重定向/陷阱。**仍有 1 项等待态用例未过**（见 §7 阶段 0 遗留问题） |

> **结论**：AHB 的等待态（`HREADY=0`）是标准用法，因此**必须先补齐 CPU 的整流水线停顿**（阶段 0），否则迁移必崩。

### 1.3 从机侧现状

| 从机 | 实现 | 迁移要点 |
| --- | --- | --- |
| ROM | `ROM_Ctrl` 包 BMG：4096×32，**无 `ena`**，1 位 `wea`，读延迟 1 | AHB-Lite 从机：地址相给 `addra`，数据相出 `HRDATA`，`HREADY` 恒 1 |
| RAM | `RAM_Ctrl` 包 BMG：16384×32，有 `ena`，**4 位 `wea`**，读延迟 1 | 同上；写用 `HWDATA` + 由 `HSIZE`/地址低位展开的 `wea` |
| TIMER / SPI / UART / GPIO | 端口统一为 `sel/addr/wdata/size/we/re/rdata`，读数据寄存一拍；写用 `size` 展开字节掩码 | 改造成 APB4 从机：`PSEL/PENABLE/PWRITE/PADDR/PWDATA/PSTRB/PRDATA/PREADY`；字节掩码改用 `PSTRB`（可删掉各模块里重复的 `be_mask` 逻辑） |

### 1.4 必须保住的验证资产

| 资产 | 作用 | 迁移中的定位 |
| --- | --- | --- |
| 10 个模块级 TB（decoder/alu/branch/jump/regs/ex/mem/control/cpu/**csr**）共 420 项 | CPU 本体回归 | **不允许退化**（阶段 0 会改 Control/CPU_top，需同步扩展用例） |
| `tb_rib_periph`（25 项） | 总线+外设集成 | 由新的 AHB/APB 集成 TB 取代 |
| **`tb_top`（118 项，RV32I 40/40 + Zicsr + 异常/中断）** | SoC 级系统回归（含 ROM/RAM IP + 外设 + UART 波形） | **迁移验收门禁：必须保持全绿** |
| `tb/prog/gen_cpu_test.py` | 测试程序生成器（含参考模型/覆盖率自检） | 不需要改（程序与总线无关） |

---

## 2. AMBA 选型

### 2.1 候选标准对比

| 标准 | 传输粒度 | 典型拍数/次 | 信号量 | 多主机 | 从机实现难度 | 与本项目契合度 |
| --- | --- | --- | --- | --- | --- | --- |
| **AHB-Lite**（AMBA5 AHB 子集） | 单次（SINGLE 突发） | 零等待下 **1 拍** | 中（~15/端口） | 需要互连（每主机一个端口） | 低 | ★★★★★ 地址相/数据相 = EX/MEM |
| AHB（多主 AHB2） | 单次/突发 | 1 拍 | 多（HBUSREQ/HLOCK/HGRANT/SPLIT…） | 原生 | 中 | ★★ 语义复杂、已过时 |
| **AXI4-Lite** | 单次 | 读 ≥2、写 ≥2 | 多（5 通道、~40/端口） | 原生 | 中 | ★★ 延迟契约不匹配，收益低 |
| AXI4（Full） | 突发/乱序 | 高吞吐 | 很多 | 原生 | 高 | ★ 对单核 RV32I 属过度设计 |
| **APB4** | 单次 | ≥2 拍 | 少（~10） | 单主（桥） | 很低 | ★★★★ 只适合慢速外设 |
| AXI4-Stream | 无地址流 | — | 少 | — | — | 不适用（无地址概念） |

### 2.2 评分矩阵（5 分制）

| 维度 | AHB-Lite | AXI4-Lite | 纯 AHB(多主) | APB4 |
| --- | :-: | :-: | :-: | :-: |
| 与现有 EX/MEM 时序契合 | **5** | 2 | 4 | 1 |
| 零等待下吞吐（拍/次） | **5**（1） | 2（≥2） | 5（1） | 1（≥2） |
| 从机实现工作量（越高越省事） | **4** | 2 | 3 | 5 |
| 互连复杂度（越高越简单） | 3 | 3 | 4 | 1 |
| 可挂第三方 IP / 生态 | 4 | **5** | 2 | **5** |
| 规范成熟度 / 教学价值 | **5** | 5 | 3 | 4 |
| 与 Zynq PS(AXI) 互联 | 3 | **5** | 2 | 1 |
| 合计 | **29** | 24 | 19 | 18 |

### 2.3 结论

1. **系统总线：AHB-Lite（AMBA 5 AHB，IHI0033 的 AHB-Lite 子集）**
   - 只实现 `SINGLE` 突发（`HBURST=000`），不实现 exclusive / secure / parity / HMASTER 扩展；
   - 主机数 2（取指、数据），从机 4（ROM、RAM、AHB→APB 桥、默认从机）。

2. **外设总线：APB4（IHI0024）**，经 **AHB→APB 桥** 接入；只实现 `PREADY`/`PSLVERR`（`PSLVERR` 先恒 0，见 §9 待决 2）。

3. **AXI4-Lite 列为二期可选**：若将来要与 Zynq PS 的 AXI 端口互联，有两种做法 ——
   (a) 在 PL 边界放一个 **AXI4-Lite ↔ AHB-Lite 转换器**（自研约 150~250 行，或复用 Xilinx 生态里的转换 IP，需按实际 IP 目录确认）；
   (b) 系统性升级为 AXI4-Lite 系统总线（等于重做主机适配器 + 全部从机，不推荐在没有 DMA/缓存需求前做）。

### 2.4 与 Zynq PS 互联的现实约束（重要提醒）

本工程目标是 Zynq-7010，PS 侧对外只有 **AXI**（GP/AHP 等）。也就是说：

- **本项目 SoC 内部用 AHB-Lite 完全没有问题**（PL 内部总线自定）；
- 一旦要让 **PS 访问 PL 里的 RAM/外设**（或 PL 访问 DDR），边界上必须出现 AXI —— 届时按 §2.3 的 (a) 处理即可，**不影响内部 HBM/AHB 结构**。

---

## 3. 目标架构

### 3.1 框图

```text
        ┌──────────────┐
        │   CPU_top    │
        │  (核心不动)   │
        └──┬───────┬───┘
   取指端口 │       │ 数据端口
 (EX 发地址)│       │(EX 发地址/数据)
        ┌──▼───────▼──────────────────────────────────────────┐
        │        AHB-Lite 互连（2 主机端口 / 4 从机端口）        │
        │  ┌────────────┐  ┌───────────┐  ┌───────────────┐   │
        │  │ 主机侧仲裁  │→ │ 从机侧解码 │→ │ 读回/HRESP/    │   │
        │  │(数据>取指)  │  │ HSEL 生成  │  │ HREADY 分发    │   │
        │  └────────────┘  └───────────┘  └───────────────┘   │
        └──┬──────────┬──────────────┬──────────────┬─────────┘
           │          │              │              │
      ┌────▼───┐ ┌────▼───┐  ┌───────▼────────┐ ┌───▼──────────┐
      │ ROM    │ │ RAM    │  │ AHB→APB 桥      │ │ 默认从机      │
      │(BMG)   │ │(BMG)   │  │ (setup/access) │ │ (OKAY + 0)   │
      │0 等待  │ │0 等待  │  └───┬────┬───┬───┬┘ └──────────────┘
      └────────┘ └────────┘      │    │   │   │
                              ┌──▼┐ ┌─▼─┐ ┌▼──┐ ┌▼───┐
                              │TMR│ │SPI│ │UAR│ │GPIO│   ← APB4 从机
                              └───┘ └───┘ └───┘ └────┘
```

### 3.2 主从清单与地址映射（保持不变）

| 从机 | 基址 | 容量 | 总线 | 等待态 |
| --- | --- | --- | --- | --- |
| ROM | `0x0000_0000` | 16 KiB | AHB-Lite | 0（BMG 延迟 1 拍 = 数据相） |
| RAM | `0x1000_0000` | 64 KiB | AHB-Lite | 0 |
| APB 区（桥） | `0x2000_0000` | 4 KiB | AHB→APB | 2~3 拍（桥的 setup + access） |
| ├ TIMER | `0x2000_0000` | 1 KiB | APB4 | 由桥决定 |
| ├ SPI | `0x2000_0400` | 1 KiB | APB4 | 同上 |
| ├ UART | `0x2000_0800` | 1 KiB | APB4 | 同上 |
| └ GPIO | `0x2000_0C00` | 1 KiB | APB4 | 同上 |
| 默认从机 | 其它 | — | AHB-Lite | 0（OKAY，读 0） |

> `X_ALIAS_MASK` 机制随之消失：AHB 从机拿到的是完整地址，由从机封装内部裁低位（ROM 取 `addr[13:2]`、RAM 取 `addr[15:2]`）。

### 3.3 时序模型（迁移能成立的核心）

```text
             T 拍（地址相）        T+1 拍（数据相）
CPU         EX：ALU 出地址    →    MEM：取回数据 / 字节通道选择
AHB-Lite    HADDR/HTRANS/VALID →   HRDATA（读）/ 写完成（写）
BMG         addra 被寄存        →   douta 有效
```

**零等待从机（ROM/RAM）下：一次传输 1 拍，与现状完全一致** —— 这是选 AHB-Lite 的根本原因。

**等待态**：从机在数据相拉低 `HREADY` → 主机保持地址/写数据、流水线冻结（由阶段 0 补全的停顿通路实现）。
**多主机**：互连对「下一拍的地址相」提前一拍做仲裁（与现在的 `grant` 提前决定一致），保证数据口抢总线时取指端口看到 `HREADY=0` 而**整体停顿**，取代现在「注 NOP + 冻 PC」的权宜做法（见 §5）。

### 3.4 关键语义约定

| 约定 | 取值 |
| --- | --- |
| 突发类型 | 只用 `SINGLE`（`HBURST=3'b000`） |
| 传输类型 | `HTRANS=IDLE`（无访问）/ `NONSEQ`（单次访问），不实现 `SEQ`/`BUSY` |
| 位宽 | `HSIZE` = 000(B)/001(H)/010(W)，与 CPU 的 `MSZ_B/H/W` 对应 |
| 保护位 | `HPROT` 输出固定值（数据访问 `3'b011`、取指 `3'b010` 之类），从机忽略 |
| 写通道 | `HWDATA` 按地址字节通道对齐（`MEM_req` 现在就是这么做的，可直接复用） |
| 只读从机 | ROM 忽略写（`HWRITE=1` 时返回 OKAY、不写） |
| 未映射 | 默认从机 OKAY + 读回 0（先保持现状，见 §9 待决 2） |

---

## 4. 接口定义（草案）

### 4.1 AHB-Lite 主机端口（CPU 适配器的从机侧，即互连看到的主机）

```systemverilog
// 每个 CPU 端口一个实例（取指 / 数据）
input  wire [31:0] haddr;      // 地址相：字节地址
input  wire [ 1:0] htrans;     // IDLE / NONSEQ
input  wire        hwrite;
input  wire [ 2:0] hsize;      // B/H/W
input  wire [ 2:0] hburst;     // 固定 SINGLE
input  wire [ 3:0] hprot;
input  wire [31:0] hwdata;     // 数据相：写数据（按字节通道对齐）
input  wire        hready;     // 从互连回：0 = 插入等待态（主机必须保持）
input  wire [31:0] hrdata;
input  wire        hresp;      // 0 = OKAY
```

### 4.2 AHB-Lite 从机端口（ROM / RAM / 桥 / 默认从机）

```systemverilog
input  wire        hsel;       // 地址译码片选（来自互连）
input  wire [31:0] haddr;
input  wire [ 1:0] htrans;
input  wire        hwrite;
input  wire [ 2:0] hsize;
input  wire [31:0] hwdata;
output logic [31:0] hrdata;
output logic        hreadyout; // 0 = 需要等待周期
output logic        hresp;     // 0 = OKAY
```

### 4.3 AHB→APB 桥

```systemverilog
// AHB 侧：一个标准 AHB-Lite 从机端口（§4.2）
// APB 侧：
output logic        psel [0:3];       // 4 个外设各自片选
output logic        penable;
output logic        pwrite;
output logic [31:0] paddr;
output logic [31:0] pwdata;
output logic [ 3:0] pstrb;            // 由 HSIZE + 地址低位展开
input  wire  [31:0] prdata [0:3];
input  wire         pready [0:3];
input  wire         pslverr [0:3];
```

### 4.4 APB4 从机端口（TIMER / SPI / UART / GPIO 统一风格）

```systemverilog
input  wire        psel;
input  wire        penable;
input  wire        pwrite;
input  wire [31:0] paddr;
input  wire [31:0] pwdata;
input  wire [ 3:0] pstrb;      // 取代现在的 size/be_mask
output logic [31:0] prdata;    // access 相组合给出即可（PREADY=1 同拍有效）
output logic        pready;    // 这些寄存器型外设恒 1
output logic        pslverr;   // 恒 0
```

---

## 5. 与现有 RIB 的映射（迁移对照表）

| RIB 概念 | AHB-Lite 对应物 | 处理 |
| --- | --- | --- |
| `Arbiter`（固定优先级） | 互连内的主机仲裁（同样固定优先级：数据 > 取指） | 逻辑照搬，接口改 AHB |
| 主机侧 MUX（按 grant 选地址/控制） | 互连的主机 MUX（驱动共享从机侧地址相） | 照搬 |
| `s_X_sel` 地址译码（BASE/MASK） | 互连的 `HSEL` 生成 | 照搬（掩码常量可继续放 `sys_define.svh`） |
| `X_ALIAS_MASK` 内部偏移裁剪 | **AHB 从机内部裁低位** | 从机封装里保留（如 `ROM_Ctrl` 内 `addr[13:2]`） |
| 读回 MUX + `m_sel_q`（按上一拍片选） | 互连的数据相读回 MUX（`HRDATA`/`HREADY`/`HRESP`） | 概念等价；AHB 用「地址相选中的从机在数据相回送」表达，比现在更直白 |
| 「1 拍延迟、无等待态」 | AHB 零等待从机（`HREADY=1`） | 语义不变 |
| `if_grant_i`/`bus_grant_valid_i` + NOP 注入 | 取指主机的 `HREADY` | **迁移后删除 NOP 注入/冻 PC 权宜逻辑**，改为标准停顿 |
| `hold_flag_i`（只冻 PC，未用） | 全流水线停顿（`HREADY=0` 的统一后果） | **阶段 0 补全**（前置任务） |
| 未映射地址读回 0 | 默认从机 OKAY + 0 | 行为不变 |
| `ram_be_o` 反推 size（临时做法） | `HSIZE` | 顺手在 `CPU_top` 增加 `size` 输出（README 里早就列为待办） |

**代码资产处置**

- 保留：`rtl/Bus/Arbiter.sv`（结构可复用，或改写成 `ahb_arbiter` 的形态）。
- 替换：`rtl/Bus/RIB_top.sv` → `rtl/Bus/AHB/` 下的互连 + 从机封装 + 桥。
- **过渡措施（建议）**：阶段 1~4 期间把现有 RIB **包一层 AHB-Lite 从机**（`ahb_rib_wrapper`），这样即使主机侧已经换成 AHB，`tb_top` 与 `tb_rib_periph` 仍可在中途跑，避免长时间无法回归。

---

## 6. 模块清单、难度与工作量

### 6.1 模块表

| # | 模块 | 文件（建议） | 难度 | 估行数 | 依赖 |
| :-: | --- | --- | :-: | :-: | --- |
| 0 | **CPU 停顿通路补全**（前置） | 改 `Control.sv` / `CPU_top.sv` | ★★★★ | 60~120 | — |
| 1 | AHB-Lite 主机适配器（CPU 侧，例化 2 次） | `rtl/Bus/AHB/ahb_master_adapter.sv` | ★★ | 120~180 | 0 |
| 2 | AHB-Lite ROM 从机 | `rtl/Peripheral/ROM.sv` 改造 | ★ | 50~70 | — |
| 3 | AHB-Lite RAM 从机 | `rtl/Peripheral/RAM.sv` 改造 | ★ | 60~90 | — |
| 4 | 默认从机（OKAY+0） | `rtl/Bus/AHB/ahb_default_slave.sv` | ★ | 30~50 | — |
| 5 | AHB-Lite 互连（仲裁+解码+读回+HREADY 分发） | `rtl/Bus/AHB/ahb_interconnect.sv` | ★★★ | 180~260 | 1,2,3,4 |
| 6 | AHB→APB 桥 | `rtl/Bus/APB/ahb2apb.sv` | ★★★ | 120~180 | — |
| 7 | APB 外设改造 ×4 | `rtl/Peripheral/{TIMER,SPI,UART,GPIO}.sv` | ★★ | 各 20~50 | 6 |
| 8 | SoC 顶层接线替换 | `rtl/CPU_SOC_top.sv` | ★★ | 80~150 | 1,5,6,7 |
| 9 | 测试平台（模块级 + 集成 + 等待态注入） | `tb/tb_ahb_*.sv` | ★★★ | 500~900 | 全部 |
| 10 | 文档 / README 更新 | `README.md`、本文件 | ★ | — | 全部 |

**合计**：RTL 约 **700~1100 行**，TB 约 **500~900 行**。

### 6.2 难度来源说明

| 难点 | 为什么难 | 缓解 |
| --- | --- | --- |
| 阶段 0 停顿通路 | 要同时处理「等待态保持地址/写数据」「flush 优先级高于 stall」「取指/数据两侧都被冻」；现有 `flush_*`/`stall_*` 语义已定型 | 先写 TB（插等待态的假从机），再改 RTL；保持 `flush > stall` 优先级不变 |
| 互连的仲裁与读回 | AHB 需要「地址相授权、数据相回送」两拍对齐；非授权主机要看到 `HREADY=0` 而保持传输 | 直接把现在的 `m_sel_q`（上一拍片选）思路翻译成 AHB 的读回 MUX |
| AHB→APB 桥 | setup/access 两相 + `PREADY` 拉长访问相 + 把 AHB 的响应带回 | 写成一个小 FSM（3~4 个状态），单独 TB 覆盖 |
| 回归风险 | 迁移会同时改 CPU 与 SoC 顶层 | 过渡期用 `ahb_rib_wrapper`；`tb_top` 作为门禁 |
| 阶段 0 未收尾 | 等待态下 store/load 数据通路仍有 1 项不符（§7） | 先修阶段 0 再动总线；`tb_cpu` 的 `WAIT_EN` 是红用例开关 |

---

## 7. 实施阶段（每阶段都有明确验收）

### 阶段 0：CPU 停顿通路补全（前置，**进行中，尚未完成**）

**已实现（`hold_flag_i` 现在是整流水线停顿，未来直接接 AHB `HREADY`）**

| 改动 | 说明 |
| --- | --- |
| 整流水线冻结 | `CPU_top`：`hold_flag_i`/`stall_pc` 现在同时冻结 `PCReg`、`IF2ID`、`ID2EX`、`EX2MEM`（访存地址/写数据保持）、`MEM2WB` |
| **取指地址寄存** | 新增 `if_addr_q`（送 ROM 的地址）+ `if_addr_hold` + `if_addr_d1`（配对）；停顿期间把 ROM 地址冻结在**上一拍的值**，否则 ROM 反复被同一个冻结 PC 寻址，**在途那条指令会永久丢失**（停顿后指令流跳一条）。无停顿时 `if_addr_q == if_pc`，行为零变化 |
| **MEM 读数据锁存** | 新增 `mem_rdata_q`：读数据只在传输完成那一拍有效；停顿会把流水线冻住，而总线地址仍来自 EX 级（下一条指令）。锁存窗口取「MEM 级是 load 且不是停顿的延续」，停顿第二拍起改用锁存值 |
| **停顿中不提交** | `Control` 新增 `ex_stall`：停顿中不允许重定向 / 陷入 / 受理中断（分支被冻在 EX 时不能在停顿期间跳转，否则取指流水与气泡错位）；`mret_en` 同样门控 |
| 验证 | `tb_control` 新增 5 项（停顿中不重定向/不异常/不陷入/不冲刷）；`tb_cpu` 新增等待态注入器（开关见下） |

**已验证**：单元 425 项 + `tb_rib_periph` 25 项 + **`tb_top` 118 项（RV32I 40/40 + Zicsr + 异常/中断）全部通过** —— 即以上改动对现有功能零影响。

**遗留问题（阻断阶段 0 完成）**

- `tb/tb_cpu.sv` 里的等待态注入开关 `WAIT_EN` 打开后（**当前默认 0，保持回归基线全绿**），仍有 **1 项失败**：
  `mem[7] lb 符号扩展 got=0xFFFFFFFF exp=0xFFFFFFFB` —— 即某次 `sb` + `lb` 在停顿介入后
  读到的是 `0xFF` 而非刚写入的 `0xFB`，指向**停顿跨越「store 提交 / load 取数」边界时的数据通路时序**。
- 已排除的假设：不是配对漂移（探测到非 4 字节 PC 的时刻就是程序里 JALR `&~1` 对齐用例的
  预期落点），不是 CSR/陷阱路径（tb_csr / tb_top 全绿）。

**下一步（建议按序）**

1. 把等待态注入打开（`WAIT_EN=1, WAIT_STRESS=0`）作为红用例，逐拍比对 store 的 `addr/be/wdata`
   与 load 的取数窗口，定位是「store 被重复提交」还是「load 取到了过期数据」；
2. 若确认是取指/访存相位耦合过深，按 §9「Option V」把取指改成显式 **valid/ready 槽**
   （`f_addr` + `f_valid`，PC 只在槽被消费时前进）—— 这样停顿、重定向、总线抢占三种情况
   可以完全解耦，也顺手删掉 `if_bus_stall` 的 NOP 注入与 `fetch_warmup` 等权宜逻辑；
3. 修好后把 `tb_cpu` 的 `WAIT_EN` 默认改为 1，并把 `WAIT_STRESS=1`（8 种等待长度/相位轮换）
   纳入常规回归。

### 阶段 1：AHB-Lite 接口 + CPU 主机适配器

- **改动**：新增 `ahb_master_adapter.sv`；`CPU_top` 增加 `size` 输出；适配器把 CPU 的 `addr/be/we/re/wdata` 翻译成 AHB 地址相/数据相，把 `HREADY` 接回停顿。
- **验收**：`tb_ahb_master` —— 用假从机验证：零等待读（1 拍）、写、以及等待态下地址/写数据保持。
- **产出**：CPU 侧说 AHB。

### 阶段 2：AHB-Lite 从机（ROM / RAM / 默认）

- **改动**：`ROM_Ctrl`/`RAM_Ctrl` 改造成 AHB-Lite 从机（内部仍例化同一个 BMG，配置不变）；新增默认从机。
- **验收**：`tb_ahb_rom` / `tb_ahb_ram`（用行为级 BMG 模型，跑在 `make unit` 流程里，免 IP）；读回、字节写通道、`HSIZE` 展开。
- **产出**：存储器挂得上 AHB。

### 阶段 3：AHB-Lite 互连

- **改动**：新增 `ahb_interconnect.sv`（2 主机 × 4 从机）：`HSEL` 解码、主机仲裁（数据 > 取指）、从机侧 MUX、读回/`HREADY`/`HRESP` 分发。
- **验收**：`tb_ahb_interconnect` —— 地址译码、争用优先级、非授权主机见 `HREADY=0`、未映射走默认从机。
- **产出**：可以整体替换 RIB（先用 `ahb_rib_wrapper` 过渡验证）。

### 阶段 4：AHB→APB 桥 + 4 个 APB 外设

- **改动**：新增 `ahb2apb.sv`；TIMER/SPI/UART/GPIO 端口换成 APB4（字节掩码改用 `PSTRB`，删掉各自重复的 `be_mask`）。
- **验收**：`tb_ahb2apb` + `tb_apb_periph`（寄存器读写、`PREADY` 拉长、SPI 传输、UART 发送、TIMER 溢出）。
- **产出**：外设标准化为 APB。

### 阶段 5：顶层集成 + 全量回归（**验收门禁**）

- **改动**：`CPU_SOC_top.sv` 换成新总线；删除 RIB 相关代码（保留 git 历史）。
- **验收（必须全部满足）**：
  1. **`make tb TB=tb_top` 保持全绿**（118 项：RV32I 40/40 + Zicsr + 异常/中断 + 外设 + UART 波形）；
  2. 新的集成 TB（取代 `tb_rib_periph`）覆盖译码/等待态/APB 访问；
  3. 模块级 420 项不退化；
  4. `make check` 通过。
- **产出**：SoC 总线 = AMBA。

### 阶段 6（可选）：错误响应与访问异常、对比与收尾

- 默认从机改为 `HRESP=ERROR` + CPU 侧实现 **load/store access fault（mcause 5/7）** —— 陷阱机制上一轮已经做好，这一步很自然；
- 综合对比 RIB vs AHB 的面积/时序（`make synth`，看 WNS 与 LUT/FF 变化）；
- 更新 README（目录结构、框图、设计要点、进度）。

---

## 8. 验证方案

| 层次 | 手段 | 说明 |
| --- | --- | --- |
| 模块级（免 IP） | `make unit TB=tb_ahb_master RTL="rtl/Bus/AHB/ahb_master_adapter.sv"` 等 | 沿用现有 `run_unit.tcl` 流程，快、可独立跑 |
| 等待态 | `tb_ahb_slow_slave`（假从机，可编程插入 N 拍 `HREADY=0`） | **验证阶段 0 的停顿通路**，也是迁移最容易出错的地方 |
| 从机功能 | 行为级 BMG 模型（与 `tb_cpu` 里 `beh_rom`/`beh_ram` 同语义） | 免 IP，含字节写通道检查 |
| 集成 | 新 `tb_ahb_periph`（取代 `tb_rib_periph`） | 译码、RAM 字节/半字写、GPIO/TIMER/UART/SPI 寄存器、`PREADY` |
| 系统级 | `tb_top`（ROM/RAM IP + 全部外设 + 真实程序） | **门禁**：RV32I 40/40 + Zicsr + 异常/中断全绿 |
| 覆盖率 | 沿用 `tb/prog/gen_cpu_test.py` 的期望值表机制 | 程序不用改，总线替换对外不可见 |

> 建议顺序：**先写阶段 0 的等待态 TB（红）→ 改 RTL（绿）→ 再动总线**。这样迁移期间任何异常都能定位到「总线 vs CPU」。

---

## 9. 风险与待决问题

### 9.1 风险

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| CPU 停顿通路不完整 | 一旦有等待态就错位，且难定位 | 阶段 0 先做 + 等待态 TB 先行 |
| 互连读回时序写错 | 读数据错拍（与上一轮 BRAM 延迟问题同类的坑） | 沿用「地址相选中、数据相回送」的显式对齐；TB 里逐拍断言 |
| 取指性能退化 | 若互连不做地址相重叠，可能 2 拍/次取指 | 明确要求：零等待从机下 **1 拍/次传输**，并在阶段 3 的 TB 里断言 |
| 回归面大 | 阶段 5 一次切换风险集中 | `ahb_rib_wrapper` 过渡 + 分阶段验收 + git 分支/tag |
| 时序变长 | 多一级读回 MUX | 阶段 6 用 `make synth` 对比；必要时把互连读回打一拍（但会引入等待态，需评估） |

### 9.2 待决问题（需要拍板）

1. **是否要为将来「与 Zynq PS 的 AXI 互联」预留**？是 → 阶段 6 加 AXI4-Lite↔AHB-Lite 转换器；否 → 只做 AHB-Lite（推荐先不做）。
2. **未映射地址**：保持「OKAY + 读 0」（现状、零改动），还是改成 `ERROR` + 访问异常（cause 5/7，需改默认从机 + Control + 新用例）？
3. **外设是否一并 APB 化**？推荐一并（标准做法、顺带删掉 4 份重复的字节掩码逻辑）；若想省一个桥，也可让外设直接做 AHB-Lite 从机（每个都要写 AHB 握手，工作量更大）。
4. **取指是否要求 1 拍/次**？推荐要求（否则取指退化，`tb_top` 的 UART/定时器轮询循环也会变慢）。
5. **RIB 是否保留**？推荐保留到阶段 5 验证通过（可用 `ahb_rib_wrapper` 过渡），通过后删除、只留 git 历史。
6. **是否需要 `HPROT`/`HMASTER`**？AHB5 的这些带外信号本项目用不到（无 cache/无安全域），建议固定值输出。

---

## 10. 迁移与回退策略

```text
分支建议：feature/amba-ahb-lite
  ├─ 阶段 0（CPU 停顿）        → 合入主干（与总线无关，独立有价值）
  ├─ 阶段 1~2（适配器/从机）   → 各自 TB 绿
  ├─ 阶段 3（互连）+ wrapper  → tb_top 仍跑通（RIB 被包成 AHB-Lite 从机）
  ├─ 阶段 4（APB）            → 集成 TB 绿
  └─ 阶段 5（切换 + 删 RIB）   → 门禁：tb_top 118 项全绿 → 合入主干
```

- **回退点**：阶段 5 之前主干上的 RIB 一直可用；阶段 5 的切换是一个独立 commit，出问题可 revert 单个提交。
- **不做的事**（避免范围膨胀）：不实现 AHB 突发/exclusive/secure/parity，不实现 AXI，不引入 Xilinx AXI Interconnect IP（保持可综合、可教学、可独立仿真）。

---

## 11. 参考资料

| 资料 | 用途 |
| --- | --- |
| Arm IHI0033《AMBA 5 AHB Protocol Specification》 | AHB-Lite 信号、地址相/数据相、`HREADY`/`HRESP` 语义 |
| Arm IHI0024《AMBA APB Protocol Specification》 | APB4 `PSEL/PENABLE/PREADY/PSTRB/PSLVERR` |
| Arm IHI0022《AMBA AXI Protocol Specification》 | 二期 AXI 转换器的依据 |
| Xilinx PG058《Block Memory Generator》 | ROM/RAM IP 的读延迟与字节写（从机封装里保持不变） |
| 本仓库 `README.md` §3.4 / §6.1 | 现有 RIB 结构、存储器时序与已踩过的坑（读回对齐、停顿时机） |

---

## 附：本方案相对现状的「保留 / 改动 / 删除」清单

| 分类 | 内容 |
| --- | --- |
| **保留** | CPU 核心（五级流水、前递、陷阱/CSR）、地址映射、BMG 配置、`tb_top` 与测试程序生成器、`sys_define.svh` 里的 BASE/MASK |
| **改动** | `CPU_top`（增加 `size` 输出、停顿通路、去掉 RIB 授权信号）、`CPU_SOC_top`（接新总线）、4 个外设（APB4 端口）、`ROM_Ctrl`/`RAM_Ctrl`（AHB-Lite 从机） |
| **删除** | `rtl/Bus/RIB_top.sv`、`rtl/Bus/Arbiter.sv`（或改写为 AHB 仲裁）、`if_bus_stall`/`if_bus_stall_d1` NOP 注入逻辑、`X_ALIAS_MASK` 在互连里的使用、`ram_be_o` 反推 size 的临时做法 |
