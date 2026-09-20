`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// IF2ID : IF -> ID 流水线寄存器
//   优先级：复位 > flush > stall
//     flush : 清空为 NOP（分支/跳转/异常时使用）
//     stall : 保持当前值（load-use / 结构冒险时使用）
//
//   instr_o == 32'h00000013 (NOP) 作为气泡标记，
//   也可配合 valid 位使用；此处沿用你原有模块，不额外加 valid。
//=====================================================================
module IF2ID (
    // System
    input  wire              clk_sys,
    input  wire              rst_sys,
    // Control
    input  wire              flush,
    input  wire              stall,
    input  wire [`DATA_BUS]  flush_pc,

    // ---------- 来自 IF 阶段 ----------
    input  wire [`DATA_BUS]  instr_i,
    input  wire [`DATA_BUS]  instr_addr_i,

    // ---------- 输出到 ID 阶段 ----------
    output logic [`DATA_BUS] instr_o,
    output logic [`DATA_BUS] instr_addr_o
);

    always @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            instr_o      <= `INST_NOP;
            instr_addr_o <= 32'b0;
        end
        else if (flush) begin
            instr_o      <= `INST_NOP;
            instr_addr_o <= flush_pc;
        end
        else if (!stall) begin
            instr_o      <= instr_i;
            instr_addr_o <= instr_addr_i;
        end
    end

endmodule
