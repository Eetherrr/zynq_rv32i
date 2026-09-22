`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_branch — 分支条件与目标地址验证（重点：有符号/无符号边界）
//  运行： vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//           -tclargs tb_branch rtl/Core/EX/Branch.sv
//=====================================================================
module tb_branch;

    logic [`DATA_BUS] op1, op2, pc, imm, branch_target;
    logic [      2:0] br_sel;
    logic             branch, branch_taken;

    Branch u_dut (
        .op1(op1), .op2(op2), .pc(pc), .imm(imm), .branch(branch),
        .br_sel(br_sel), .branch_taken(branch_taken), .branch_target(branch_target)
    );

    int errors = 0, checks = 0;

    task automatic t(input string name, input logic [2:0] sel,
                     input logic [31:0] a, input logic [31:0] b,
                     input logic exp);
        br_sel = sel; op1 = a; op2 = b; branch = 1'b1; #1;
        checks = checks + 1;
        if (branch_taken !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %-34s a=%h b=%h taken=%b exp=%b", name, a, b, branch_taken, exp);
        end
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_branch - 分支条件与目标验证");
        $display("==========================================================");

        // ---- BEQ ----
        $display("\n-- BEQ --");
        t("beq 相等",        `INST_BEQ, 32'd5, 32'd5, 1'b1);
        t("beq 不等",        `INST_BEQ, 32'd5, 32'd6, 1'b0);
        t("beq 0==0",        `INST_BEQ, 32'd0, 32'd0, 1'b1);
        t("beq 高位差异",     `INST_BEQ, 32'h8000_0000, 32'd0, 1'b0);

        // ---- BNE ----
        $display("\n-- BNE --");
        t("bne 不等",        `INST_BNE, 32'd5, 32'd6, 1'b1);
        t("bne 相等",        `INST_BNE, 32'd5, 32'd5, 1'b0);

        // ---- BLT（有符号）----
        $display("\n-- BLT (signed) --");
        t("blt -1 < 0",      `INST_BLT, 32'hFFFF_FFFF, 32'd0, 1'b1);
        t("blt 0 < -1 假",   `INST_BLT, 32'd0, 32'hFFFF_FFFF, 1'b0);
        t("blt -2 < -1",     `INST_BLT, 32'hFFFF_FFFE, 32'hFFFF_FFFF, 1'b1);
        t("blt 最小负数<0",   `INST_BLT, 32'h8000_0000, 32'd0, 1'b1);
        t("blt 最大正数<0 假",`INST_BLT, 32'h7FFF_FFFF, 32'd0, 1'b0);
        t("blt 相等为假",     `INST_BLT, 32'd7, 32'd7, 1'b0);

        // ---- BGE（有符号）----
        $display("\n-- BGE (signed) --");
        t("bge 0 >= -1",     `INST_BGE, 32'd0, 32'hFFFF_FFFF, 1'b1);
        t("bge -1 >= 0 假",  `INST_BGE, 32'hFFFF_FFFF, 32'd0, 1'b0);
        t("bge 相等为真",     `INST_BGE, 32'd7, 32'd7, 1'b1);

        // ---- BLTU（无符号：与 BLT 在负数上相反）----
        $display("\n-- BLTU (unsigned) --");
        t("bltu 0xFFFFFFFF<0 假", `INST_BLTU, 32'hFFFF_FFFF, 32'd0, 1'b0);
        t("bltu 0<0xFFFFFFFF",    `INST_BLTU, 32'd0, 32'hFFFF_FFFF, 1'b1);
        t("bltu 5<6",             `INST_BLTU, 32'd5, 32'd6, 1'b1);
        t("bltu 相等为假",         `INST_BLTU, 32'd5, 32'd5, 1'b0);

        // ---- BGEU ----
        $display("\n-- BGEU (unsigned) --");
        t("bgeu 0xFFFFFFFF>=0",   `INST_BGEU, 32'hFFFF_FFFF, 32'd0, 1'b1);
        t("bgeu 0>=0xFFFFFFFF 假",`INST_BGEU, 32'd0, 32'hFFFF_FFFF, 1'b0);
        t("bgeu 相等为真",         `INST_BGEU, 32'd5, 32'd5, 1'b1);

        // ---- branch 有效位 ----
        $display("\n-- branch 有效位 --");
        br_sel = `INST_BEQ; op1 = 32'd1; op2 = 32'd1; branch = 1'b0; #1;
        checks = checks + 1;
        if (branch_taken !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] branch=0 时不应 taken");
        end

        // ---- 目标地址 ----
        $display("\n-- 分支目标地址 --");
        pc = 32'h0000_1000; imm = 32'd8; branch = 1'b1; br_sel = `INST_BEQ; #1;
        checks = checks + 1;
        if (branch_target !== 32'h0000_1008) begin
            errors = errors + 1;
            $display("  [FAIL] 正偏移目标 got=%h exp=00001008", branch_target);
        end
        pc = 32'h0000_1000; imm = 32'hFFFF_FFF8; #1;   // -8
        checks = checks + 1;
        if (branch_target !== 32'h0000_0FF8) begin
            errors = errors + 1;
            $display("  [FAIL] 负偏移目标 got=%h exp=00000ff8", branch_target);
        end
        pc = 32'h0000_0000; imm = 32'hFFFF_FFFC; #1;   // 0 + (-4)，回绕到 0xFFFFFFFC
        checks = checks + 1;
        if (branch_target !== 32'hFFFF_FFFC) begin
            errors = errors + 1;
            $display("  [FAIL] 0+(-4) 目标 got=%h exp=fffffffc", branch_target);
        end
        // 自跳：pc 指向自身，imm = -4
        pc = 32'h0000_2000; imm = 32'hFFFF_FFFC; #1;
        checks = checks + 1;
        if (branch_target !== 32'h0000_1FFC) begin
            errors = errors + 1;
            $display("  [FAIL] pc-4 目标 got=%h exp=00001ffc", branch_target);
        end

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_branch 全部通过");
        else             $display("==> tb_branch 存在失败");
        $display("==========================================================");
        $finish;
    end

endmodule
