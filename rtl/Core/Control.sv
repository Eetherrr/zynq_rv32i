`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// Control : 冒险 / 控制单元
//
//   本流水线采用「全前递 + EX 级发起访存」的微架构，因此：
//     - 普通 RAW 冒险：EX/MEM、MEM/WB 前递解决；
//     - load-use 冒险：**不需要停顿**。访存地址在 EX 级发起（MEM_req），
//       BRAM 的 1 拍读延迟落在 MEM 级，MEM 级组合提取出的 load 数据直接
//       前递给紧随其后的指令（见 EX.sv 的 ex_mem_load_data）。
//       依赖指令在 EX 级的那一拍，load 正好在 MEM 级，数据同拍可用。
//     - 结构冒险：数据访问占用 RIB 时取指口丢一拍，由 CPU_top 冻结 PC
//       并向 IF2ID 注入 NOP 处理（不经过本模块）。
//
//   因此本模块只产生「冲刷 + 重定向」：分支 / 跳转 / 异常在 EX 级解析，
//   冲刷 ID / EX / MEM 三个下游流水寄存器，并把 PC 重定向到目标。
//
//   stall_* 三个输出保留（当前恒为 0），供将来接入需要等待的外设
//   （由外设拉高 hold_flag_i 时在 CPU_top 侧冻结）或多周期访存使用。
//=====================================================================
module Control (
    input  wire              clk_sys,
    input  wire              rst_sys,

    // 来自 EX 阶段
    input  wire              ex_branch_taken,
    input  wire              ex_jump_taken,
    input  wire [`DATA_BUS]  ex_pc,                 // EX 级指令 PC（陷阱记录 mepc）
    input  wire [`DATA_BUS]  ex_branch_target,
    input  wire [`DATA_BUS]  ex_jump_target,
    input  wire              ex_illegal,
    input  wire              ex_ecall,
    input  wire              ex_ebreak,
    input  wire              ex_load_misaligned,    // load 地址非对齐
    input  wire              ex_store_misaligned,   // store 地址非对齐
    input  wire              ex_csr_illegal,        // CSR 地址非法 / 写只读 CSR
    input  wire              interrupt_req,         // mip.MTIP & mie.MTIE & mstatus.MIE
    input  wire [`DATA_BUS]  mtvec,                 // 陷阱向量
    input  wire              mret_en,               // MRET（返回 mepc）
    input  wire [`DATA_BUS]  mepc,

    // EX 阶段当前指令 (来自 ID2EX) —— 保留给将来实现异常 / 中断
    input  wire [`ADDR_BUS]  id_ex_rd_addr,
    input  wire              id_ex_rd_we,
    input  wire              id_ex_mem_read,

    // ID 阶段当前指令 —— 保留给将来的冒险检测
    input  wire [`INST_BUS]  id_instr,
    input  wire [`ADDR_BUS]  id_rs1_addr,
    input  wire [`ADDR_BUS]  id_rs2_addr,

    // 输出
    output logic             flush_if2id,
    output logic             flush_id2ex,
    output logic             flush_ex2mem,
    output logic             flush_mem2wb,
    output logic             stall_pc,
    output logic             stall_if2id,
    output logic             stall_id2ex,

    // 重定向
    output logic             redirect_en,
    output logic [`DATA_BUS] redirect_pc,
    output logic             exception_en,
    output logic             trap_en,          // 本拍进入陷阱（异常或中断）
    output logic [`DATA_BUS] trap_cause,
    output logic [`DATA_BUS] trap_pc
);

    logic redirect, exception, trap;

    assign redirect  = ex_branch_taken | ex_jump_taken;
    assign exception = ex_illegal | ex_ecall | ex_ebreak |
                       ex_load_misaligned | ex_store_misaligned | ex_csr_illegal;

    // 中断只在没有同步异常时受理（同一指令上异常优先）
    assign trap      = exception | (interrupt_req & ~exception);

    //---- 陷阱 cause（mcause）----
    always_comb begin
        if      (ex_illegal || ex_csr_illegal) trap_cause = `CAUSE_ILLEGAL_INSTR;
        else if (ex_ebreak)                    trap_cause = `CAUSE_BREAKPOINT;
        else if (ex_ecall)                     trap_cause = `CAUSE_ECALL_M;
        else if (ex_load_misaligned)           trap_cause = `CAUSE_LOAD_MISALIGN;
        else if (ex_store_misaligned)          trap_cause = `CAUSE_STORE_MISALIGN;
        else if (interrupt_req)                trap_cause = `CAUSE_IRQ_M_TIMER;
        else                                   trap_cause = 32'b0;
    end

    // mepc：同步异常 = 出错指令 PC；中断 = 被打断指令 PC（由 CSR 模块记录）
    assign trap_pc = ex_pc;

    // flush:
    //   · 重定向只冲刷「更年轻」的 IF/ID 与 ID/EX —— **不能冲刷 EX2MEM**：
    //     JAL / JALR 正是产生重定向的那条指令，而它还要把返回地址
    //     （PC+4，wb_sel = WB_PC4）经 EX2MEM → MEM2WB 写回 rd。
    //     若连 EX2MEM 一起清空，`jal ra, func` / `jalr ra, 0(rs1)` 这类
    //     函数调用的返回地址就永远写不进寄存器（分支不写回，所以以前没暴露）。
    //   · 异常才需要把 EX2MEM 也清掉：出错指令不允许写回
    //     （illegal / ecall / ebreak 的 rd_we 本来就是 0）。
    assign flush_if2id  = redirect | trap;
    assign flush_id2ex  = redirect | trap;
    //   · 分支/跳转重定向不清 EX2MEM（JAL/JALR 链接值要写回）
    //   · 陷阱清 EX2MEM：出错/被打断的指令不写回
    assign flush_ex2mem = trap;
    assign flush_mem2wb = 1'b0;   // WB 阶段无需 flush

    // stall: 当前微架构无数据冒险停顿（见文件头说明）
    assign stall_pc     = 1'b0;
    assign stall_if2id  = 1'b0;
    assign stall_id2ex  = 1'b0;

    // 重定向优先级：陷阱 > MRET > 分支 > 跳转
    assign redirect_en  = trap | mret_en | redirect;
    always_comb begin
        if      (trap)              redirect_pc = mtvec;
        else if (mret_en)           redirect_pc = mepc;
        else if (ex_branch_taken)   redirect_pc = ex_branch_target;
        else                        redirect_pc = ex_jump_target;
    end
    assign exception_en = exception;
    assign trap_en      = trap;

endmodule
