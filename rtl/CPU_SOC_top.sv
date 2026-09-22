`timescale 1ns / 1ps

`include "sys_define.svh"

//=====================================================================
// CPU_SOC_top : SoC 顶层
//
//   ┌──────────┐  m0(取指)   ┌─────────┐   s_rom   ┌─────┐
//   │          │────────────►│         │──────────►│ ROM │
//   │ CPU_top  │  m1(数据)   │   RIB   │   s_ram   ├─────┤
//   │          │◄────────────│(Arbiter │──────────►│ RAM │
//   │          │             │ +译码)  │   s_timer ├───────┤
//   │          │             │         │──────────►│ TIMER │
//   │          │             │         │   s_spi   ├─────┐ │
//   │          │             │         │──────────►│ SPI │ │
//   │          │             │         │   s_uart  ├─────┤ │
//   │          │             │         │──────────►│UART │ │
//   │          │             │         │   s_gpio  ├─────┤ │
//   └──────────┘             └─────────┘──────────►│GPIO │ │
//                                                  └─────┘ │
//                                                          ▼
//                                              SPI / UART / GPIO 引脚
//
//   地址映射见 rtl/sys_define.svh
//   延迟模型：全组合读通路，单周期完成取指与访存；
//             将来若有从机需要多个周期，可拉高 hold_flag 冻结流水线。
//=====================================================================
module CPU_SOC_top (
        input  wire       clk_sys,
        input  wire       rst_async,

        // ---- UART ----
        input  wire       uart_rx,
        output wire       uart_tx,

        // ---- SPI ----
        output wire       spi_sclk,
        output wire       spi_mosi,
        input  wire       spi_miso,
        output wire       spi_ss_n,

        // ---- GPIO ----
        input  wire [7:0] gpio_i,
        output wire [7:0] gpio_o,
        output wire [7:0] gpio_t,

        // ---- 中断 ----
        output wire       timer_irq
    );

    //==================================================================
    // 1. 复位同步
    //    rst_async 低有效，打一拍得到同步复位 rst_sys
    //==================================================================
    reg rst_sync_r;
    always_ff @(posedge clk_sys or negedge rst_async) begin
        if (!rst_async)
            rst_sync_r <= `RESET_EN;
        else
            rst_sync_r <= `RESET_DIS;
    end

    wire rst_sys = rst_sync_r;

    //==================================================================
    // 2. CPU 端口
    //==================================================================
    // 指令侧
    wire [31:0] cpu_rom_addr;
    wire [31:0] cpu_rom_instr;
    // 数据侧
    wire [31:0] cpu_ram_addr;
    wire [31:0] cpu_ram_wdata;
    wire [31:0] cpu_ram_rdata;
    wire [ 3:0] cpu_ram_be;
    wire        cpu_ram_we;
    wire        cpu_ram_re;

    wire [7:0]  int_bus;
    wire        hold_flag;

    // 总线授权：数据口是 m0，取指口是 m1
    wire        bus_grant_valid;
    wire        if_grant;

    //------------------------------------------------------------------
    // 访问宽度推导
    //   CPU_top 目前只引出 ram_be_o（4 位字节使能），未引出 mem_size。
    //   这里由 be 反推出 B / H / W：MEM 阶段保证 be 是「连续若干位」
    //   （B → 1 位，H → 2 位，W → 4 位），因此可以无歧义地还原。
    //   待 CPU_top 增加 size 输出后，把 cpu_size 换成该端口即可。
    //------------------------------------------------------------------
    wire be_is_one  = (cpu_ram_be == 4'b0001) || (cpu_ram_be == 4'b0010) ||
                      (cpu_ram_be == 4'b0100) || (cpu_ram_be == 4'b1000);
    wire be_is_two  = (cpu_ram_be == 4'b0011) || (cpu_ram_be == 4'b1100);

    wire [1:0] cpu_size = be_is_one ? `MSZ_B :
                          be_is_two ? `MSZ_H : `MSZ_W;

    CPU_top u_CPU_top (
        .clk_sys     (clk_sys),
        .rst_sys     (rst_sys),

        // 指令 ROM
        .rom_instr_i      (cpu_rom_instr),
        .rom_instr_addr_o (cpu_rom_addr),

        // 数据 RAM
        .ram_addr_o  (cpu_ram_addr),
        .ram_data_o  (cpu_ram_wdata),
        .ram_be_o    (cpu_ram_be),
        .ram_we_o    (cpu_ram_we),
        .ram_re_o    (cpu_ram_re),
        .ram_data_i  (cpu_ram_rdata),

        // 中断与总线等待
        .int_i       (int_bus),
        .hold_flag_i (hold_flag),

        // 取指总线授权：数据访问占用总线的周期需要冻结 IF
        .if_grant_i        (if_grant),
        .bus_grant_valid_i (bus_grant_valid)
    );

    //==================================================================
    // 3. 中断
    //    当前仅定时器有中断源，其余位预留
    //==================================================================
    assign int_bus = {7'b0, timer_irq};

    // 当前所有从机均为单周期，无需冻结流水线
    assign hold_flag = `FALSE;

    //==================================================================
    // 4. RIB 互联
    //    m0 : 取指（指令 ROM）        m1 : 数据访存（RAM / 外设）
    //    m2 / m3 : 预留（DMA / 调试）
    //==================================================================
    // 从机回送数据
    wire [31:0] rom_rdata, ram_rdata, timer_rdata;
    wire [31:0] spi_rdata, uart_rdata, gpio_rdata;
    // 地址译码片选
    wire        rom_sel, ram_sel, timer_sel, spi_sel, uart_sel, gpio_sel;
    // RIB → 从机的请求与地址
    wire [31:0] s_rom_addr, s_ram_addr, s_timer_addr;
    wire [31:0] s_spi_addr, s_uart_addr, s_gpio_addr;
    wire [31:0] s_rom_wdata, s_ram_wdata, s_timer_wdata;
    wire [31:0] s_spi_wdata, s_uart_wdata, s_gpio_wdata;
    wire [ 1:0] s_rom_size, s_ram_size, s_timer_size;
    wire [ 1:0] s_spi_size, s_uart_size, s_gpio_size;
    wire        s_rom_we, s_ram_we, s_timer_we, s_spi_we, s_uart_we, s_gpio_we;
    wire        s_rom_re, s_ram_re, s_timer_re, s_spi_re, s_uart_re, s_gpio_re;
    wire        s_rom_req, s_ram_req, s_timer_req;
    wire        s_spi_req, s_uart_req, s_gpio_req;

    RIB u_RIB (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),

        // 授权状态引出给 CPU（见 CPU_top 的 if_bus_stall）
        .grant_o       (),
        .valid_o       (bus_grant_valid),
        .m1_grant_o    (if_grant),

        // ---- Master 0 : 数据访存（优先级最高）----
        // 数据写一旦丢失就无法恢复，而取指晚一拍只是让 IF 多等一拍；
        // 因此把数据口放在最高优先级，取指口放在 m1。
        // CPU_top 用 if_grant / grant_valid 检测取指被让出并冻结 IF。
        .m0_addr  (cpu_ram_addr),
        .m0_wdata (cpu_ram_wdata),
        .m0_rdata (cpu_ram_rdata),
        .m0_req   (cpu_ram_we | cpu_ram_re),
        .m0_we    (cpu_ram_we),
        .m0_re    (cpu_ram_re),
        .m0_size  (cpu_size),

        // ---- Master 1 : 取指（指令 ROM）----
        // 取指端口持续请求；只要数据口不发请求，它每拍都能拿到授权。
        .m1_addr  (cpu_rom_addr),
        .m1_wdata (32'b0),
        .m1_rdata (cpu_rom_instr),
        .m1_req   (1'b1),
        .m1_we    (`DISABLE),
        .m1_re    (`ENABLE),
        .m1_size  (`MSZ_W),

        // ---- Master 2 / 3 : 预留 ----
        .m2_addr  (32'b0),
        .m2_wdata (32'b0),
        .m2_rdata (),
        .m2_req   (`DISABLE),
        .m2_we    (`DISABLE),
        .m2_re    (`DISABLE),
        .m2_size  (`MSZ_W),

        .m3_addr  (32'b0),
        .m3_wdata (32'b0),
        .m3_rdata (),
        .m3_req   (`DISABLE),
        .m3_we    (`DISABLE),
        .m3_re    (`DISABLE),
        .m3_size  (`MSZ_W),

        // ---- Slave : ROM ----
        .s_rom_addr  (s_rom_addr),
        .s_rom_wdata (s_rom_wdata),
        .s_rom_we    (s_rom_we),
        .s_rom_re    (s_rom_re),
        .s_rom_req   (s_rom_req),
        .s_rom_size  (s_rom_size),
        .s_rom_rdata (rom_rdata),
        .s_rom_sel   (rom_sel),

        // ---- Slave : RAM ----
        .s_ram_addr  (s_ram_addr),
        .s_ram_wdata (s_ram_wdata),
        .s_ram_we    (s_ram_we),
        .s_ram_re    (s_ram_re),
        .s_ram_req   (s_ram_req),
        .s_ram_size  (s_ram_size),
        .s_ram_rdata (ram_rdata),
        .s_ram_sel   (ram_sel),

        // ---- Slave : TIMER ----
        .s_timer_addr  (s_timer_addr),
        .s_timer_wdata (s_timer_wdata),
        .s_timer_we    (s_timer_we),
        .s_timer_re    (s_timer_re),
        .s_timer_req   (s_timer_req),
        .s_timer_size  (s_timer_size),
        .s_timer_rdata (timer_rdata),
        .s_timer_sel   (timer_sel),

        // ---- Slave : SPI ----
        .s_spi_addr  (s_spi_addr),
        .s_spi_wdata (s_spi_wdata),
        .s_spi_we    (s_spi_we),
        .s_spi_re    (s_spi_re),
        .s_spi_req   (s_spi_req),
        .s_spi_size  (s_spi_size),
        .s_spi_rdata (spi_rdata),
        .s_spi_sel   (spi_sel),

        // ---- Slave : UART ----
        .s_uart_addr  (s_uart_addr),
        .s_uart_wdata (s_uart_wdata),
        .s_uart_we    (s_uart_we),
        .s_uart_re    (s_uart_re),
        .s_uart_req   (s_uart_req),
        .s_uart_size  (s_uart_size),
        .s_uart_rdata (uart_rdata),
        .s_uart_sel   (uart_sel),

        // ---- Slave : GPIO ----
        .s_gpio_addr  (s_gpio_addr),
        .s_gpio_wdata (s_gpio_wdata),
        .s_gpio_we    (s_gpio_we),
        .s_gpio_re    (s_gpio_re),
        .s_gpio_req   (s_gpio_req),
        .s_gpio_size  (s_gpio_size),
        .s_gpio_rdata (gpio_rdata),
        .s_gpio_sel   (gpio_sel)
    );

    //==================================================================
    // 5. 从机例化
    //==================================================================
    // 指令 ROM：封装 IP（4096x32，16 KiB，读延迟 1 拍）
    ROM_Ctrl u_ROM (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (rom_sel),
        .addr    (s_rom_addr),
        .wdata   (s_rom_wdata),
        .size    (s_rom_size),
        .we      (s_rom_we),
        .re      (s_rom_re),
        .rdata   (rom_rdata)
    );

    // 数据 RAM：封装 IP（16384x32，64 KiB，读延迟 1 拍）
    RAM_Ctrl u_RAM (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (ram_sel),
        .addr    (s_ram_addr),
        .wdata   (s_ram_wdata),
        .size    (s_ram_size),
        .we      (s_ram_we),
        .re      (s_ram_re),
        .rdata   (ram_rdata)
    );

    TIMER u_TIMER (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (timer_sel),
        .addr    (s_timer_addr),
        .wdata   (s_timer_wdata),
        .size    (s_timer_size),
        .we      (s_timer_we),
        .re      (s_timer_re),
        .rdata   (timer_rdata),
        .irq_o   (timer_irq)
    );

    SPI u_SPI (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (spi_sel),
        .addr    (s_spi_addr),
        .wdata   (s_spi_wdata),
        .size    (s_spi_size),
        .we      (s_spi_we),
        .re      (s_spi_re),
        .rdata   (spi_rdata),
        .sclk_o  (spi_sclk),
        .mosi_o  (spi_mosi),
        .miso_i  (spi_miso),
        .ss_n_o  (spi_ss_n)
    );

    UART #(
        .BAUD_DEFAULT (867)             // 100 MHz / 115200 - 1
    ) u_UART (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (uart_sel),
        .addr    (s_uart_addr),
        .wdata   (s_uart_wdata),
        .size    (s_uart_size),
        .we      (s_uart_we),
        .re      (s_uart_re),
        .rdata   (uart_rdata),
        .rx_i    (uart_rx),
        .tx_o    (uart_tx)
    );

    GPIO #(
        .WIDTH (8)
    ) u_GPIO (
        .clk_sys (clk_sys),
        .rst_sys (rst_sys),
        .sel     (gpio_sel),
        .addr    (s_gpio_addr),
        .wdata   (s_gpio_wdata),
        .size    (s_gpio_size),
        .we      (s_gpio_we),
        .re      (s_gpio_re),
        .rdata   (gpio_rdata),
        .gpio_i  (gpio_i),
        .gpio_o  (gpio_o),
        .gpio_t  (gpio_t)
    );

endmodule
