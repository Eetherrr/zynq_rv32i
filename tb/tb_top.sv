`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_top — RV32I 系统级验证测试平台（SoC 顶层 + ROM/RAM IP + 全部外设）
//
//   流程：
//     1. ROM 内容来自 tb/prog/ROM.mif（由 tb/prog/gen_cpu_test.py 生成），
//        程序自带 RV32I 全覆盖用例，每个用例把结果写进 RAM 的一个「结果槽」；
//     2. 程序末尾写 RESULT（1 通过 / 0 失败）与 DONE 魔数，然后挂死；
//     3. 本测试平台用「影子内存」镜像 CPU 对 RAM 的写操作，等 DONE 魔数出现后
//        逐槽与 tb/prog/cpu_test.exp 里的期望值比对，并核对外设副作用。
//
//   核对内容：
//     1. 期望值表      cpu_test.exp 每行「RAM 地址 期望值 名称」：
//                      指令结果槽 + CSR 读写结果 + 陷阱记录(mcause/mepc)
//     2. RESULT / DONE RAM[0] == 1、RAM[1] == 0x600D_1EAF
//     3. GPIO          DIR / DATA 引脚电平、输入回环
//     4. TIMER         OVERFLOW 置位
//     5. UART          引脚上真实收到的 "OK\n"（含停止位校验）
//
//   指令覆盖：RV32I 40/40（含 ECALL/EBREAK/FENCE）+ Zicsr 六条 CSR 指令；
//             另覆盖异常入口（非法指令 / 非对齐访存）、MRET 与定时器中断。
//
//   运行： make tb TB=tb_top
//         （改测试程序后先跑 python3 tb/prog/gen_cpu_test.py）
//=====================================================================
module tb_top;

    //------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------
    parameter real CLK_PERIOD = 10.0;                       // 100 MHz
    parameter      PROG_FILE  = "/home/ether/edev/fpga/prj/zynq_rv32i/tb/prog/cpu_test.hex";
    parameter      EXP_FILE   = "/home/ether/edev/fpga/prj/zynq_rv32i/tb/prog/cpu_test.exp";
    parameter int  PROG_WORDS = 4096;                       // ROM 容量（字）
    parameter int  UART_DIV   = 867;                        // 与程序写入的 BAUD 一致
    parameter real BIT_NS     = (UART_DIV + 1) * CLK_PERIOD; // 一个位周期 ≈ 8680 ns
    // 超时：程序要发 3 个 UART 字节（每帧 ≈ 87us，含等待），留足余量取 1.5ms
    parameter real TIMEOUT_NS = 1500000.0;

    // 结果槽 / 结束标志（与 gen_cpu_test.py 的布局一致）
    localparam int DONE_WORD  = 1;                          // RAM 字 1 = 字节 0x04
    localparam int SLOT_WORD  = 256;                        // RAM 字 0x100 = 字节 0x400
    localparam logic [31:0] DONE_MAGIC = 32'h600D_1EAF;
    localparam int MAX_SLOTS  = 256;

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
    wire [31:0] cur_pc    = u_dut.u_CPU_top.if_pc;
    wire        rst_sys   = u_dut.rst_sys;

    //------------------------------------------------------------------
    // RAM 影子内存
    //   RAM 是 BMG IP，内部数组的层次路径依赖 IP 实现细节，不适合硬编码。
    //   这里镜像 RIB 送给 RAM 从机的写事务，供最终校验使用。
    //------------------------------------------------------------------
    localparam int RAM_WORDS = 16384;
    logic [31:0] ram_shadow [0:RAM_WORDS-1];
    int          ram_wr_cnt = 0;
    bit          done_seen  = 1'b0;

    always @(posedge clk_sys) begin
        if (u_dut.s_ram_we) begin
            logic [3:0] be;
            case (u_dut.s_ram_size)
                `MSZ_B:  be = 4'b0001 << u_dut.s_ram_addr[1:0];
                `MSZ_H:  be = u_dut.s_ram_addr[1] ? 4'b1100 : 4'b0011;
                default: be = 4'b1111;
            endcase
            for (int b = 0; b < 4; b = b + 1) begin
                if (be[b])
                    ram_shadow[u_dut.s_ram_addr[15:2]][8*b +: 8]
                              <= u_dut.s_ram_wdata[8*b +: 8];
            end
            ram_wr_cnt <= ram_wr_cnt + 1;

            // DONE 魔数：整字写入 RAM 字 1
            if (u_dut.s_ram_addr[15:2] == DONE_WORD[13:0] &&
                u_dut.s_ram_size == `MSZ_W &&
                u_dut.s_ram_wdata == DONE_MAGIC)
                done_seen <= 1'b1;
        end
    end

    function automatic logic [31:0] peek_ram(input int word_idx);
        peek_ram = ram_shadow[word_idx];
    endfunction

    //------------------------------------------------------------------
    // 串口接收：起始位下降沿后每个位周期采一次，采样点落在位中间
    //------------------------------------------------------------------
    int         uart_count = 0;
    bit         uart_ok    = 1'b1;
    logic [7:0] uart_byte  [0:7];

    task automatic uart_recv_byte(output logic [7:0] data, output bit stop_ok);
        logic [7:0] d;
        int i;
        @(negedge uart_tx);                 // 起始位下降沿
        #(BIT_NS * 1.5);                    // → bit0 中间（半位偏置）
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
        uart_byte[0] = b;
        $display("[UART ] byte #1 = 0x%02x ('%c') stop=%0b", b,
                 (b >= 8'h20 && b < 8'h7F) ? b : 8'h2E, st);
        if (!st) uart_ok = 1'b0;
        forever begin
            uart_recv_byte(b, st);
            if (uart_count < 8) uart_byte[uart_count] = b;
            uart_count = uart_count + 1;
            $display("[UART ] byte #%0d = 0x%02x ('%c') stop=%0b", uart_count, b,
                     (b >= 8'h20 && b < 8'h7F) ? b : 8'h2E, st);
            if (!st) uart_ok = 1'b0;
        end
    endtask

    initial
        uart_recv_all();

    //------------------------------------------------------------------
    // 诊断开关（默认关闭）
    //------------------------------------------------------------------
    int TRACE_MAX = 0;          // >0：复位后逐拍打印取指对齐信息
    bit TRACE_WB  = 1'b0;       // 1：打印写回 / 访存事务
    int fa_cnt = 0, wb_cnt = 0;

    always @(posedge clk_sys) begin
        if (TRACE_MAX > 0 && rst_async && fa_cnt < TRACE_MAX) begin
            fa_cnt = fa_cnt + 1;
            $display("[FA] if_pc=%h rom_instr=%h | id_pc=%h id_instr=%h",
                     u_dut.u_CPU_top.if_pc, u_dut.u_CPU_top.if_instr,
                     u_dut.u_CPU_top.id_pc, u_dut.u_CPU_top.id_instr);
        end
        if (TRACE_WB && rst_sys == `RESET_DIS && u_dut.u_CPU_top.wb_rd_we && wb_cnt < 100) begin
            wb_cnt = wb_cnt + 1;
            $display("[WB] pc=%h x%0d <= %h", u_dut.u_CPU_top.u_MEM2WB.wb_pc4 - 4,
                     u_dut.u_CPU_top.wb_rd_addr, u_dut.u_CPU_top.wb_wdata);
        end
    end

    //------------------------------------------------------------------
    // 检查
    //------------------------------------------------------------------
    int    errors = 0, checks = 0;
    string names [0:31];

    task automatic check(input int id, input logic [31:0] got,
                             input logic [31:0] exp);
        checks = checks + 1;
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
        $display("  RESULT            = 0x%08x", peek_ram(0));
        $display("  DONE              = 0x%08x", peek_ram(DONE_WORD));
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
    logic [31:0] prog [0:PROG_WORDS-1];
    logic [31:0] exp_addr [0:MAX_SLOTS-1];
    logic [31:0] exp_val  [0:MAX_SLOTS-1];
    string       exp_name [0:MAX_SLOTS-1];
    int          n_slots = 0;
    int          n_pass  = 0, n_fail = 0;
    int          fd, i, rd_ok;
    string       line, nm;
    logic [31:0] v, a;

    initial begin
        names[0]  = "RESULT_word";
        names[1]  = "DONE_magic";
        names[2]  = "GPIO_DIR";
        names[3]  = "GPIO_DATA";
        names[4]  = "GPIO_IN_loopback";
        names[5]  = "TIMER_overflow_set";
        names[6]  = "UART_sent_OK_newline";

        $display("==========================================================");
        $display(" tb_top - RV32I 系统级验证（SoC + ROM/RAM IP + 外设）");
        $display("==========================================================");

        // ---- 0. 读期望值表（结果槽：每行「期望值 名称」）----
        fd = $fopen(EXP_FILE, "r");
        if (fd == 0) begin
            $display("[FATAL] 打不开期望值文件：%s", EXP_FILE);
            $display("        先运行 python3 tb/prog/gen_cpu_test.py");
            $finish;
        end
        // 每行格式：RAM 字节地址 期望值 名称
        while ($fgets(line, fd) != 0 && n_slots < MAX_SLOTS) begin
            if (line.len() > 2) begin
                rd_ok = $sscanf(line, "%h %h %s", a, v, nm);
                if (rd_ok == 3) begin
                    exp_addr[n_slots] = a;
                    exp_val[n_slots]  = v;
                    exp_name[n_slots] = nm;
                    n_slots = n_slots + 1;
                end
            end
        end
        $fclose(fd);
        if (n_slots == 0) begin
            $display("[FATAL] 期望值文件为空：%s", EXP_FILE);
            $finish;
        end
        $display("==> 结果槽 %0d 个（来自 %s）", n_slots, EXP_FILE);

        // ---- 1. 检查程序镜像存在（ROM 内容由 ROM.mif 提供）----
        for (i = 0; i < PROG_WORDS; i = i + 1) prog[i] = 32'h0000_0013;
        fd = $fopen(PROG_FILE, "r");
        if (fd == 0) begin
            $display("[FATAL] 打不开程序镜像：%s", PROG_FILE);
            $finish;
        end
        $fclose(fd);
        $display("==> 程序镜像：%s", PROG_FILE);
        $display("    （ROM 实际内容由 tb/prog/ROM.mif 提供，run_tb.tcl 会拷到运行目录）");

        // ---- 2. 复位 ----
        rst_async = 1'b0;
        repeat (10) @(posedge clk_sys);
        rst_async = 1'b1;
        $display("==> 复位释放，CPU 运行中");

        // ---- 3. 等 DONE 魔数（带超时）----
        fork : wait_done
            begin
                wait (done_seen);
                #(15 * BIT_NS);         // 让流水线里的 store 落地、串口把 3 字节发完
                $display("==> 程序跑完，t=%0t（PC=%h，RAM 写 %0d 次）",
                         $time, cur_pc, ram_wr_cnt);
            end
            begin
                #(TIMEOUT_NS);
                $display("[FATAL] 超时：%0t 内没有看到 DONE 魔数", TIMEOUT_NS);
                errors = errors + 1;
            end
        join_any
        disable wait_done;

        // ---- 4. 结果槽逐项比对 ----
        $display("");
        $display("-- 1) 期望值表逐项比对（共 %0d 项：指令结果槽 + CSR + 陷阱记录）--",
                 n_slots);
        for (i = 0; i < n_slots; i = i + 1) begin
            v = peek_ram(exp_addr[i][15:2]);
            checks = checks + 1;
            if (v === exp_val[i])
                n_pass = n_pass + 1;
            else begin
                n_fail = n_fail + 1;
                errors = errors + 1;
                $display("[FAIL] #%0d %s @RAM+0x%03x : got=0x%08x exp=0x%08x",
                         i, exp_name[i], exp_addr[i], v, exp_val[i]);
            end
        end
        $display("     期望值：通过 %0d / 失败 %0d", n_pass, n_fail);

        // ---- 5. RESULT / DONE ----
        $display("");
        $display("-- 2) RESULT / DONE --");
        check(0, peek_ram(0), 32'h1);
        check(1, peek_ram(DONE_WORD), DONE_MAGIC);

        // ---- 6. GPIO / TIMER ----
        $display("");
        $display("-- 3) 外设副作用 --");
        check(2, {24'b0, gpio_t}, 32'h0000_00FF);
        check(3, {24'b0, gpio_o}, 32'h0000_005A);
        check(4, {24'b0, gpio_i}, 32'h0000_005A);
        check(5, u_dut.u_TIMER.overflow_reg, 32'h1);

        // ---- 7. UART 实际波形 ----
        $display("");
        $display("-- 4) UART 引脚输出 --");
        #(2 * BIT_NS);
        if (uart_count >= 3 && uart_ok &&
                uart_byte[0] == 8'h4F &&        // 'O'
                uart_byte[1] == 8'h4B &&        // 'K'
                uart_byte[2] == 8'h0A)          // '\n'
            $display("[PASS] #6 %s : '%c','%c','\\n' 停止位有效",
                     names[6], uart_byte[0], uart_byte[1]);
        else begin
            $display("[FAIL] #6 %s : count=%0d stop_ok=%0b bytes=%02x %02x %02x",
                     names[6], uart_count, uart_ok,
                     uart_byte[0], uart_byte[1], uart_byte[2]);
            errors = errors + 1;
        end
        checks = checks + 1;

        // ---- 8. 结论 ----
        $display("");
        $display("==========================================================");
        $display(" 检查项：期望值 %0d + 其它 6 项 = %0d", n_slots, checks);
        if (errors == 0)
            $display("==> tb_top 通过：RV32I 40/40（含 ECALL/EBREAK/FENCE）+ Zicsr 系统级验证通过");
        else begin
            $display("==> tb_top 失败：%0d 项不符", errors);
            dump_state();
        end
        $display("==========================================================");
        $finish;
    end

endmodule
