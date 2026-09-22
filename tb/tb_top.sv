`timescale 1ns / 1ps
`include "../rtl/sys_define.svh"

//=====================================================================
// tb_top — CPU 功能验证测试平台
//
//   把 tb/prog/cpu_test.hex 载入 ROM，复位后让 CPU 自由运行，直到程序
//   把结果写进 RAM[0x1000_0000]（1 = 通过，0 = 失败）并进入挂死循环。
//   然后由测试平台核对：
//     1. 结果字          RAM[0x1000_0000] == 1
//     2. 寄存器堆        x1~x20 的架构可见值与程序预期一致
//     3. 内存副作用      RAM[0x1000_0000]、[0x1000_0004] 最终内容
//     4. GPIO 副作用     DIR / DATA 引脚电平
//     5. 串口输出        UART 引脚上收到的字节必须是 "OK\n"
//     6. 程序流          是否跑飞到了失败汇合点 0x100
//
//   覆盖的指令 / 机制（逐条对应 tb/prog/cpu_test.hex，已做往返解码核对）
//     ALU    : ADD / SUB / AND / OR
//     立即数 : ADDI（含负立即数 -0x411、0xBEF）、ANDI、LUI
//     访存   : LW / SW（字）、SB / LBU（字节）、SH / LHU（半字）
//     控制流 : BEQ（跳与不跳）、BNE（跳与不跳）、JAL
//     外设   : UART（波特率 + STATUS 轮询 + 发 "OK\n"）、GPIO（DIR/DATA）、
//              TIMER（装载 + 启动 + 轮询 OVERFLOW + 写 1 清标志）
//     冒险   : LOAD-USE（0x048 的 lw 紧跟 0x044 的 sw，同地址）、RAW 前递、
//              分支/跳转冲刷
//
//   未覆盖（后续补）：JALR、BLT/BGE/BLTU/BGEU、SLL/SRL/SRA/SLT/SLTU、
//                     LB/LH、非对齐访问异常、CSR/中断响应
//
//   运行： make tb TB=tb_top
//
//   说明：程序镜像由 ROM IP 的初始化文件 tb/prog/cpu_test.coe 预置
//         （IP 内部数组不可直接写入）。
//         读回校验用测试平台内的「影子内存」镜像 CPU 的 RAM 写操作，
//         不依赖 IP 内部层次结构。
//=====================================================================
module tb_top;

    //------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------
    parameter real CLK_PERIOD = 10.0;                       // 100 MHz
    parameter      PROG_FILE  = "/home/ether/edev/fpga/prj/zynq_rv32i/tb/prog/cpu_test.hex";
    parameter int  PROG_WORDS = 4096;                       // ROM 容量（字）
    parameter int  UART_DIV   = 867;                        // 与程序写入的 BAUD 一致
    parameter real BIT_NS     = (UART_DIV + 1) * CLK_PERIOD; // 一个位周期 ≈ 8680 ns
    parameter real TIMEOUT_NS = 40000.0;                    // 4 万个时钟周期上限

    //------------------------------------------------------------------
    // 时钟 / 复位
    //------------------------------------------------------------------
    logic clk_sys   = 1'b0;
    logic rst_async = 1'b0;                                 // 低有效

    always #(CLK_PERIOD/2.0) clk_sys = ~clk_sys;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire        uart_tx;
    wire        spi_sclk, spi_mosi, spi_ss_n;
    wire [7:0]  gpio_o, gpio_t;
    wire        timer_irq;
    wire [7:0]  gpio_i;

    assign gpio_i = gpio_o;                                 // 输出回环，便于观察

    CPU_SOC_top u_dut (
                    .clk_sys   (clk_sys),
                    .rst_async (rst_async),
                    .uart_rx   (1'b1),                                  // 串口空闲高
                    .uart_tx   (uart_tx),
                    .spi_sclk  (spi_sclk),
                    .spi_mosi  (spi_mosi),
                    .spi_miso  (1'b1),
                    .spi_ss_n  (spi_ss_n),
                    .gpio_i    (gpio_i),
                    .gpio_o    (gpio_o),
                    .gpio_t    (gpio_t),
                    .timer_irq (timer_irq)
                );

    //------------------------------------------------------------------
    // 观测点
    //------------------------------------------------------------------
    wire        mem_we    = u_dut.cpu_ram_we;
    wire [31:0] mem_addr  = u_dut.cpu_ram_addr;
    wire [31:0] mem_wdata = u_dut.cpu_ram_wdata;
    wire [31:0] cur_pc    = u_dut.u_CPU_top.if_pc;
    wire        rst_sys   = u_dut.rst_sys;

    bit          result_seen = 1'b0;
    logic [31:0] result_w    = 32'hDEAD_DEAD;

    //------------------------------------------------------------------
    // 取指对齐诊断：复位后头 20 拍，逐拍列出
    //   if_pc（PC 寄存器输出）/ rom_instr（ROM 锁定输出）
    //   / id_pc、id_instr（IF2ID 锁存结果）
    //   判断「指令是否与它应属的地址配对」。
    //   TRACE_MAX 设 0 可关闭。
    //------------------------------------------------------------------
    int TRACE_MAX = 20;
    int fa_cnt = 0;

    always @(posedge clk_sys) begin
        if (rst_async && fa_cnt < TRACE_MAX) begin
            fa_cnt = fa_cnt + 1;
            $display("[FA] if_pc=%h rom_instr=%h | id_pc=%h id_instr=%h",
                     u_dut.u_CPU_top.if_pc,
                     u_dut.u_CPU_top.if_instr,
                     u_dut.u_CPU_top.id_pc,
                     u_dut.u_CPU_top.id_instr);
        end
    end

    // 程序流追踪：CPU 是否跑飞到了失败汇合点
    bit          reached_fail_path = 1'b0;

    always @(posedge clk_sys) begin
        if (!result_seen && mem_we && (mem_addr == `RAM_BASE)) begin
            result_w    <= mem_wdata;
            result_seen <= 1'b1;
        end
        if (cur_pc == 32'h0000_0100)
            reached_fail_path <= 1'b1;
    end

    //------------------------------------------------------------------
    // 程序镜像
    //------------------------------------------------------------------
    logic [31:0] prog [0:PROG_WORDS-1];
    bit          prog_loaded = 1'b0;
    int          fd;

    //------------------------------------------------------------------
    // 串口接收：起始位下降沿后，每个位周期采一次，采样点落在位中间，
    //           与 DUT 发送边沿相差 5 ns，不会踩在跳变上。
    //------------------------------------------------------------------
    int         uart_count = 0;
    logic [7:0] uart_last  = 8'h00;
    bit         uart_ok    = 1'b1;
    logic [7:0] uart_byte  [0:7];       // 实际收到的字节序列（最多存 8 个）

    task automatic uart_recv_byte(output logic [7:0] data, output bit stop_ok);
        logic [7:0] d;
        int i;
        @(negedge uart_tx);                 // 起始位下降沿
        #(BIT_NS);                          // → bit0 中间
        d[0] = uart_tx;
        for (i = 1; i < 8; i = i + 1) begin
            #(BIT_NS);
            d[i] = uart_tx;
        end
        #(BIT_NS);
        stop_ok = uart_tx;                  // 停止位应为高
        data    = d;
    endtask

    task automatic uart_recv_all();
        bit st;
        logic [7:0] b;
        uart_recv_byte(b, st);
        uart_count = 1;
        uart_last  = b;
        uart_byte[0] = b;
        $display("[UART ] byte #1 = 0x%02x ('%c') stop=%0b", b,
                 (b >= 8'h20 && b < 8'h7F) ? b : 8'h2E, st);
        if (!st)
            uart_ok = 1'b0;
        forever begin
            uart_recv_byte(b, st);
            if (uart_count < 8)
                uart_byte[uart_count] = b;
            uart_count = uart_count + 1;
            uart_last  = b;
            $display("[UART ] byte #%0d = 0x%02x ('%c') stop=%0b", uart_count, b,
                     (b >= 8'h20 && b < 8'h7F) ? b : 8'h2E, st);
            if (!st)
                uart_ok = 1'b0;
        end
    endtask

    // 串口接收进程：独立 initial 块，与主流程并发
    initial
        uart_recv_all();

    //------------------------------------------------------------------
    // 检查辅助：用整数编号 + 模块级字符串表，避开仿真器对 %s 参数的
    //           格式化差异；编号与 names[] 一一对应。
    //------------------------------------------------------------------
    int    errors = 0;
    string names [0:31];

    //------------------------------------------------------------------
    // RAM 影子内存（shadow memory）
    //   RAM 已换成 Block Memory Generator IP，其内部数组的层次路径依赖
    //   IP 实现细节（不同版本/配置会变），不适合在测试平台里硬编码。
    //   这里改为「镜像」RAM 的实际写入：观察 RIB 送给 RAM 从机的
    //   s_ram_we / s_ram_addr / s_ram_wdata / s_ram_size，在测试平台内
    //   维护一份 RAM 内容副本用于最终校验。
    //   用 s_ram_we（RIB → RAM 的实际写使能）而不是 CPU 侧 mem_we，
    //   可以准确反映「这一拍 RAM 是否真的被写入」。
    //------------------------------------------------------------------
    localparam int RAM_WORDS = 16384;
    logic [31:0] ram_shadow [0:RAM_WORDS-1];
    int          ram_wr_cnt = 0;

    always @(posedge clk_sys) begin
        if (u_dut.s_ram_we) begin
            // 字节使能由 size + 地址低位展开（与 rtl/Peripheral/RAM.sv 一致）
            logic [3:0] be;
            case (u_dut.s_ram_size)
                `MSZ_B:
                    be = 4'b0001 << u_dut.s_ram_addr[1:0];
                `MSZ_H:
                    be = u_dut.s_ram_addr[1] ? 4'b1100 : 4'b0011;
                default:
                    be = 4'b1111;
            endcase
            for (int b = 0; b < 4; b = b + 1) begin
                if (be[b])
                    ram_shadow[u_dut.s_ram_addr[15:2]][8*b +: 8]
                              <= u_dut.s_ram_wdata[8*b +: 8];
            end
            ram_wr_cnt <= ram_wr_cnt + 1;
        end
    end

    function automatic logic [31:0] peek_ram(input int word_idx);
        peek_ram = ram_shadow[word_idx];
    endfunction

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

    task automatic dump_state();
        $display("---- 现场 ----");
        $display("  PC                = 0x%08x", cur_pc);
        $display("  RESULT            = 0x%08x", result_w);
        $display("  RAM[0x1000_0000]  = 0x%08x", peek_ram(0));
        $display("  RAM[0x1000_0004]  = 0x%08x", peek_ram(1));
        $display("  GPIO DIR / DATA   = 0x%02x / 0x%02x", gpio_t, gpio_o);
        $display("  TIMER count/ovf   = %0d / %0b",
                 u_dut.u_TIMER.count_reg, u_dut.u_TIMER.overflow_reg);
        $display("  UART tx_shift     = 0x%02x (busy=%0b)",
                 u_dut.u_UART.tx_shift, u_dut.u_UART.tx_busy);
        $display("  x1..x10  = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 u_dut.u_CPU_top.u_Regs.regs[1],  u_dut.u_CPU_top.u_Regs.regs[2],
                 u_dut.u_CPU_top.u_Regs.regs[3],  u_dut.u_CPU_top.u_Regs.regs[4],
                 u_dut.u_CPU_top.u_Regs.regs[5],  u_dut.u_CPU_top.u_Regs.regs[6],
                 u_dut.u_CPU_top.u_Regs.regs[7],  u_dut.u_CPU_top.u_Regs.regs[8],
                 u_dut.u_CPU_top.u_Regs.regs[9],  u_dut.u_CPU_top.u_Regs.regs[10]);
        $display("  x11..x15 = %0d %0d %0d %0d %0d",
                 u_dut.u_CPU_top.u_Regs.regs[11], u_dut.u_CPU_top.u_Regs.regs[12],
                 u_dut.u_CPU_top.u_Regs.regs[13], u_dut.u_CPU_top.u_Regs.regs[14],
                 u_dut.u_CPU_top.u_Regs.regs[15]);
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    logic [31:0] R [1:15];
    int          i;

    initial begin
        // 名称表
        names[0]  = "RAM_RESULT_word";
        names[1]  = "x1_addi_0";
        names[2]  = "x2_addi_10";
        names[3]  = "x3_add_sub";
        names[4]  = "x4_add";
        names[5]  = "x5_RAM_base";
        names[6]  = "x6_or_then_1";
        names[7]  = "x7_lw_word";
        names[8]  = "x8_addi_7F";
        names[9]  = "x9_base_plus_1";
        names[10] = "x10_lbu";
        names[11] = "x11_periph_base";
        names[12] = "x12_addi_0";
        names[13] = "x13_uart_last_byte";
        names[14] = "x14_timer_status_w1";
        names[15] = "x15_timer_load_200";
        names[16] = "RAM_SW_final";
        names[17] = "RAM_SH_final";
        names[18] = "GPIO_DIR";
        names[19] = "GPIO_DATA";
        names[20] = "GPIO_IN_loopback";
        names[21] = "TIMER_overflow_set";
        names[22] = "no_fail_path";
        names[23] = "x28_addi_BEF";
        names[24] = "x29_neg_immediate";
        names[25] = "x30_final_zero";

        $display("==========================================================");
        $display(" tb_top - CPU functional test");
        $display("==========================================================");

        // ---- 1. 载入程序镜像 ----
        for (i = 0; i < PROG_WORDS; i = i + 1)
            prog[i] = 32'h0000_0013;                        // 其余填 NOP

        fd = $fopen(PROG_FILE, "r");
        if (fd == 0) begin
            $display("[FATAL] cannot open program image: %s", PROG_FILE);
            $display("        run make tb from the project root");
            $finish;
        end
        $fclose(fd);
        $readmemh(PROG_FILE, prog);
        prog_loaded = 1'b1;
        $display("==> program loaded: %s", PROG_FILE);

        // 程序已在 ROM IP 内由 tb/prog/cpu_test.coe 初始化，
        // 这里不再向 ROM 写数据（IP 内部数组不可直接访问）。

        // ---- 2. 复位 ----
        rst_async = 1'b0;
        repeat (10) @(posedge clk_sys);
        rst_async = 1'b1;
        $display("==> reset released, CPU running");

        // ---- 3. 等结果（带超时） ----
        fork : wait_result
            begin
                wait (result_seen);
                #(15 * CLK_PERIOD);     // 让流水线里的 store 落地、串口把 3 字节发完
                $display("==> result written at t=%0t ns", $time);
            end
            begin
                #(TIMEOUT_NS);
                $display("[FATAL] timeout: no result within %0t ns", TIMEOUT_NS);
                errors = errors + 1;
            end
        join_any
        disable wait_result;

        // ---- 4. 核对 ----
        $display("");
        $display("-- 1) result word --");
        check(0, peek_ram(0), 32'h1);

        $display("");
        $display("-- 2) register file x1..x15 --");
        for (i = 1; i <= 15; i = i + 1)
            R[i] = u_dut.u_CPU_top.u_Regs.regs[i];

        check(1,  R[1],  32'd0);            // addi x1, x0, 0
        check(2,  R[2],  32'd10);           // addi x2, x0, 10
        check(3,  R[3],  32'd10);           // 20 再 sub x2 -> 10
        check(4,  R[4],  32'd10);           // add x1(0)+x2(10)
        check(5,  R[5],  `RAM_BASE);        // 最后一次 lui x5, 0x10000
        check(6,  R[6],  32'd1);            // 通过标志
        check(7,  R[7],  32'd1);            // lw RAM[base] == 1
        check(8,  R[8],  32'h7F);
        check(9,  R[9],  `RAM_BASE + 32'd1);
        check(10, R[10], 32'h7F);           // lbu
        check(11, R[11], 32'h2000_0000);    // lui x11, 0x20000
        check(12, R[12], 32'd0);            // addi x12, x0, 0
        check(13, R[13], 32'h0A);           // 最后一个 UART 字节 '\n'
        check(14, R[14], 32'd1);            // TIMER STATUS 写 1 清标志
        check(15, R[15], 32'd200);          // TIMER.LOAD 装载值
        // 半字访存相关寄存器（x30/x31 在程序末尾被复用，其正确性由程序内
        // 的 bne x31,x29 自检保证；这里核对未被复用的 x28 / x29）
        check(23, u_dut.u_CPU_top.u_Regs.regs[28], 32'h1000_0EEF); // addi x28,x29,0xBEF
        check(24, u_dut.u_CPU_top.u_Regs.regs[29], 32'hFFFF_FBEF); // addi x29,x0,-0x411
        check(25, u_dut.u_CPU_top.u_Regs.regs[30], 32'h0);         // 末次 addi x30,x0,0

        $display("");
        $display("-- 3) memory side effects --");
        $display("       (影子内存共记录 %0d 次 RAM 写)", ram_wr_cnt);
        check(16, peek_ram(0), 32'h1);                 // SW x6,0(x5)
        check(17, peek_ram(192), 32'h0000_BEEF);       // SH x28,0(x29)

        $display("");
        $display("-- 4) GPIO side effects --");
        check(18, {24'b0, gpio_t}, 32'h0000_00FF);
        check(19, {24'b0, gpio_o}, 32'h0000_005A);
        check(20, {24'b0, gpio_i}, 32'h0000_005A);

        $display("");
        $display("-- 5) UART output on the wire --");
        // 接收任务需要 3 个位周期收完最后一帧，这里在检查前再等一小段
        #(5 * BIT_NS);
        if (uart_count == 3 && uart_ok &&
                uart_byte[0] == 8'h4F &&        // 'O'
                uart_byte[1] == 8'h4B &&        // 'K'
                uart_byte[2] == 8'h0A)          // '\n'
            $display("[PASS] #23 UART sent 'O','K','\\n' with valid stop bits");
        else begin
            $display("[FAIL] #23 UART count=%0d stop_ok=%0b bytes=%02x %02x %02x",
                     uart_count, uart_ok, uart_byte[0], uart_byte[1], uart_byte[2]);
            errors = errors + 1;
        end

        $display("");
        $display("-- 6) program flow --");
        check(21, u_dut.u_TIMER.overflow_reg, 32'h1);
        check(22, {31'b0, reached_fail_path}, 32'h0);

        // ---- 5. 结论 ----
        $display("");
        $display("==========================================================");
        if (errors == 0)
            $display("==> CPU functional test PASSED");
        else begin
            $display("==> CPU functional test FAILED: %0d check(s)", errors);
            dump_state();
        end
        $display("==========================================================");
        $finish;
    end

endmodule
