`timescale 1ns / 1ps

`include "../../sys_define.svh"

module EX (
    input  logic [`DATA_BUS] id_ex_op1,         // ID 选好的 op1（ALU 用）
    input  logic [`DATA_BUS] id_ex_op2,         // ID 选好的 op2（ALU 用）
    input  logic [`DATA_BUS] id_ex_rs2_data,    // 寄存器堆读出的原始 rs2
    input  logic [`ADDR_BUS] id_ex_rs1_addr,
    input  logic [`ADDR_BUS] id_ex_rs2_addr,
    input  logic [      1:0] id_ex_op1_sel,
    input  logic [      0:0] id_ex_op2_sel,

    // 前递源 1: EX/MEM
    input  logic [`ADDR_BUS] ex_mem_rd_addr,
    input  logic [`DATA_BUS] ex_mem_alu_result,
    input  logic             ex_mem_rd_we,
    input  logic             ex_mem_mem_read,   // 1 = EX/MEM 级是 load
    input  logic [`DATA_BUS] ex_mem_load_data,  // EX/MEM 是 load 时的已提取数据
    input  logic             ex_mem_is_csr,     // 1 = EX/MEM 级是 CSR 指令
    input  logic [`DATA_BUS] ex_mem_csr_data,   // EX/MEM 是 CSR 指令时读出的旧值

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

    // EX/MEM 前递数据源
    //   访存地址在 EX 级发起（见 MEM_req），BRAM 的 1 拍读延迟落在 MEM 级，
    //   因此当 EX/MEM 级是 load 时，MEM 级组合提取出来的 mem_rdata_ext
    //   就是本条 load 的数据，可以直接前递给紧随其后的指令 ——
    //   这就是「load-use 不需要停顿」的原因：依赖指令在 EX 级的那一拍，
    //   load 正好在 MEM 级并把数据组合送到这里。
    //   若 EX/MEM 不是 load，前递源仍是 ALU 结果。
    logic [`DATA_BUS] ex_mem_fwd_data;

    //   · load：前递 MEM 级组合提取出的数据
    //   · CSR ：前递 CSR 读出的旧值（rd 写的就是它，而 alu_result 是垃圾）
    //   · 其它：前递 ALU 结果
    assign ex_mem_fwd_data = ex_mem_is_csr   ? ex_mem_csr_data
                           : ex_mem_mem_read ? ex_mem_load_data
                           :                   ex_mem_alu_result;

    assign hit_ex_mem_rs1 = ex_mem_rd_we
                         && (ex_mem_rd_addr != `REG_ZERO)
                         && (ex_mem_rd_addr == id_ex_rs1_addr);

    assign hit_ex_mem_rs2 = ex_mem_rd_we
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
        if      (hit_ex_mem_rs1) rs1_fwd = ex_mem_fwd_data;
        else if (hit_mem_wb_rs1) rs1_fwd = mem_wb_wdata;
        else                     rs1_fwd = id_ex_op1;
    end

    // ★ rs2 的「无前递」来源必须是寄存器堆读出的原始 rs2（id_ex_rs2_data），
    //   不能用 id_ex_op2：S 型的 op2_sel = OP2_IMM（那是地址偏移量），
    //   用它当 store 数据会在「rs2 没有前递来源」时把立即数写进内存。
    always_comb begin
        if      (hit_ex_mem_rs2) rs2_fwd = ex_mem_fwd_data;
        else if (hit_mem_wb_rs2) rs2_fwd = mem_wb_wdata;
        else                     rs2_fwd = id_ex_rs2_data;
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

