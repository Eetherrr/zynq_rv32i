`timescale 1ns / 1ps
`include "../rtl/sys_define.svh"

//=====================================================================
// tb_rib_periph : RIB + 外设集成测试（不含 CPU）
//
//   用一个极简「假主机」驱动 RIB 的 m1 数据端口，验证：
//     1. 地址译码与从机选择
//     2. 读数据回送通路
//     3. RAM / GPIO / TIMER / UART / SPI 寄存器的读写
//     4. SPI 在 DIV=0、Mode 0 下能否完成一次 8 bit 移位传输
//
//   运行： vivado -mode batch -source scripts/run_tb.tcl
//=====================================================================
module tb_rib_periph;

    //---- 时钟 / 复位 ----
    logic clk_sys = 1'b0;
    logic rst_n   = 1'b0;

    always #5 clk_sys = ~clk_sys;       // 100 MHz

    initial begin
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
    end

    // 复位为低有效（RESET_EN = 1'b0），直接使用，不要再取反
    wire rst_sys = rst_n;

    //==================================================================
    // 总线主机模型（接到 RIB 的 m1 端口）
    //==================================================================
    logic [31:0] m1_addr, m1_wdata, m1_rdata;
    logic        m1_req, m1_we, m1_re;
    logic [ 1:0] m1_size;

    //==================================================================
    // 从机互联
    //==================================================================
    logic [31:0] rom_rdata, ram_rdata, timer_rdata;
    logic [31:0] spi_rdata, uart_rdata, gpio_rdata;
    logic        rom_sel, ram_sel, timer_sel, spi_sel, uart_sel, gpio_sel;
    logic [31:0] s_rom_addr, s_ram_addr, s_timer_addr;
    logic [31:0] s_spi_addr, s_uart_addr, s_gpio_addr;
    logic [31:0] s_rom_wdata, s_ram_wdata, s_timer_wdata;
    logic [31:0] s_spi_wdata, s_uart_wdata, s_gpio_wdata;
    logic [ 1:0] s_rom_size, s_ram_size, s_timer_size;
    logic [ 1:0] s_spi_size, s_uart_size, s_gpio_size;
    logic        s_rom_we, s_ram_we, s_timer_we, s_spi_we, s_uart_we, s_gpio_we;
    logic        s_rom_re, s_ram_re, s_timer_re, s_spi_re, s_uart_re, s_gpio_re;
    logic        s_rom_req, s_ram_req, s_timer_req;
    logic        s_spi_req, s_uart_req, s_gpio_req;

    //---- 物理引脚 ----
    logic       uart_tx;
    wire        uart_rx = 1'b1;         // 空闲高
    logic       spi_sclk, spi_mosi, spi_ss_n;
    wire        spi_miso = 1'b1;
    logic [7:0] gpio_o, gpio_t;
    logic [7:0] gpio_i;
    wire        timer_irq;

    // GPIO 输出回环到输入，便于验证 DATA 写读
    assign gpio_i = gpio_o;

    RIB u_rib (
            .clk_sys (clk_sys),
            .rst_sys (rst_sys),

            // m0：本 tb 不使用
            .m0_addr (32'b0), .m0_wdata (32'b0), .m0_rdata (),
            .m0_req  (1'b0),  .m0_we    (1'b0),  .m0_re    (1'b0),
            .m0_size (`MSZ_W),

            // m1：假主机
            .m1_addr (m1_addr), .m1_wdata (m1_wdata), .m1_rdata (m1_rdata),
            .m1_req  (m1_req),  .m1_we    (m1_we),    .m1_re    (m1_re),
            .m1_size (m1_size),

            // m2 / m3：预留
            .m2_addr (32'b0), .m2_wdata (32'b0), .m2_rdata (),
            .m2_req  (1'b0),  .m2_we    (1'b0),  .m2_re    (1'b0),
            .m2_size (`MSZ_W),
            .m3_addr (32'b0), .m3_wdata (32'b0), .m3_rdata (),
            .m3_req  (1'b0),  .m3_we    (1'b0),  .m3_re    (1'b0),
            .m3_size (`MSZ_W),

            .s_rom_addr (s_rom_addr), .s_rom_wdata (s_rom_wdata),
            .s_rom_we   (s_rom_we),   .s_rom_re    (s_rom_re),
            .s_rom_req  (s_rom_req),  .s_rom_size  (s_rom_size),
            .s_rom_rdata(rom_rdata),  .s_rom_sel   (rom_sel),

            .s_ram_addr (s_ram_addr), .s_ram_wdata (s_ram_wdata),
            .s_ram_we   (s_ram_we),   .s_ram_re    (s_ram_re),
            .s_ram_req  (s_ram_req),  .s_ram_size  (s_ram_size),
            .s_ram_rdata(ram_rdata),  .s_ram_sel   (ram_sel),

            .s_timer_addr (s_timer_addr), .s_timer_wdata (s_timer_wdata),
            .s_timer_we   (s_timer_we),   .s_timer_re    (s_timer_re),
            .s_timer_req  (s_timer_req),  .s_timer_size  (s_timer_size),
            .s_timer_rdata(timer_rdata),  .s_timer_sel   (timer_sel),

            .s_spi_addr (s_spi_addr), .s_spi_wdata (s_spi_wdata),
            .s_spi_we   (s_spi_we),   .s_spi_re    (s_spi_re),
            .s_spi_req  (s_spi_req),  .s_spi_size  (s_spi_size),
            .s_spi_rdata(spi_rdata),  .s_spi_sel   (spi_sel),

            .s_uart_addr (s_uart_addr), .s_uart_wdata (s_uart_wdata),
            .s_uart_we   (s_uart_we),   .s_uart_re    (s_uart_re),
            .s_uart_req  (s_uart_req),  .s_uart_size  (s_uart_size),
            .s_uart_rdata(uart_rdata),  .s_uart_sel   (uart_sel),

            .s_gpio_addr (s_gpio_addr), .s_gpio_wdata (s_gpio_wdata),
            .s_gpio_we   (s_gpio_we),   .s_gpio_re    (s_gpio_re),
            .s_gpio_req  (s_gpio_req),  .s_gpio_size  (s_gpio_size),
            .s_gpio_rdata(gpio_rdata),  .s_gpio_sel   (gpio_sel)
        );

    ROM #(.WORDS(4096)) u_rom (
            .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(rom_sel), .addr(s_rom_addr),
            .wdata(s_rom_wdata), .size(s_rom_size), .we(s_rom_we), .re(s_rom_re),
            .rdata(rom_rdata)
        );

    RAM #(.WORDS(16384)) u_ram (
            .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(ram_sel), .addr(s_ram_addr),
            .wdata(s_ram_wdata), .size(s_ram_size), .we(s_ram_we), .re(s_ram_re),
            .rdata(ram_rdata)
        );

    TIMER u_timer (
              .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(timer_sel), .addr(s_timer_addr),
              .wdata(s_timer_wdata), .size(s_timer_size), .we(s_timer_we),
              .re(s_timer_re), .rdata(timer_rdata), .irq_o(timer_irq)
          );

    SPI u_spi (
            .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(spi_sel), .addr(s_spi_addr),
            .wdata(s_spi_wdata), .size(s_spi_size), .we(s_spi_we), .re(s_spi_re),
            .rdata(spi_rdata), .sclk_o(spi_sclk), .mosi_o(spi_mosi),
            .miso_i(spi_miso), .ss_n_o(spi_ss_n)
        );

    UART u_uart (
             .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(uart_sel), .addr(s_uart_addr),
             .wdata(s_uart_wdata), .size(s_uart_size), .we(s_uart_we),
             .re(s_uart_re), .rdata(uart_rdata), .rx_i(uart_rx), .tx_o(uart_tx)
         );

    GPIO #(.WIDTH(8)) u_gpio (
             .clk_sys(clk_sys), .rst_sys(rst_sys), .sel(gpio_sel), .addr(s_gpio_addr),
             .wdata(s_gpio_wdata), .size(s_gpio_size), .we(s_gpio_we),
             .re(s_gpio_re), .rdata(gpio_rdata),
             .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_t(gpio_t)
         );

    //==================================================================
    // 主机任务
    //   驱动方式：在时钟沿之后用「阻塞赋值」建立信号，并让出 1ns 给组合
    //   逻辑稳定；这样采样到的就是本拍的真实值，不会出现非阻塞赋值带来的
    //   地址/数据错拍。
    //   读时序：第 1 拍给出地址，第 2 拍锁存读数据（组合读通路）。
    //==================================================================
    int errors = 0;
    logic [31:0] rd;

    task automatic bus_write(input logic [31:0] a, input logic [31:0] d);
        @(posedge clk_sys);
        #1;
        m1_addr  = a;
        m1_wdata = d;
        m1_we    = 1'b1;
        m1_re    = 1'b0;
        m1_size  = `MSZ_W;
        m1_req   = 1'b1;
        @(posedge clk_sys);         // 写在本拍被从机采样
        #1;
        m1_req = 1'b0;
        m1_we  = 1'b0;
    endtask

    task automatic bus_write_size(input logic [31:0] a, input logic [31:0] d,
                                      input logic [1:0] sz);
        @(posedge clk_sys);
        #1;
        m1_addr  = a;
        m1_wdata = d;
        m1_we    = 1'b1;
        m1_re    = 1'b0;
        m1_size  = sz;
        m1_req   = 1'b1;
        @(posedge clk_sys);
        #1;
        m1_req = 1'b0;
        m1_we  = 1'b0;
    endtask

    task automatic bus_read(input logic [31:0] a, output logic [31:0] d);
        @(posedge clk_sys);
        #1;
        m1_addr = a;
        m1_we   = 1'b0;
        m1_re   = 1'b1;
        m1_size = `MSZ_W;
        m1_req  = 1'b1;
        @(negedge clk_sys);         // 半周期后组合读通路已稳定
        d = m1_rdata;
        m1_req = 1'b0;
        m1_re  = 1'b0;
        @(posedge clk_sys);
    endtask

    string names [0:31];   // 测试名称表（必须在使用它的 task 之前声明）

    // 检查任务：用编号 + ASCII 名称输出，避免仿真器对非 ASCII 字符串的
    // 格式化问题；编号对应上面的 names 数组。
    task automatic check(input int id, input logic [31:0] got,
                             input logic [31:0] exp);
        if (got === exp)
            $display("[PASS] #%0d %s = 0x%08x", id, names[id], got);
        else begin
            $display("[FAIL] #%0d %s = 0x%08x (expected 0x%08x)",
                     id, names[id], got, exp);
            errors = errors + 1;
        end
    endtask


    //==================================================================
    // 测试序列
    //==================================================================
    initial begin
        m1_addr = 32'b0;
        m1_wdata = 32'b0;
        m1_req = 1'b0;
        m1_we = 1'b0;
        m1_re = 1'b0;
        m1_size = `MSZ_W;

        names[0]  = "ROM_sel_at_ROM_BASE";
        names[1]  = "RAM_sel_at_RAM_BASE";
        names[2]  = "TIMER_sel_at_TIMER_BASE";
        names[3]  = "SPI_sel_at_SPI_BASE";
        names[4]  = "UART_sel_at_UART_BASE";
        names[5]  = "GPIO_sel_at_GPIO_BASE";
        names[6]  = "no_sel_at_unmapped";
        names[7]  = "RAM_write_read_back";
        names[8]  = "RAM_byte_write_preserves_neighbours";
        names[9]  = "RAM_halfword_write";
        names[10] = "GPIO_DIR_reset_value";
        names[11] = "GPIO_DIR_after_write";
        names[12] = "GPIO_DATA_write_read_loopback";
        names[13] = "GPIO_gpio_o_pins";
        names[14] = "GPIO_after_SET";
        names[15] = "GPIO_after_CLR";
        names[16] = "TIMER_COUNT_after_start";
        names[17] = "TIMER_not_overflowed";
        names[18] = "TIMER_OVERFLOW_set";
        names[19] = "TIMER_OVERFLOW_cleared";
        names[20] = "UART_BAUD_write_read";
        names[21] = "SPI_DIV_write_read";
        names[22] = "SPI_TXDATA_write_read";
        names[23] = "SPI_transfer_BUSY_cleared";
        names[24] = "SPI_DONE_set";

        @(posedge rst_n);
        repeat (4) @(posedge clk_sys);

        $display("\n===== 1. Address decode =====");
        @(posedge clk_sys);
        #1;
        // 片选由地址组合译码得到；需要一个主机持有总线授权，
        // 因此这里用 m1 发一个「读」请求把地址送上总线。
        m1_re   = 1'b1;
        m1_we   = 1'b0;
        m1_size = `MSZ_W;
        m1_req  = 1'b1;

        m1_addr = `ROM_BASE;
        #1 check(0,  {31'b0, rom_sel},   32'd1);
        m1_addr = `RAM_BASE;
        #1 check(1,  {31'b0, ram_sel},   32'd1);
        m1_addr = `TIMER_BASE;
        #1 check(2,  {31'b0, timer_sel}, 32'd1);
        m1_addr = `SPI_BASE;
        #1 check(3,  {31'b0, spi_sel},   32'd1);
        m1_addr = `UART_BASE;
        #1 check(4,  {31'b0, uart_sel},  32'd1);
        m1_addr = `GPIO_BASE;
        #1 check(5,  {31'b0, gpio_sel},  32'd1);
        m1_addr = 32'hDEAD_0000;
        #1 check(6, {30'b0, rom_sel, ram_sel}, 32'd0);
        m1_req = 1'b0;
        m1_re = 1'b0;

        $display("\n===== 2. RAM read/write =====");
        bus_write(`RAM_BASE + 32'h10, 32'hA5A5_1234);
        bus_read (`RAM_BASE + 32'h10, rd);
        check(7,  rd, 32'hA5A5_1234);

        // 字节 / 半字写：size 决定改写哪些字节通道。
        // 注意 wdata 由 MEM 阶段按地址低位预先对齐到目标字节通道
        // （byte 写 0x21 → 数据落在 lane1 → wdata = 0x0000_AA00），
        // RIB 与从机只按 size 选择要写的字节通道。
        bus_write(`RAM_BASE + 32'h20, 32'h1122_3344);
        bus_write_size(`RAM_BASE + 32'h21, 32'h0000_AA00, `MSZ_B);
        bus_read (`RAM_BASE + 32'h20, rd);
        check(8, rd, 32'h1122_AA44);          // 仅 lane1 被改写

        bus_write(`RAM_BASE + 32'h24, 32'hFFFF_FFFF);
        bus_write_size(`RAM_BASE + 32'h26, 32'hBEEF_0000, `MSZ_H);
        bus_read (`RAM_BASE + 32'h24, rd);
        check(9, rd, 32'hBEEF_FFFF);          // 仅高半字被改写

        $display("\n===== 3. GPIO data/direction =====");
        bus_read (`GPIO_BASE + 32'h04, rd);
        check(10,  rd, 32'h0);

        bus_write(`GPIO_BASE + 32'h04, 32'hFF);      // 全部设为输出
        bus_read (`GPIO_BASE + 32'h04, rd);
        check(11,  rd, 32'hFF);

        bus_write(`GPIO_BASE + 32'h00, 32'h5A);      // 写 DATA
        bus_read (`GPIO_BASE + 32'h00, rd);
        check(12, rd, 32'h5A);
        check(13, {24'b0, gpio_o}, 32'h5A);

        bus_write(`GPIO_BASE + 32'h08, 32'hA0);      // SET
        bus_read (`GPIO_BASE + 32'h00, rd);
        check(14, rd, 32'hFA);

        bus_write(`GPIO_BASE + 32'h0C, 32'h0A);      // CLR
        bus_read (`GPIO_BASE + 32'h00, rd);
        check(15, rd, 32'hF0);

        $display("\n===== 4. TIMER count/overflow =====");
        bus_write(`TIMER_BASE + 32'h00, 32'd20);     // LOAD = 20
        bus_write(`TIMER_BASE + 32'h08, 32'h1);      // EN = 1
        bus_read (`TIMER_BASE + 32'h04, rd);
        // 使能后计数立即开始递减，读回时已比 LOAD 少 1
        check(16, rd, 32'd19);

        bus_read (`TIMER_BASE + 32'h0C, rd);
        check(17, rd, 32'h0);

        repeat (30) @(posedge clk_sys);              // 等计数到 0
        bus_read (`TIMER_BASE + 32'h0C, rd);
        check(18, rd, 32'h1);

        bus_write(`TIMER_BASE + 32'h08, 32'h0);      // 停止
        bus_write(`TIMER_BASE + 32'h0C, 32'h1);      // 写 1 清标志
        bus_read (`TIMER_BASE + 32'h0C, rd);
        check(19, rd, 32'h0);

        $display("\n===== 5. UART/SPI registers =====");
        bus_write(`UART_BASE + 32'h0C, 32'd99);      // BAUD
        bus_read (`UART_BASE + 32'h0C, rd);
        check(20, rd, 32'd99);

        bus_write(`SPI_BASE + 32'h0C, 32'd3);        // DIV
        bus_read (`SPI_BASE + 32'h0C, rd);
        check(21, rd, 32'd3);

        bus_write(`SPI_BASE + 32'h00, 32'hA5);       // TXDATA
        bus_read (`SPI_BASE + 32'h00, rd);
        check(22, rd, 32'hA5);

        $display("\n===== 6. SPI transfer (DIV=0, Mode0) =====");
        bus_write(`SPI_BASE + 32'h0C, 32'd0);        // DIV = 0
        bus_write(`SPI_BASE + 32'h08, 32'h2);        // EN = 1
        bus_write(`SPI_BASE + 32'h08, 32'h3);        // EN = 1, START = 1
        repeat (30) @(posedge clk_sys);
        bus_read (`SPI_BASE + 32'h10, rd);
        check(23, rd[0], 32'd0);
        check(24, rd[1], 32'd1);

        $display("\n==========================================");
        if (errors == 0)
            $display("==> ALL TESTS PASSED");
        else
            $display("==> %0d TEST(S) FAILED", errors);
        $display("==========================================\n");

        $finish;
    end

    //---- 超时保护 ----
    initial begin
        #200000;
        $display("[FAIL] simulation timeout");
        $finish;
    end

endmodule
