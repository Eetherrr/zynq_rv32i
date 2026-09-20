`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// EX2MEM : EX -> MEM 流水线寄存器
//   优先级：复位 > flush > stall
//   flush : 清空为 NOP（分支/Jump/异常时使用）
//   stall : 保持当前值（结构冒险时使用）
//=====================================================================
module EX2MEM (
    input  logic             clk_sys,
    input  logic             rst_sys,
    input  logic             flush,
    input  logic             stall,

    // ---------- 来自 EX 阶段 ----------
    input  logic [`DATA_BUS] ex_alu_result,     // ALU 结果
    input  logic [`DATA_BUS] ex_rs2_data,       // store 数据（前递后的 rs2）
    input  logic [`DATA_BUS] ex_pc,
    input  logic [`DATA_BUS] ex_pc4,            // PC + 4（JAL/JALR 写回用）
    input  logic [`ADDR_BUS] ex_rd_addr,
    input  logic             ex_rd_we,
    input  logic [      1:0] ex_wb_sel,
    input  logic [      1:0] ex_mem_size,
    input  logic             ex_mem_read,
    input  logic             ex_mem_write,
    input  logic             ex_mem_unsigned,

    // ---------- 输出到 MEM 阶段 ----------
    output logic [`DATA_BUS] mem_alu_result,
    output logic [`DATA_BUS] mem_rs2_data,
    output logic [`DATA_BUS] mem_pc,
    output logic [`DATA_BUS] mem_pc4,
    output logic [`ADDR_BUS] mem_rd_addr,
    output logic             mem_rd_we,
    output logic [      1:0] mem_wb_sel,
    output logic [      1:0] mem_size,
    output logic             mem_read,
    output logic             mem_write,
    output logic             mem_unsigned
);

    always @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            // ---------------- 复位 ----------------
            mem_alu_result <= 32'b0;
            mem_rs2_data   <= 32'b0;
            mem_pc         <= 32'b0;
            mem_pc4        <= 32'b0;
            mem_rd_addr    <= 5'b0;
            mem_rd_we      <= `DISABLE;
            mem_wb_sel     <= `WB_ALU;
            mem_size       <= `MSZ_W;
            mem_read       <= `DISABLE;
            mem_write      <= `DISABLE;
            mem_unsigned   <= `FALSE;
        end
        else if (flush) begin
            // ---------------- 清空为 NOP ----------------
            mem_alu_result <= 32'b0;
            mem_rs2_data   <= 32'b0;
            mem_pc         <= 32'b0;
            mem_pc4        <= 32'b0;
            mem_rd_addr    <= 5'b0;
            mem_rd_we      <= `DISABLE;
            mem_wb_sel     <= `WB_ALU;
            mem_size       <= `MSZ_W;
            mem_read       <= `DISABLE;
            mem_write      <= `DISABLE;
            mem_unsigned   <= `FALSE;
        end
        else if (!stall) begin
            // ---------------- 正常流水 ----------------
            mem_alu_result <= ex_alu_result;
            mem_rs2_data   <= ex_rs2_data;
            mem_pc         <= ex_pc;
            mem_pc4        <= ex_pc4;
            mem_rd_addr    <= ex_rd_addr;
            mem_rd_we      <= ex_rd_we;
            mem_wb_sel     <= ex_wb_sel;
            mem_size       <= ex_mem_size;
            mem_read       <= ex_mem_read;
            mem_write      <= ex_mem_write;
            mem_unsigned   <= ex_mem_unsigned;
        end
        // else : stall，保持当前值不变
    end

endmodule
