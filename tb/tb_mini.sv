`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_mini — 最小 store/load 回读定位平台（诊断用，不是正式回归）
//
//   载入 tb/prog/mini_load.hex：
//     lui x5,0x10000 ; addi x6,x0,0xAA ; sw x6,0(x5) ; lw x7,0(x5)
//     addi x8,x7,0   ; sw x7,4(x5) ; jal x0,0
//   期望 x7 = 0xAA、RAM[0x1000_0000] = 0xAA、RAM[0x1000_0004] = 0xAA
//
//   同时打印每一次数据口总线事务与读回数据，用于定位 load 通路问题。
//   运行： make tb TB=tb_mini
//=====================================================================
module tb_mini;

    parameter real CLK_PERIOD = 10.0;
    // 仿真在 sim/xsim_run 下执行，故用相对于该目录的路径
    parameter      PROG_FILE  = "../../tb/prog/mini_load.hex";
    parameter int  PROG_WORDS = 4096;

    logic clk_sys   = 1'b0;
    logic rst_async = 1'b0;
    always #(CLK_PERIOD/2.0) clk_sys = ~clk_sys;

    wire        uart_tx, spi_sclk, spi_mosi, spi_ss_n, timer_irq;
    wire [7:0]  gpio_o, gpio_t;
    logic [7:0] gpio_i;
    assign gpio_i = gpio_o;

    CPU_SOC_top u_dut (
        .clk_sys(clk_sys), .rst_async(rst_async),
        .uart_rx(1'b1), .uart_tx(uart_tx),
        .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(1'b1),
        .spi_ss_n(spi_ss_n),
        .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_t(gpio_t),
        .timer_irq(timer_irq)
    );

    wire [31:0] mem_addr  = u_dut.cpu_ram_addr;
    wire [31:0] mem_wdata = u_dut.cpu_ram_wdata;
    wire        mem_we    = u_dut.cpu_ram_we;
    wire        mem_re    = u_dut.cpu_ram_re;
    wire [31:0] cur_pc    = u_dut.u_CPU_top.if_pc;

    // 只记录数据口事务
    always @(posedge clk_sys) begin
        if (u_dut.cpu_ram_we || u_dut.cpu_ram_re)
            $display("[TX] t=%0t if_pc=%h %s addr=%h wdata=%h rdata=%h",
                     $time, cur_pc, u_dut.cpu_ram_we ? "WR" : "RD",
                     mem_addr, mem_wdata, u_dut.cpu_ram_rdata);
    end

    int fd, i;
    logic [31:0] prog [0:PROG_WORDS-1];

    initial begin
        for (i = 0; i < PROG_WORDS; i = i + 1) prog[i] = 32'h0000_0013;
        fd = $fopen(PROG_FILE, "r");
        if (fd == 0) begin
            $display("[FATAL] 打不开 %s", PROG_FILE);
            $finish;
        end
        $fclose(fd);
        $readmemh(PROG_FILE, prog);
        for (i = 0; i < PROG_WORDS; i = i + 1) u_dut.u_ROM.mem[i] = prog[i];
        $display("==> 已载入 %s", PROG_FILE);
        for (i = 0; i < 8; i = i + 1)
            $display("    rom[%0d] = 0x%08x", i, u_dut.u_ROM.mem[i]);

        rst_async = 1'b0;
        repeat (10) @(posedge clk_sys);
        rst_async = 1'b1;

        repeat (60) @(posedge clk_sys);      // 程序很短，60 拍足够跑完
        $display("");
        $display("---- 最终状态 ----");
        $display("  x5 = 0x%08x", u_dut.u_CPU_top.u_Regs.regs[5]);
        $display("  x6 = 0x%08x", u_dut.u_CPU_top.u_Regs.regs[6]);
        $display("  x7 = 0x%08x   <-- 期望 0x000000aa", u_dut.u_CPU_top.u_Regs.regs[7]);
        $display("  x8 = 0x%08x", u_dut.u_CPU_top.u_Regs.regs[8]);
        $display("  RAM[0x1000_0000] = 0x%08x   <-- 期望 0x000000aa", u_dut.u_RAM.mem[0]);
        $display("  RAM[0x1000_0004] = 0x%08x   <-- 期望 0x000000aa", u_dut.u_RAM.mem[1]);
        $display("  PC = 0x%08x", cur_pc);
        $finish;
    end

endmodule
