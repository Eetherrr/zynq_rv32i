`timescale 1ns / 1ps
`include "sys_define.svh"
// tb_mem — 访存通路：请求生成（MEM_req）+ 读数据通路（MEM_load）
//   MEM_req 在 EX 级产生地址/写数据/字节使能（地址提前一拍，
//   让 BRAM 的 1 拍读延迟正好落在 MEM 级）；
//   MEM_load 在 MEM 级做对齐检查、通道提取、符号/零扩展。
// 运行: vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//        -tclargs tb_mem rtl/Core/MEM/MEM_req.sv rtl/Core/MEM/MEM_load.sv
module tb_mem;
    // ---- MEM_req ----
    logic [`DATA_BUS] mem_alu_result, mem_rs2_data;
    logic [1:0]       mem_size;
    logic             mem_read, mem_write;
    logic [`DATA_BUS] mem_addr, mem_wdata;
    logic [3:0]       mem_be;
    logic             mem_req, mem_we;

    // ---- MEM_load ----
    logic [`DATA_BUS] mem_rdata, mem_rdata_ext;
    logic             mem_unsigned, mem_align_err;

    MEM_req u_req (
        .mem_alu_result(mem_alu_result), .mem_rs2_data(mem_rs2_data),
        .mem_size(mem_size), .mem_read(mem_read), .mem_write(mem_write),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_req(mem_req), .mem_we(mem_we));

    MEM_load u_load (
        .mem_alu_result(mem_alu_result), .mem_size(mem_size),
        .mem_read(mem_read), .mem_write(mem_write),
        .mem_unsigned(mem_unsigned), .mem_rdata(mem_rdata),
        .mem_rdata_ext(mem_rdata_ext), .mem_align_err(mem_align_err));

    int errors = 0, checks = 0;
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1; $display("  [FAIL] %-42s got=%h exp=%h", n, g, e); end
    endtask
    task automatic ck1(input string n, input logic g, input logic e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1; $display("  [FAIL] %-42s got=%b exp=%b", n, g, e); end
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_mem - 访存请求生成 / 对齐 / 通道 / 扩展验证");
        $display("==========================================================");
        mem_read=0; mem_write=0; mem_unsigned=0; mem_size=`MSZ_W;
        mem_alu_result=0; mem_rs2_data=0; mem_rdata=0; #1;

        $display("\n-- MEM_req: mem_req / mem_we --");
        mem_read=1; mem_write=0; #1; ck1("读: req=1 we=0", mem_req, 1'b1); ck1("读: we=0", mem_we, 1'b0);
        mem_read=0; mem_write=1; #1; ck1("写: req=1 we=1", mem_req, 1'b1); ck1("写: we=1", mem_we, 1'b1);
        mem_read=0; mem_write=0; #1; ck1("空闲: req=0", mem_req, 1'b0);

        $display("\n-- MEM_load: 地址对齐检查 --");
        mem_read=1; mem_write=0;
        mem_size=`MSZ_B; mem_alu_result=32'h1001; #1; ck1("字节 任意地址 无对齐错", mem_align_err, 1'b0);
        mem_size=`MSZ_H; mem_alu_result=32'h1000; #1; ck1("半字 偶地址 ok", mem_align_err, 1'b0);
        mem_size=`MSZ_H; mem_alu_result=32'h1001; #1; ck1("半字 奇地址 报错", mem_align_err, 1'b1);
        mem_size=`MSZ_W; mem_alu_result=32'h1000; #1; ck1("字 4 对齐 ok", mem_align_err, 1'b0);
        mem_size=`MSZ_W; mem_alu_result=32'h1001; #1; ck1("字 未对齐 报错", mem_align_err, 1'b1);
        mem_size=`MSZ_W; mem_alu_result=32'h1002; #1; ck1("字 半字对齐 报错", mem_align_err, 1'b1);
        // 非访存指令不报对齐错
        mem_read=0; mem_write=0; mem_size=`MSZ_W; mem_alu_result=32'h1001; #1;
        ck1("非访存不报对齐错", mem_align_err, 1'b0);

        $display("\n-- MEM_req: 字节使能（写） --");
        mem_write=1; mem_read=0;
        mem_rs2_data = 32'hAABB_CCDD;
        mem_size=`MSZ_B; mem_alu_result=32'h0; #1; ck32("SB @0 be=0001", {28'b0,mem_be}, 32'h1);
        mem_alu_result=32'h1; #1; ck32("SB @1 be=0010", {28'b0,mem_be}, 32'h2);
        mem_alu_result=32'h2; #1; ck32("SB @2 be=0100", {28'b0,mem_be}, 32'h4);
        mem_alu_result=32'h3; #1; ck32("SB @3 be=1000", {28'b0,mem_be}, 32'h8);
        mem_size=`MSZ_H; mem_alu_result=32'h0; #1; ck32("SH @0 be=0011", {28'b0,mem_be}, 32'h3);
        mem_alu_result=32'h2; #1; ck32("SH @2 be=1100", {28'b0,mem_be}, 32'hC);
        mem_size=`MSZ_W; mem_alu_result=32'h0; #1; ck32("SW be=1111", {28'b0,mem_be}, 32'hF);

        $display("\n-- MEM_req: 写数据字节通道对齐 --");
        mem_size=`MSZ_B;
        mem_alu_result=32'h0; #1; ck32("SB @0 数据在 lane0", mem_wdata, 32'h0000_00DD);
        mem_alu_result=32'h1; #1; ck32("SB @1 数据在 lane1", mem_wdata, 32'h0000_DD00);
        mem_alu_result=32'h2; #1; ck32("SB @2 数据在 lane2", mem_wdata, 32'h00DD_0000);
        mem_alu_result=32'h3; #1; ck32("SB @3 数据在 lane3", mem_wdata, 32'hDD00_0000);
        mem_size=`MSZ_H;
        mem_alu_result=32'h0; #1; ck32("SH @0 低半字", mem_wdata, 32'h0000_CCDD);
        mem_alu_result=32'h2; #1; ck32("SH @2 高半字", mem_wdata, 32'hCCDD_0000);
        mem_size=`MSZ_W; mem_alu_result=32'h0; #1; ck32("SW 全字", mem_wdata, 32'hAABB_CCDD);

        $display("\n-- MEM_load: 加载数据提取 + 符号/零扩展 --");
        mem_read=1; mem_write=0;
        mem_rdata = 32'h807F_80FF;   // lane0=FF lane1=80 lane2=7F lane3=80
        mem_size=`MSZ_B; mem_unsigned=0;
        mem_alu_result=32'h0; #1; ck32("LB @0 0xFF 符号扩展", mem_rdata_ext, 32'hFFFF_FFFF);
        mem_alu_result=32'h1; #1; ck32("LB @1 0x80 符号扩展", mem_rdata_ext, 32'hFFFF_FF80);
        mem_alu_result=32'h2; #1; ck32("LB @2 0x7F 符号扩展", mem_rdata_ext, 32'h0000_007F);
        mem_alu_result=32'h3; #1; ck32("LB @3 0x80 符号扩展", mem_rdata_ext, 32'hFFFF_FF80);
        mem_unsigned=1;
        mem_alu_result=32'h0; #1; ck32("LBU @0 零扩展", mem_rdata_ext, 32'h0000_00FF);
        mem_alu_result=32'h1; #1; ck32("LBU @1 零扩展", mem_rdata_ext, 32'h0000_0080);
        mem_size=`MSZ_H; mem_unsigned=0;
        mem_alu_result=32'h0; #1; ck32("LH @0 0x80FF 符号扩展", mem_rdata_ext, 32'hFFFF_80FF);
        mem_alu_result=32'h2; #1; ck32("LH @2 0x807F 符号扩展", mem_rdata_ext, 32'hFFFF_807F);
        mem_unsigned=1;
        mem_alu_result=32'h0; #1; ck32("LHU @0 零扩展", mem_rdata_ext, 32'h0000_80FF);
        mem_size=`MSZ_W; mem_unsigned=0;
        mem_alu_result=32'h0; #1; ck32("LW 全字", mem_rdata_ext, 32'h807F_80FF);

        $display("\n-- 非 load 时 mem_rdata_ext 应为 0 --");
        mem_read=0; mem_write=0; mem_size=`MSZ_W; mem_alu_result=32'h0; #1;
        ck32("非 load 输出 0", mem_rdata_ext, 32'h0);

        $display("\n-- mem_addr 直通 ALU 结果（EX 级提前发起地址）--");
        mem_alu_result = 32'hDEAD_BEEF; #1;
        ck32("mem_addr = alu_result", mem_addr, 32'hDEAD_BEEF);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_mem 全部通过"); else $display("==> tb_mem 存在失败");
        $display("==========================================================");
        $finish;
    end
endmodule
