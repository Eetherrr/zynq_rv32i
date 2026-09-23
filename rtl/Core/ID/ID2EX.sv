`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// ID2EX : ID -> EX 流水线寄存器
//   优先级 : 复位 > flush > stall
//   flush  : 清空为 NOP
//   stall  : 保持当前值 (本设计中恒为 0，作为预留)
//=====================================================================
module ID2EX (
    // System
    input  wire              clk_sys,
    input  wire              rst_sys,
    // Control
    input  wire              flush,
    input  wire              stall,

    // ---------- 来自 IF2ID / Decoder / ID ----------
    input  wire [`DATA_BUS]  id_pc,             // 来自 IF2ID 的 instr_addr_o
    input  wire [`ADDR_BUS]  id_rs1_addr,       // Decoder 输出
    input  wire [`ADDR_BUS]  id_rs2_addr,       // Decoder 输出
    input  wire [`ADDR_BUS]  id_rd_addr,        // Decoder 输出
    input  wire              id_rd_we,
    input  wire [      3:0]  id_alu_op,
    input  wire [      1:0]  id_op1_sel,
    input  wire [      0:0]  id_op2_sel,
    input  wire [`DATA_BUS]  id_op1,            // ID 模块选好的 op1
    input  wire [`DATA_BUS]  id_op2,            // ID 模块选好的 op2
    input  wire [`DATA_BUS]  id_rs2_data,       // 寄存器堆读出的原始 rs2
                                                //  （store 数据用它，不能用 op2：
                                                //   S 型 op2_sel=IMM，是地址偏移量）
    input  wire [`DATA_BUS]  id_imm,
    input  wire [      1:0]  id_wb_sel,
    input  wire [      1:0]  id_mem_size,
    input  wire              id_mem_read,
    input  wire              id_mem_write,
    input  wire              id_mem_unsigned,
    input  wire              id_branch,
    input  wire [      2:0]  id_br_sel,
    input  wire              id_jump,
    input  wire              id_jump_reg,
    input  wire              id_illegal,
    input  wire              id_ecall,
    input  wire              id_ebreak,
    input  wire              id_fence,
    // Zicsr / 陷阱返回
    input  wire              id_csr_en,
    input  wire [      2:0]  id_csr_op,
    input  wire [     11:0]  id_csr_addr,
    input  wire              id_csr_imm,
    input  wire [      4:0]  id_csr_uimm,
    input  wire              id_csr_we,
    input  wire              id_mret,

    // ---------- 输出到 EX ----------
    output logic [`DATA_BUS] id_ex_pc,
    output logic [`ADDR_BUS] id_ex_rs1_addr,
    output logic [`ADDR_BUS] id_ex_rs2_addr,
    output logic [`ADDR_BUS] id_ex_rd_addr,
    output logic             id_ex_rd_we,
    output logic [      3:0] id_ex_alu_op,
    output logic [      1:0] id_ex_op1_sel,
    output logic [      0:0] id_ex_op2_sel,
    output logic [`DATA_BUS] id_ex_op1,
    output logic [`DATA_BUS] id_ex_op2,
    output logic [`DATA_BUS] id_ex_rs2_data,
    output logic [`DATA_BUS] id_ex_imm,
    output logic [      1:0] id_ex_wb_sel,
    output logic [      1:0] id_ex_mem_size,
    output logic             id_ex_mem_read,
    output logic             id_ex_mem_write,
    output logic             id_ex_mem_unsigned,
    output logic             id_ex_branch,
    output logic [      2:0] id_ex_br_sel,
    output logic             id_ex_jump,
    output logic             id_ex_jump_reg,
    output logic             id_ex_illegal,
    output logic             id_ex_ecall,
    output logic             id_ex_ebreak,
    output logic             id_ex_fence,

    // Zicsr / 陷阱返回
    output logic             id_ex_csr_en,
    output logic [      2:0] id_ex_csr_op,
    output logic [     11:0] id_ex_csr_addr,
    output logic             id_ex_csr_imm,
    output logic [      4:0] id_ex_csr_uimm,
    output logic             id_ex_csr_we,
    output logic             id_ex_mret,

    // 该级是否是「真实指令」（0 = 冲刷出来的气泡）
    //   中断只在真实指令上受理，否则 mepc 会记到气泡的 PC(=0) 上
    output logic             id_ex_valid
);

    always @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            // ---------------- 复位 ----------------
            id_ex_pc            <= 32'b0;
            id_ex_rs1_addr      <= 5'b0;
            id_ex_rs2_addr      <= 5'b0;
            id_ex_rd_addr       <= 5'b0;
            id_ex_rd_we         <= `DISABLE;
            id_ex_alu_op        <= `ALU_ADD;
            id_ex_op1_sel       <= `OP1_RS1;
            id_ex_op2_sel       <= `OP2_RS2;
            id_ex_op1           <= 32'b0;
            id_ex_op2           <= 32'b0;
            id_ex_rs2_data      <= 32'b0;
            id_ex_imm           <= 32'b0;
            id_ex_wb_sel        <= `WB_ALU;
            id_ex_mem_size      <= `MSZ_W;
            id_ex_mem_read      <= `DISABLE;
            id_ex_mem_write     <= `DISABLE;
            id_ex_mem_unsigned  <= `FALSE;
            id_ex_branch        <= `FALSE;
            id_ex_br_sel        <= `INST_BEQ;
            id_ex_jump          <= `FALSE;
            id_ex_jump_reg      <= `FALSE;
            id_ex_illegal       <= `FALSE;
            id_ex_ecall         <= `FALSE;
            id_ex_ebreak        <= `FALSE;
            id_ex_fence         <= `FALSE;
            id_ex_csr_en        <= `FALSE;
            id_ex_csr_op        <= `CSR_OP_RW;
            id_ex_csr_addr      <= 12'b0;
            id_ex_csr_imm       <= `FALSE;
            id_ex_csr_uimm      <= 5'b0;
            id_ex_csr_we        <= `FALSE;
            id_ex_mret          <= `FALSE;
            id_ex_valid         <= `FALSE;
        end
        else if (flush) begin
            // ---------------- 清空为 NOP ----------------
            id_ex_pc            <= 32'b0;
            id_ex_rs1_addr      <= 5'b0;
            id_ex_rs2_addr      <= 5'b0;
            id_ex_rd_addr       <= 5'b0;
            id_ex_rd_we         <= `DISABLE;
            id_ex_alu_op        <= `ALU_ADD;
            id_ex_op1_sel       <= `OP1_RS1;
            id_ex_op2_sel       <= `OP2_RS2;
            id_ex_op1           <= 32'b0;
            id_ex_op2           <= 32'b0;
            id_ex_rs2_data      <= 32'b0;
            id_ex_imm           <= 32'b0;
            id_ex_wb_sel        <= `WB_ALU;
            id_ex_mem_size      <= `MSZ_W;
            id_ex_mem_read      <= `DISABLE;
            id_ex_mem_write     <= `DISABLE;
            id_ex_mem_unsigned  <= `FALSE;
            id_ex_branch        <= `FALSE;
            id_ex_br_sel        <= `INST_BEQ;
            id_ex_jump          <= `FALSE;
            id_ex_jump_reg      <= `FALSE;
            id_ex_illegal       <= `FALSE;
            id_ex_ecall         <= `FALSE;
            id_ex_ebreak        <= `FALSE;
            id_ex_fence         <= `FALSE;
            id_ex_csr_en        <= `FALSE;
            id_ex_csr_op        <= `CSR_OP_RW;
            id_ex_csr_addr      <= 12'b0;
            id_ex_csr_imm       <= `FALSE;
            id_ex_csr_uimm      <= 5'b0;
            id_ex_csr_we        <= `FALSE;
            id_ex_mret          <= `FALSE;
            id_ex_valid         <= `FALSE;
        end
        else if (!stall) begin
            // ---------------- 正常流水 ----------------
            id_ex_pc            <= id_pc;
            id_ex_rs1_addr      <= id_rs1_addr;
            id_ex_rs2_addr      <= id_rs2_addr;
            id_ex_rd_addr       <= id_rd_addr;
            id_ex_rd_we         <= id_rd_we;
            id_ex_alu_op        <= id_alu_op;
            id_ex_op1_sel       <= id_op1_sel;
            id_ex_op2_sel       <= id_op2_sel;
            id_ex_op1           <= id_op1;
            id_ex_op2           <= id_op2;
            id_ex_rs2_data      <= id_rs2_data;
            id_ex_imm           <= id_imm;
            id_ex_wb_sel        <= id_wb_sel;
            id_ex_mem_size      <= id_mem_size;
            id_ex_mem_read      <= id_mem_read;
            id_ex_mem_write     <= id_mem_write;
            id_ex_mem_unsigned  <= id_mem_unsigned;
            id_ex_branch        <= id_branch;
            id_ex_br_sel        <= id_br_sel;
            id_ex_jump          <= id_jump;
            id_ex_jump_reg      <= id_jump_reg;
            id_ex_illegal       <= id_illegal;
            id_ex_ecall         <= id_ecall;
            id_ex_ebreak        <= id_ebreak;
            id_ex_fence         <= id_fence;
            id_ex_csr_en        <= id_csr_en;
            id_ex_csr_op        <= id_csr_op;
            id_ex_csr_addr      <= id_csr_addr;
            id_ex_csr_imm       <= id_csr_imm;
            id_ex_csr_uimm      <= id_csr_uimm;
            id_ex_csr_we        <= id_csr_we;
            id_ex_mret          <= id_mret;
            id_ex_valid         <= `TRUE;
        end
    end

endmodule
