`timescale 1ns / 1ps
`include "sys_define.svh"
// tb_ex — EX 级前递验证（含 EX/MEM 优先、load 阻塞、x0/rd_we 屏蔽）
// 运行: vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//        -tclargs tb_ex rtl/Core/EX/EX.sv
module tb_ex;
    logic [`DATA_BUS] id_ex_op1, id_ex_op2;
    logic [`ADDR_BUS] id_ex_rs1_addr, id_ex_rs2_addr;
    logic [1:0] id_ex_op1_sel;
    logic [0:0] id_ex_op2_sel;
    logic [`ADDR_BUS] ex_mem_rd_addr, mem_wb_rd_addr;
    logic [`DATA_BUS] ex_mem_alu_result, mem_wb_wdata;
    logic             ex_mem_rd_we, ex_mem_mem_read, mem_wb_rd_we;
    logic [`DATA_BUS] alu_op1, alu_op2, br_op1, br_op2, jump_rs1;

    EX u_dut (
        .id_ex_op1(id_ex_op1), .id_ex_op2(id_ex_op2),
        .id_ex_rs1_addr(id_ex_rs1_addr), .id_ex_rs2_addr(id_ex_rs2_addr),
        .id_ex_op1_sel(id_ex_op1_sel), .id_ex_op2_sel(id_ex_op2_sel),
        .ex_mem_rd_addr(ex_mem_rd_addr), .ex_mem_alu_result(ex_mem_alu_result),
        .ex_mem_rd_we(ex_mem_rd_we), .ex_mem_mem_read(ex_mem_mem_read),
        .mem_wb_rd_addr(mem_wb_rd_addr), .mem_wb_wdata(mem_wb_wdata),
        .mem_wb_rd_we(mem_wb_rd_we),
        .alu_op1(alu_op1), .alu_op2(alu_op2), .br_op1(br_op1), .br_op2(br_op2),
        .jump_rs1(jump_rs1)
    );

    int errors = 0, checks = 0;
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1; $display("  [FAIL] %-44s got=%h exp=%h", n, g, e); end
    endtask

    // 便于批量设置
    task automatic set(input int rs1, input int rs2,
                       input logic [31:0] op1, input logic [31:0] op2,
                       input logic [1:0] o1s, input logic [0:0] o2s);
        id_ex_rs1_addr = rs1[4:0]; id_ex_rs2_addr = rs2[4:0];
        id_ex_op1 = op1; id_ex_op2 = op2; id_ex_op1_sel = o1s; id_ex_op2_sel = o2s;
    endtask
    task automatic exmem(input int rd, input logic [31:0] v, input logic we, input logic ld);
        ex_mem_rd_addr = rd[4:0]; ex_mem_alu_result = v; ex_mem_rd_we = we; ex_mem_mem_read = ld;
    endtask
    task automatic memwb(input int rd, input logic [31:0] v, input logic we);
        mem_wb_rd_addr = rd[4:0]; mem_wb_wdata = v; mem_wb_rd_we = we;
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_ex - EX 前递验证");
        $display("==========================================================");
        exmem(0,0,0,0); memwb(0,0,0);

        $display("\n-- 无前递：用寄存器堆值 --");
        set(1,2, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2);
        #1;
        ck32("无命中 alu_op1", alu_op1, 32'hA1);
        ck32("无命中 alu_op2", alu_op2, 32'hB2);

        $display("\n-- EX/MEM 前递 --");
        set(5,6, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2);
        exmem(5, 32'hE5E5, 1'b1, 1'b0);   // rd5 在 EX/MEM，非 load
        #1;
        ck32("rs1 命中 EX/MEM", alu_op1, 32'hE5E5);
        set(9,5, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2); #1;
        ck32("rs2 命中 EX/MEM", alu_op2, 32'hE5E5);

        $display("\n-- MEM/WB 前递 --");
        exmem(0,0,0,0);
        set(5,6, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2);
        memwb(5, 32'hF5F5, 1'b1); #1;
        ck32("rs1 命中 MEM/WB", alu_op1, 32'hF5F5);

        $display("\n-- 优先级：EX/MEM 高于 MEM/WB --");
        exmem(5, 32'hE5E5, 1'b1, 1'b0); memwb(5, 32'hF5F5, 1'b1);
        set(5,5, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2); #1;
        ck32("两者都命中时取 EX/MEM", alu_op1, 32'hE5E5);

        $display("\n-- load 时禁止 EX/MEM 前递（数据还没回来） --");
        exmem(5, 32'h1000_0000, 1'b1, 1'b1);  // mem_read=1 -> alu_result 是地址
        memwb(0, 0, 1'b0);
        set(5,6, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2); #1;
        ck32("load 阻断 EX/MEM，退回原值", alu_op1, 32'hA1);
        // 但 MEM/WB 仍应可前递
        memwb(5, 32'hF5F5, 1'b1); #1;
        ck32("load 时 MEM/WB 仍前递", alu_op1, 32'hF5F5);

        $display("\n-- rd_we=0 不前递 --");
        exmem(5, 32'hE5E5, 1'b0, 1'b0); memwb(0,0,0);
        set(5,6, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2); #1;
        ck32("EX/MEM rd_we=0 不前递", alu_op1, 32'hA1);
        memwb(5, 32'hF5F5, 1'b0); #1;
        ck32("MEM/WB rd_we=0 不前递", alu_op1, 32'hA1);

        $display("\n-- x0 不参与前递 --");
        exmem(0, 32'hE0E0, 1'b1, 1'b0); memwb(0, 32'hF0F0, 1'b1);
        set(0,0, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2); #1;
        ck32("rd=x0 不前递 rs1", alu_op1, 32'hA1);
        ck32("rd=x0 不前递 rs2", alu_op2, 32'hB2);

        $display("\n-- op1_sel/op2_sel 非寄存器时不前递 --");
        exmem(5, 32'hE5E5, 1'b1, 1'b0); memwb(5, 32'hF5F5, 1'b1);
        // op1_sel=PC：立即数/PC 不参与前递
        set(5,5, 32'h0000_1000, 32'h0000_00FF, `OP1_PC, `OP2_IMM); #1;
        ck32("op1_sel=PC 不前递", alu_op1, 32'h0000_1000);
        ck32("op2_sel=IMM 不前递", alu_op2, 32'h0000_00FF);

        $display("\n-- 分支/跳转操作数也走前递 --");
        set(5,5, 32'hA1, 32'hB2, `OP1_RS1, `OP2_RS2);
        exmem(5, 32'hE5E5, 1'b1, 1'b0); memwb(0,0,0); #1;
        ck32("br_op1 前递", br_op1, 32'hE5E5);
        ck32("br_op2 前递", br_op2, 32'hE5E5);
        ck32("jump_rs1 前递", jump_rs1, 32'hE5E5);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_ex 全部通过"); else $display("==> tb_ex 存在失败");
        $display("==========================================================");
        $finish;
    end
endmodule
