`timescale 1ns / 1ps
`include "sys_define.svh"
//=====================================================================
// tb_csr — CSR / 陷阱入口 / MRET / 中断挂起 单元验证
//   运行: vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//          -tclargs tb_csr rtl/Core/CSR/CSR.sv
//=====================================================================
module tb_csr;
    logic        clk = 0, rst_sys = `RESET_EN;
    always #5 clk = ~clk;

    logic [11:0] csr_addr;
    logic [31:0] csr_rdata;
    logic        csr_valid, csr_writable;
    logic        csr_we;
    logic [11:0] csr_addr_w;
    logic [31:0] csr_wdata;
    logic        trap_en, mret_en;
    logic [31:0] trap_cause, trap_pc, trap_vector;
    logic [7:0]  int_i;
    logic        mip_mtip, irq_pending;
    logic [31:0] mstatus_o, mepc_o, mcause_o, mie_o;

    CSR u_dut (
        .clk_sys(clk), .rst_sys(rst_sys),
        .csr_addr(csr_addr), .csr_rdata(csr_rdata),
        .csr_valid(csr_valid), .csr_writable(csr_writable),
        .csr_we(csr_we), .csr_addr_w(csr_addr_w), .csr_wdata(csr_wdata),
        .trap_en(trap_en), .trap_cause(trap_cause), .trap_pc(trap_pc),
        .mret_en(mret_en), .trap_vector(trap_vector),
        .int_i(int_i), .mip_mtip(mip_mtip), .irq_pending(irq_pending),
        .mstatus_o(mstatus_o), .mepc_o(mepc_o), .mcause_o(mcause_o), .mie_o(mie_o)
    );

    int errors = 0, checks = 0;
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1;
            $display("  [FAIL] %-44s got=%h exp=%h", n, g, e); end
    endtask
    task automatic ck1(input string n, input logic g, input logic e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1;
            $display("  [FAIL] %-44s got=%b exp=%b", n, g, e); end
    endtask

    // 写一个 CSR（在时钟沿提交）
    task automatic wr(input logic [11:0] a, input logic [31:0] d);
        csr_we = 1'b1; csr_addr_w = a; csr_wdata = d;
        @(posedge clk); #1; csr_we = 1'b0;
    endtask

    task automatic rd(input logic [11:0] a);
        csr_addr = a; #1;
    endtask

    int i;
    initial begin
        $display("==========================================================");
        $display(" tb_csr - CSR / 陷阱 / MRET / 中断 验证");
        $display("==========================================================");

        csr_we = 0; csr_addr = 0; csr_addr_w = 0; csr_wdata = 0;
        trap_en = 0; trap_cause = 0; trap_pc = 0; mret_en = 0; int_i = 0;

        // ---- 复位 ----
        rst_sys = `RESET_EN;
        repeat (3) @(posedge clk);
        rst_sys = `RESET_DIS;
        repeat (2) @(posedge clk);
        #1;

        $display("\n-- 复位值与只读寄存器 --");
        rd(`CSR_MISA);    ck32("misa = 0x40000100 (MXL=1,I)", csr_rdata, 32'h4000_0100);
        ck1("misa 只读", csr_writable, 1'b0);
        rd(`CSR_MTVAL);   ck32("mtval 复位 0", csr_rdata, 32'h0);
        ck1("mtval 只读", csr_writable, 1'b0);
        rd(`CSR_MIP);     ck32("mip 复位 0", csr_rdata, 32'h0);
        ck1("mip 只读", csr_writable, 1'b0);
        rd(`CSR_MSTATUS); ck32("mstatus 复位 0", csr_rdata, 32'h0);
        rd(`CSR_MTVEC);   ck32("mtvec 复位 0", csr_rdata, 32'h0);

        $display("\n-- 地址译码 / 非法地址 --");
        rd(12'h000);       ck1("0x000 未实现", csr_valid, 1'b0);
        rd(12'hC00);       ck1("0xC00 未实现", csr_valid, 1'b0);
        rd(`CSR_MSCRATCH); ck1("mscratch 已实现", csr_valid, 1'b1);
        ck1("mscratch 可写", csr_writable, 1'b1);

        $display("\n-- 读写普通 CSR --");
        wr(`CSR_MSCRATCH, 32'hDEAD_BEEF);
        rd(`CSR_MSCRATCH); ck32("mscratch 读回", csr_rdata, 32'hDEAD_BEEF);

        wr(`CSR_MCAUSE, 32'h8000_0007);
        rd(`CSR_MCAUSE);   ck32("mcause 读回（含中断位）", csr_rdata, 32'h8000_0007);

        $display("\n-- mepc / mtvec：低 2 位强制 0（IALIGN=32，direct 模式）--");
        wr(`CSR_MEPC, 32'h1234_567B);
        rd(`CSR_MEPC);     ck32("mepc 低 2 位清零", csr_rdata, 32'h1234_5678);
        wr(`CSR_MTVEC, 32'h0000_0F03);
        rd(`CSR_MTVEC);    ck32("mtvec mode 强制 0", csr_rdata, 32'h0000_0F00);
        ck32("trap_vector = mtvec", trap_vector, 32'h0000_0F00);

        $display("\n-- mstatus：只实现 MIE/MPIE/MPP --");
        wr(`CSR_MSTATUS, 32'hFFFF_FFFF);
        rd(`CSR_MSTATUS);
        ck32("mstatus 仅保留 MIE|MPIE|MPP",
             csr_rdata, (32'd3 << 11) | (32'd1 << 7) | (32'd1 << 3));

        $display("\n-- mie：只实现 MTIE(bit7) --");
        wr(`CSR_MIE, 32'h0000_00FF);
        rd(`CSR_MIE);      ck32("mie 仅保留 MTIE", csr_rdata, 32'h0000_0080);

        $display("\n-- mip / irq_pending --");
        int_i = 8'h01; #1;
        rd(`CSR_MIP);      ck32("mip.MTIP 跟随 int_i[0]", csr_rdata, 32'h0000_0080);
        ck1("MTIE&MIE 都置位 -> pending", irq_pending, 1'b1);
        wr(`CSR_MSTATUS, 32'd0);      // 关 MIE
        rd(`CSR_MSTATUS); #1;
        ck1("MIE=0 -> 不 pending", irq_pending, 1'b0);
        wr(`CSR_MSTATUS, 32'd8);      // 开 MIE
        #1;
        ck1("MIE=1 -> pending", irq_pending, 1'b1);

        $display("\n-- 陷阱入口：mepc/mcause/mstatus --");
        trap_pc = 32'h0000_0134; trap_cause = `CAUSE_ECALL_M; trap_en = 1'b1;
        @(posedge clk); #1; trap_en = 1'b0;
        rd(`CSR_MEPC);    ck32("mepc = 陷阱指令 PC", csr_rdata, 32'h0000_0134);
        rd(`CSR_MCAUSE);  ck32("mcause = ECALL(11)", csr_rdata, `CAUSE_ECALL_M);
        rd(`CSR_MSTATUS);
        ck32("陷阱后 MIE=0 / MPIE=旧MIE", csr_rdata, (32'd3 << 11) | (32'd1 << 7));
        ck1("陷阱后中断被关", irq_pending, 1'b0);

        $display("\n-- MRET：MIE←MPIE，MPIE←1 --");
        mret_en = 1'b1;
        @(posedge clk); #1; mret_en = 1'b0;
        rd(`CSR_MSTATUS); ck32("MRET 后 MIE 恢复", csr_rdata, (32'd3 << 11) | (32'd1 << 7) | (32'd1 << 3));
        ck1("MRET 后中断重新使能", irq_pending, 1'b1);

        $display("\n-- 只读寄存器写入被忽略 --");
        wr(`CSR_MISA, 32'h0);
        wr(`CSR_MTVAL, 32'hFFFF_FFFF);
        wr(`CSR_MIP, 32'h0);
        rd(`CSR_MISA);  ck32("misa 写无效", csr_rdata, 32'h4000_0100);
        rd(`CSR_MTVAL); ck32("mtval 恒 0", csr_rdata, 32'h0);

        $display("\n-- 读端口同拍写前递（连续两条 CSR 指令操作同一寄存器）--");
        rd(`CSR_MSCRATCH); ck32("无待写时读到寄存器值", csr_rdata, 32'hDEAD_BEEF);
        csr_we = 1'b1; csr_addr_w = `CSR_MSCRATCH; csr_wdata = 32'h1122_3344;
        rd(`CSR_MSCRATCH); #1;
        ck32("有同地址待写：前递新值", csr_rdata, 32'h1122_3344);
        @(posedge clk); #1; csr_we = 1'b0;      // 走一个沿才真正提交
        rd(`CSR_MSCRATCH); ck32("提交后读到新值", csr_rdata, 32'h1122_3344);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_csr 全部通过"); else $display("==> tb_csr 存在失败");
        $display("==========================================================");
        $finish;
    end
endmodule
