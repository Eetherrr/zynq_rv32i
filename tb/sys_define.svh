// --------------------
// System
// --------------------
`define DATA_WIDTH 32
`define ADDR_WIDTH 5
`define INST_WIDTH 32
`define DATA_BUS 31:0
`define DATA_BUS_Z 32'bz
`define ADDR_BUS 4:0
`define INST_BUS 31:0

// 字节使能（4 字节通道）
`define BE_B 4'b0001   // 字节
`define BE_H 4'b0011   // 半字
`define BE_W 4'b1111   // 字

`define ENABLE 1'b1
`define DISABLE 1'b0
`define RESET_EN 1'b0
`define RESET_DIS 1'b1
`define TRUE 1'b1
`define FALSE 1'b0

`define REG_NUM 32

// --------------------
// Instruction Define
// --------------------
`define FCT7_L 7'b0000000
`define FCT7_A 7'b0100000
`define FCT3_PRIV 3'b000   // SYSTEM 类指令（ECALL/EBREAK/CSRxx）

// PC 复位向量
`define PC_RESET 32'h0000_0000

// --------------------
// RIB 地址映射
//   从机选中条件： (addr & MASK) == BASE
//   MASK 为覆盖该从机地址空间所需的全 1 掩码
//
//   *_ALIAS_MASK 用于把总线地址裁成「从机内部偏移」：
//       offset = addr & ALIAS_MASK
//   这样即使从机基址落在 0x1000_0000 这样的高地址，其内部仍只用
//   小范围索引（如 RAM 用 offset[15:2] 取 16K 个字），无需 64MB 存储。
// --------------------
`define ROM_BASE   32'h0000_0000   // 指令 ROM  16 KiB
`define ROM_MASK   32'hFFFF_C000
`define ROM_ALIAS_MASK 32'h0000_3FFF

`define RAM_BASE   32'h1000_0000   // 数据 RAM  64 KiB
`define RAM_MASK   32'hFFFF_0000
`define RAM_ALIAS_MASK 32'h0000_FFFF

`define TIMER_BASE 32'h2000_0000   // 定时器    1 KiB
`define TIMER_MASK 32'hFFFF_FC00
`define TIMER_ALIAS_MASK 32'h0000_03FF

`define SPI_BASE   32'h2000_0400   // SPI       1 KiB
`define SPI_MASK   32'hFFFF_FC00
`define SPI_ALIAS_MASK 32'h0000_03FF

`define UART_BASE  32'h2000_0800   // UART      1 KiB
`define UART_MASK  32'hFFFF_FC00
`define UART_ALIAS_MASK 32'h0000_03FF

`define GPIO_BASE  32'h2000_0C00   // GPIO      1 KiB
`define GPIO_MASK  32'hFFFF_FC00
`define GPIO_ALIAS_MASK 32'h0000_03FF

// 流水线气泡
`define INST_NOP 32'h0000_0013

// R-type
`define INST_TYPE_R 7'b0110011  // opcode
`define INST_ADD_SUB 3'b000
`define INST_SLL 3'b001
`define INST_SLT 3'b010
`define INST_SLTU 3'b011
`define INST_XOR 3'b100
`define INST_SR 3'b101
`define INST_OR 3'b110
`define INST_AND 3'b111

// I-type
`define INST_TYPE_I 7'b0010011  // opcode
`define INST_ADDI 3'b000
`define INST_SLLI 3'b001
`define INST_SLTI 3'b010
`define INST_SLTIU 3'b011
`define INST_XORI 3'b100
`define INST_SRI 3'b101
`define INST_ORI 3'b110
`define INST_ANDI 3'b111
// Load
`define INST_TYPE_L 7'b0000011  // opcode
`define INST_LB 3'b000
`define INST_LH 3'b001
`define INST_LW 3'b010
`define INST_LBU 3'b100
`define INST_LHU 3'b101
// Reg Jump
`define INST_JALR 7'b1100111    // opcode
`define FCT3_JALR 3'b000
// System
`define INST_TYPE_SYS 7'b1110011
`define INST_ECALL 3'b000
`define INST_EBREAK 3'b000
// S-type
`define INST_TYPE_S 7'b0100011
`define INST_SB 3'b000
`define INST_SH 3'b001
`define INST_SW 3'b010

// B-type
`define INST_TYPE_B 7'b1100011
`define INST_BEQ 3'b000
`define INST_BNE 3'b001
`define INST_BLT 3'b100
`define INST_BGE 3'b101
`define INST_BLTU 3'b110
`define INST_BGEU 3'b111

// J_type
`define INST_JAL 7'b1101111

// U-type
`define INST_LUI 7'b0110111     // opcode
`define INST_AUIPC 7'b0010111   // opcode

// FENCE
`define INST_TYPE_FENCE 7'b0001111
`define INST_FENCE 3'b000



// ALU Opcode
`define ALU_ADD  4'b0000
`define ALU_SUB  4'b0001
`define ALU_SLL  4'b0010
`define ALU_SLT  4'b0011
`define ALU_SLTU 4'b0100
`define ALU_XOR  4'b0101
`define ALU_SRL  4'b0110
`define ALU_SRA  4'b0111
`define ALU_OR   4'b1000
`define ALU_AND  4'b1001

// op1 sel
`define OP1_RS1  2'b00
`define OP1_PC   2'b01
`define OP1_ZERO 2'b10
// op2 sel
`define OP2_RS2 1'b0
`define OP2_IMM 1'b1

// wb sel
`define WB_ALU 2'b00
`define WB_MEM 2'b01
`define WB_PC4 2'b10    // 写回PC+4（JAL/JALR）

// mem size
`define MSZ_B 2'b00
`define MSZ_H 2'b01
`define MSZ_W 2'b10

// -----------------------------------------------------------
// Registers Address Map
//
// ┌─────────────────────────────────────────────────────────┐
// │                    32 General Regs                      │
// ├─────────────┬───────────────────┬───────────────────────┤
// │  Special    │       Call        │    General Work       │
// ├─────────────┼───────────────────┼───────────────────────┤
// │ x0  (zero)  │ x1   (ra)         │ x5-t0, x6-t1, x7-t2   │
// │ x2  (sp)    │ x8   (s0/fp)      │ x28-t3, x29-t4        │
// │ x3  (gp)    │ x9   (s1)         │ x30-t5, x31-t6        │
// │ x4  (tp)    │ x10-a0 ~ x17-a7   │                       │
// │             │ x18-s2 ~ x27-s11  │                       │
// └─────────────┴───────────────────┴───────────────────────┘
//
// -----------------------------------------------------------


`define REG_ZERO 5'd0   // 硬连线零，读取恒为 0，写入无效
`define REG_RA 5'd1     // 返回地址（Return Address）
`define REG_SP 5'd2     // 栈指针（Stack Pointer）
`define REG_GP 5'd3     // 全局指针（Global Pointer）
`define REG_TP 5'd4     // 线程指针（Thread Pointer）

`define REG_T0 5'd5     // 临时寄存器 / 链接暂存
`define REG_T1 5'd6     // 临时寄存器
`define REG_T2 5'd7     // 临时寄存器
`define REG_T3 5'd28    // 临时寄存器
`define REG_T4 5'd29    // 临时寄存器
`define REG_T5 5'd30    // 临时寄存器
`define REG_T6 5'd31    // 临时寄存器

`define REG_S0 5'd8     // 保存寄存器
`define REG_FP 5'd8     // AKA: 帧指针（Frame Pointer）
`define REG_S1 5'd9     // 保存寄存器
`define REG_S2 5'd18    // 保存寄存器
`define REG_S3 5'd19    // 保存寄存器
`define REG_S4 5'd20    // 保存寄存器
`define REG_S5 5'd21    // 保存寄存器
`define REG_S6 5'd22    // 保存寄存器
`define REG_S7 5'd23    // 保存寄存器
`define REG_S8 5'd24    // 保存寄存器
`define REG_S9 5'd25    // 保存寄存器
`define REG_S10 5'd26   // 保存寄存器
`define REG_S11 5'd27   // 保存寄存器

`define REG_A0 5'd10    // 函数参数 0 / 返回值 0
`define REG_A1 5'd11    // 函数参数 1 / 返回值 1
`define REG_A2 5'd12    // 函数参数 2
`define REG_A3 5'd13    // 函数参数 3
`define REG_A4 5'd14    // 函数参数 4
`define REG_A5 5'd15    // 函数参数 5
`define REG_A6 5'd16    // 函数参数 6
`define REG_A7 5'd17    // 函数参数 7 / 系统调用号

