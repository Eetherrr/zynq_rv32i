`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_jump — JAL / JALR 目标地址验证
//  运行： vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//           -tclargs tb_jump rtl/Core/EX/Jump.sv
//=====================================================================
module tb_jump;

    logic [`DATA_BUS] pc, rs1, imm, jump_target;
    logic             jump, jump_reg, jump_taken;

    Jump u_dut (.pc(pc), .rs1(rs1), .imm(imm), .jump(jump),
                .jump_reg(jump_reg), .jump_taken(jump_taken), .jump_target(jump_target));

    int errors = 0, checks = 0;

    task automatic t(input string name, input logic [31:0] p, input logic [31:0] r,
                     input logic [31:0] i, input logic jr,
                     input logic exp_tk, input logic [31:0] exp_tgt);
        pc = p; rs1 = r; imm = i; jump = 1'b1; jump_reg = jr; #1;
        checks = checks + 1;
        if (jump_taken !== exp_tk || jump_target !== exp_tgt) begin
            errors = errors + 1;
            $display("  [FAIL] %-32s pc=%h rs1=%h imm=%h jr=%b -> tk=%b tgt=%h (exp %b %h)",
                     name, p, r, i, jr, jump_taken, jump_target, exp_tk, exp_tgt);
        end
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_jump - JAL / JALR 目标地址验证");
        $display("==========================================================");

        $display("\n-- JAL（pc + imm，PC 相对）--");
        t("jal +16",       32'h100, 32'd0,       32'd16,        1'b0, 1'b1, 32'h110);
        t("jal -4",        32'h100, 32'd0,       32'hFFFF_FFFC, 1'b0, 1'b1, 32'h0FC);
        t("jal +0",        32'h100, 32'd0,       32'd0,         1'b0, 1'b1, 32'h100);
        t("jal 大偏移",     32'h0000_0000, 32'd0, 32'h0007_FFFE, 1'b0, 1'b1, 32'h0007_FFFE);
        t("jal 负大偏移",   32'h0008_0000, 32'd0, 32'hFFF8_0000, 1'b0, 1'b1, 32'h0000_0000);

        $display("\n-- JALR（(rs1 + imm) & ~1）--");
        t("jalr rs1=0x1000,off=8",  32'h0, 32'h1000, 32'd8,  1'b1, 1'b1, 32'h1008);
        t("jalr 奇地址清 bit0",      32'h0, 32'h1001, 32'd0,  1'b1, 1'b1, 32'h1000);
        t("jalr 奇结果清 bit0",      32'h0, 32'h1000, 32'd1,  1'b1, 1'b1, 32'h1000);
        t("jalr 负偏移",            32'h0, 32'h1000, 32'hFFFF_FFF8, 1'b1, 1'b1, 32'h0FF8);
        t("jalr 结果奇+负",         32'h0, 32'h1002, 32'hFFFF_FFFF, 1'b1, 1'b1, 32'h1000);
        t("jalr rs1 高位",          32'h0, 32'h8000_0000, 32'd4, 1'b1, 1'b1, 32'h8000_0004);
        t("jalr 与 PC 无关",        32'hDEAD_0000, 32'h2000, 32'd0, 1'b1, 1'b1, 32'h2000);
        // JALR 回绕
        t("jalr 回绕",              32'h0, 32'hFFFF_FFFC, 32'd8, 1'b1, 1'b1, 32'h0000_0004);

        $display("\n-- jump 有效位 --");
        pc = 32'h100; rs1 = 32'd0; imm = 32'd8; jump = 1'b0; jump_reg = 1'b0; #1;
        checks = checks + 1;
        if (jump_taken !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] jump=0 时不应 taken");
        end

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_jump 全部通过");
        else             $display("==> tb_jump 存在失败");
        $display("==========================================================");
        $finish;
    end

endmodule
