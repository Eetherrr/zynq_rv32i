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
    input  wire [`DATA_BUS]  ex_branch_target,
    input  wire [`DATA_BUS]  ex_jump_target,
    input  wire              ex_illegal,
    input  wire              ex_ecall,
    input  wire              ex_ebreak,

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
    output logic             exception_en
);

    logic redirect, exception;

    assign redirect  = ex_branch_taken | ex_jump_taken;
    assign exception = ex_illegal | ex_ecall | ex_ebreak;

    // flush: 全部下游流水寄存器清 NOP
    assign flush_if2id  = redirect | exception;
    assign flush_id2ex  = redirect | exception;
    assign flush_ex2mem = redirect | exception;
    assign flush_mem2wb = 1'b0;   // WB 阶段无需 flush

    // stall: 当前微架构无数据冒险停顿（见文件头说明）
    assign stall_pc     = 1'b0;
    assign stall_if2id  = 1'b0;
    assign stall_id2ex  = 1'b0;

    // 重定向
    assign redirect_en  = redirect;
    assign redirect_pc  = ex_branch_taken ? ex_branch_target
                                          : ex_jump_target;
    assign exception_en = exception;

endmodule
