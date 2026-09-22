`timescale 1ns / 1ps
`include "sys_define.svh"
// tb_regs — 寄存器堆验证：x0 硬连线、写使能、读穿透、复位
// 运行: vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//        -tclargs tb_regs rtl/Core/ID/Regs.sv
module tb_regs;
    logic clk = 0, rst_sys = `RESET_DIS;
    logic [`ADDR_BUS] rs1_addr, rs2_addr, rd_addr;
    logic [`DATA_BUS] rd_data, rs1_data, rs2_data;
    logic             we_flag;
    always #5 clk = ~clk;

    Regs u_dut (.clk_sys(clk), .rst_sys(rst_sys), .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
                .rs1_data(rs1_data), .rs2_data(rs2_data), .rd_addr(rd_addr),
                .rd_data(rd_data), .we_flag(we_flag));

    int errors = 0, checks = 0;
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1; $display("  [FAIL] %-40s got=%h exp=%h", n, g, e); end
    endtask
    task automatic wr(input int a, input logic [31:0] d);
        rd_addr = a[4:0]; rd_data = d; we_flag = 1'b1; @(posedge clk); #1; we_flag = 1'b0; #1;
    endtask
    task automatic rd2(input int a, input int b);
        rs1_addr = a[4:0]; rs2_addr = b[4:0]; #1;
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_regs - 寄存器堆验证");
        $display("==========================================================");
        rs1_addr=0; rs2_addr=0; rd_addr=0; rd_data=0; we_flag=0;

        // 先复位，清空寄存器堆（真实系统上电即如此）
        rst_sys = `RESET_EN; #1;
        rst_sys = `RESET_DIS; #1;

        $display("\n-- x0 硬连线 --");
        ck32("x0 读出为 0", rs1_data, 32'd0);
        wr(0, 32'hDEAD_BEEF);          // 写 x0 应被忽略
        rd2(0, 0); ck32("写 x0 后读出仍为 0", rs1_data, 32'd0);

        $display("\n-- 写入与读出 --");
        wr(1, 32'h1111_1111); wr(2, 32'h2222_2222); wr(31, 32'hFFFF_FFFF);
        rd2(1, 2); ck32("x1", rs1_data, 32'h1111_1111); ck32("x2", rs2_data, 32'h2222_2222);
        rd2(31, 1); ck32("x31", rs1_data, 32'hFFFF_FFFF);

        $display("\n-- 写使能无效时不应写入 --");
        rd_addr = 5'd5; rd_data = 32'hAAAA_AAAA; we_flag = 1'b0; @(posedge clk); #1;
        rd2(5, 0); ck32("we=0 未写 x5", rs1_data, 32'd0);
        wr(5, 32'h5555_5555);
        rd2(5, 0); ck32("we=1 写入 x5", rs1_data, 32'h5555_5555);

        $display("\n-- 同拍写读穿透（WB 写、ID 读同地址） --");
        // 组合读端口在 we_flag 有效且地址相同时应给出 rd_data
        rd_addr = 5'd7; rd_data = 32'h7777_7777; we_flag = 1'b1;
        rs1_addr = 5'd7; rs2_addr = 5'd7; #1;
        ck32("穿透读 rs1", rs1_data, 32'h7777_7777);
        ck32("穿透读 rs2", rs2_data, 32'h7777_7777);
        @(posedge clk); #1; we_flag = 1'b0;

        $display("\n-- 复位 --");
        rst_sys = `RESET_EN; #1;
        rd2(1, 2); ck32("复位时读 x1", rs1_data, 32'd0);
        ck32("复位时读 x2", rs2_data, 32'd0);
        rst_sys = `RESET_DIS; #1;

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_regs 全部通过"); else $display("==> tb_regs 存在失败");
        $display("==========================================================");
        $finish;
    end
endmodule
