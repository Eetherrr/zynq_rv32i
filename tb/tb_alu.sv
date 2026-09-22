`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_alu — ALU 全运算验证（含边界与符号语义）
//  运行： vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//           -tclargs tb_alu rtl/Core/EX/ALU.sv
//=====================================================================
module tb_alu;

    logic [`DATA_BUS] op1, op2, result;
    logic [      3:0] alu_op;

    ALU u_dut (.op1(op1), .op2(op2), .alu_op(alu_op), .result(result));

    int errors = 0, checks = 0;

    task automatic t(input string name, input logic [3:0] op,
                     input logic [31:0] a, input logic [31:0] b,
                     input logic [31:0] exp);
        alu_op = op; op1 = a; op2 = b; #1;
        checks = checks + 1;
        if (result !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %-30s %h %h -> %h (exp %h)", name, a, b, result, exp);
        end
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_alu - ALU 全运算验证");
        $display("==========================================================");

        // ---- ADD ----
        $display("\n-- ADD --");
        t("add 1+2",        `ALU_ADD, 32'd1, 32'd2, 32'd3);
        t("add 0+0",        `ALU_ADD, 32'd0, 32'd0, 32'd0);
        t("add 溢出回绕",    `ALU_ADD, 32'hFFFF_FFFF, 32'd1, 32'h0000_0000);
        t("add 大数",        `ALU_ADD, 32'h7FFF_FFFF, 32'd1, 32'h8000_0000);

        // ---- SUB ----
        $display("\n-- SUB --");
        t("sub 5-3",        `ALU_SUB, 32'd5, 32'd3, 32'd2);
        t("sub 3-5 负结果",  `ALU_SUB, 32'd3, 32'd5, 32'hFFFF_FFFE);
        t("sub 0-1",        `ALU_SUB, 32'd0, 32'd1, 32'hFFFF_FFFF);
        t("sub 相等",        `ALU_SUB, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 32'd0);

        // ---- SLL ----（只用 op2 低 5 位）
        $display("\n-- SLL --");
        t("sll 1<<0",       `ALU_SLL, 32'd1, 32'd0, 32'd1);
        t("sll 1<<31",      `ALU_SLL, 32'd1, 32'd31, 32'h8000_0000);
        t("sll shamt 取模32",`ALU_SLL, 32'd1, 32'd32, 32'd1);        // 32&31=0
        t("sll shamt 33",   `ALU_SLL, 32'd1, 32'd33, 32'd2);        // 33&31=1
        t("sll 高位溢出",    `ALU_SLL, 32'h8000_0000, 32'd1, 32'd0);

        // ---- SRL ----（逻辑右移，高位补 0）
        $display("\n-- SRL --");
        t("srl 0x80000000>>1", `ALU_SRL, 32'h8000_0000, 32'd1, 32'h4000_0000);
        t("srl >>31",          `ALU_SRL, 32'hFFFF_FFFF, 32'd31, 32'd1);
        t("srl shamt 取模",     `ALU_SRL, 32'hFFFF_FFFF, 32'd32, 32'hFFFF_FFFF);

        // ---- SRA ----（算术右移，高位补符号位）
        $display("\n-- SRA --");
        t("sra 负数>>1",      `ALU_SRA, 32'h8000_0000, 32'd1, 32'hC000_0000);
        t("sra -1>>1 保持-1", `ALU_SRA, 32'hFFFF_FFFF, 32'd1, 32'hFFFF_FFFF);
        t("sra 正数>>1",      `ALU_SRA, 32'h7FFF_FFFE, 32'd1, 32'h3FFF_FFFF);
        t("sra >>31 得符号位", `ALU_SRA, 32'h8000_0000, 32'd31, 32'hFFFF_FFFF);

        // ---- SLT ----（有符号比较）
        $display("\n-- SLT --");
        t("slt -1<0",        `ALU_SLT, 32'hFFFF_FFFF, 32'd0, 32'd1);
        t("slt 0<-1 假",     `ALU_SLT, 32'd0, 32'hFFFF_FFFF, 32'd0);
        t("slt -2147483648<0",`ALU_SLT, 32'h8000_0000, 32'd0, 32'd1);
        t("slt 相等",         `ALU_SLT, 32'd7, 32'd7, 32'd0);
        t("slt 正数",         `ALU_SLT, 32'd3, 32'd5, 32'd1);

        // ---- SLTU ----（无符号比较：与 SLT 在负数上结论相反）
        $display("\n-- SLTU --");
        t("sltu 0xFFFFFFFF<0 假", `ALU_SLTU, 32'hFFFF_FFFF, 32'd0, 32'd0);
        t("sltu 0<0xFFFFFFFF",    `ALU_SLTU, 32'd0, 32'hFFFF_FFFF, 32'd1);
        t("sltu 3<5",             `ALU_SLTU, 32'd3, 32'd5, 32'd1);
        t("sltu 相等",            `ALU_SLTU, 32'd9, 32'd9, 32'd0);

        // ---- XOR / OR / AND ----
        $display("\n-- 逻辑运算 --");
        t("xor",            `ALU_XOR, 32'hF0F0_F0F0, 32'h0F0F_0F0F, 32'hFFFF_FFFF);
        t("xor 自异或=0",   `ALU_XOR, 32'h1234_5678, 32'h1234_5678, 32'd0);
        t("or",             `ALU_OR,  32'hF000_0000, 32'h0000_000F, 32'hF000_000F);
        t("and",            `ALU_AND, 32'hFF00_FF00, 32'h0FF0_0FF0, 32'h0F00_0F00);
        t("and 与0",        `ALU_AND, 32'hFFFF_FFFF, 32'd0, 32'd0);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_alu 全部通过");
        else             $display("==> tb_alu 存在失败");
        $display("==========================================================");
        $finish;
    end

endmodule
