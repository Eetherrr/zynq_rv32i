`timescale 1ns / 1ps

`include "../../sys_define.svh"

module EX (
    input  logic [`DATA_BUS] id_ex_op1,
    input  logic [`DATA_BUS] id_ex_op2,
    input  logic [`ADDR_BUS] id_ex_rs1_addr,
    input  logic [`ADDR_BUS] id_ex_rs2_addr,
    input  logic [      1:0] id_ex_op1_sel,
    input  logic [      0:0] id_ex_op2_sel,

    // 前递源 1: EX/MEM
    input  logic [`ADDR_BUS] ex_mem_rd_addr,
    input  logic [`DATA_BUS] ex_mem_alu_result,
    input  logic             ex_mem_rd_we,
    input  logic             ex_mem_mem_read,   // 新增: load 时禁用此路前递

    // 前递源 2: MEM/WB
    input  logic [`ADDR_BUS] mem_wb_rd_addr,
    input  logic [`DATA_BUS] mem_wb_wdata,
    input  logic             mem_wb_rd_we,

    output logic [`DATA_BUS] alu_op1,
    output logic [`DATA_BUS] alu_op2,
    output logic [`DATA_BUS] br_op1,
    output logic [`DATA_BUS] br_op2,
    output logic [`DATA_BUS] jump_rs1
);

    logic hit_ex_mem_rs1, hit_ex_mem_rs2;
    logic hit_mem_wb_rs1, hit_mem_wb_rs2;

    // EX/MEM 是 load 时, alu_result 是地址不是数据, 禁止前递
    assign hit_ex_mem_rs1 = ex_mem_rd_we
                         && !ex_mem_mem_read
                         && (ex_mem_rd_addr != `REG_ZERO)
                         && (ex_mem_rd_addr == id_ex_rs1_addr);

    assign hit_ex_mem_rs2 = ex_mem_rd_we
                         && !ex_mem_mem_read
                         && (ex_mem_rd_addr != `REG_ZERO)
                         && (ex_mem_rd_addr == id_ex_rs2_addr);

    assign hit_mem_wb_rs1 = mem_wb_rd_we
                         && (mem_wb_rd_addr != `REG_ZERO)
                         && (mem_wb_rd_addr == id_ex_rs1_addr);

    assign hit_mem_wb_rs2 = mem_wb_rd_we
                         && (mem_wb_rd_addr != `REG_ZERO)
                         && (mem_wb_rd_addr == id_ex_rs2_addr);

    logic [`DATA_BUS] rs1_fwd, rs2_fwd;

    always_comb begin
        if      (hit_ex_mem_rs1) rs1_fwd = ex_mem_alu_result;
        else if (hit_mem_wb_rs1) rs1_fwd = mem_wb_wdata;
        else                     rs1_fwd = id_ex_op1;
    end

    always_comb begin
        if      (hit_ex_mem_rs2) rs2_fwd = ex_mem_alu_result;
        else if (hit_mem_wb_rs2) rs2_fwd = mem_wb_wdata;
        else                     rs2_fwd = id_ex_op2;
    end

    always_comb begin
        if (id_ex_op1_sel == `OP1_RS1 && (hit_ex_mem_rs1 || hit_mem_wb_rs1))
            alu_op1 = rs1_fwd;
        else
            alu_op1 = id_ex_op1;
    end

    always_comb begin
        if (id_ex_op2_sel == `OP2_RS2 && (hit_ex_mem_rs2 || hit_mem_wb_rs2))
            alu_op2 = rs2_fwd;
        else
            alu_op2 = id_ex_op2;
    end

    assign br_op1   = rs1_fwd;
    assign br_op2   = rs2_fwd;
    assign jump_rs1 = rs1_fwd;

endmodule

