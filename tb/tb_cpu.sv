`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_cpu — 完整 CPU 功能验证（用行为级 ROM/RAM 替代 IP，纯 RTL 可跑）
//
//   目的：在不引入 Block Memory Generator IP 的前提下验证 CPU_top 本体，
//         包括取指、流水线、前递、冒险、分支/跳转、访存。
//
//   ROM/RAM 行为模型与 IP 语义一致：
//     - ROM 为寄存输出（读延迟 1 拍）
//     - RAM 为寄存输出（读延迟 1 拍），字节写使能仅在 we=1 时有效
//   程序镜像由本文件内的 prog 数组提供（test 中逐条编码）。
//
//   覆盖点（除原有的 ALU/分支/跳转外，重点覆盖数据侧）：
//     · load-use：load 后紧跟使用其结果的指令（无需停顿，靠 MEM→EX 前递）
//     · 背靠背 load：两条 load 连续，随后同时依赖两者
//     · store 的 rs2 无前递来源（必须取寄存器堆原值，不能取立即数）
//     · store → load 同地址
//     · LB/LH 符号扩展、LBU/LHU 零扩展，字节 / 半字写通道
//     · 循环（分支目标为「非幂等」指令，重复执行会立刻暴露）
//
//   运行： vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//            -tclargs tb_cpu rtl/Core/CPU_top.sv rtl/Core/Control.sv \
//              rtl/Core/IF/IF.sv rtl/Core/IF/PCReg.sv rtl/Core/IF/IF2ID.sv \
//              rtl/Core/ID/Decoder.sv rtl/Core/ID/Regs.sv rtl/Core/ID/ID.sv \
//              rtl/Core/ID/ID2EX.sv rtl/Core/EX/ALU.sv rtl/Core/EX/Branch.sv \
//              rtl/Core/EX/Jump.sv rtl/Core/EX/EX.sv rtl/Core/EX/EX2MEM.sv \
//              rtl/Core/MEM/MEM_req.sv rtl/Core/MEM/MEM_load.sv \
//              rtl/Core/MEM/MEM2WB.sv rtl/Core/WB/WB.sv
//=====================================================================

//---------------------------------------------------------------------
// 行为级 ROM（1 拍寄存输出，与 IP 配置一致；ROM 无使能）
//---------------------------------------------------------------------
module beh_rom #(parameter int WORDS = 4096) (
    input  wire        clk,
    input  wire [31:0] addr,
    output logic [31:0] dout
);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] addr_q;
    always_ff @(posedge clk) addr_q <= addr;
    always_comb dout = mem[addr_q[13:2]];
endmodule

//---------------------------------------------------------------------
// 行为级 RAM（1 拍寄存输出 + 字节写）
//   语义与 rtl/Peripheral/RAM.sv（BMG IP）严格一致：
//     - ena = sel & (we | re)；ena=0 时地址寄存器与输出都保持
//     - 字节写使能只在 we=1 时有效（★ 读访问绝不能写）
//     - T 拍给 addr，T+1 拍 dout 才是该地址的数据
//---------------------------------------------------------------------
module beh_ram #(parameter int WORDS = 16384) (
    input  wire        clk,
    input  wire        ena,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] din,
    input  wire [ 3:0] wea,
    output logic [31:0] dout
);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] addr_q;
    always_ff @(posedge clk) begin
        if (ena) begin
            addr_q <= addr;
            if (we) begin
                if (wea[0]) mem[addr[15:2]][ 7: 0] <= din[ 7: 0];
                if (wea[1]) mem[addr[15:2]][15: 8] <= din[15: 8];
                if (wea[2]) mem[addr[15:2]][23:16] <= din[23:16];
                if (wea[3]) mem[addr[15:2]][31:24] <= din[31:24];
            end
        end
    end
    always_comb dout = mem[addr_q[15:2]];
endmodule

//---------------------------------------------------------------------
// 测试平台
//---------------------------------------------------------------------
module tb_cpu;
    logic clk = 0, rst_sys = `RESET_EN;
    always #5 clk = ~clk;

    logic [31:0] rom_addr, rom_data;
    logic [31:0] ram_addr, ram_data_o, ram_data_i;
    logic [ 3:0] ram_be;
    logic        ram_we, ram_re;

    beh_rom u_rom (.clk(clk), .addr(rom_addr), .dout(rom_data));

    // 访问 RAM 时使能，否则保持（与 RAM_Ctrl 的 ena = sel & (we|re) 一致）
    wire ram_sel = (ram_addr[31:16] == 16'h1000);
    wire ram_ena = ram_sel & (ram_we | ram_re);
    beh_ram u_ram (.clk(clk), .ena(ram_ena), .we(ram_we), .addr(ram_addr),
                   .din(ram_data_o), .wea(ram_be), .dout(ram_data_i));

    CPU_top u_cpu (
        .clk_sys(clk), .rst_sys(rst_sys),
        .rom_instr_i(rom_data), .rom_instr_addr_o(rom_addr),
        .ram_addr_o(ram_addr), .ram_data_o(ram_data_o), .ram_be_o(ram_be),
        .ram_we_o(ram_we), .ram_re_o(ram_re), .ram_data_i(ram_data_i),
        .int_i(8'b0), .hold_flag_i(1'b0),
        .if_grant_i(1'b1),          // 单主机：取指始终获得授权
        .bus_grant_valid_i(1'b0)
    );

    //------------------------------------------------------------------
    // 指令编码助手
    //------------------------------------------------------------------
    function automatic logic [31:0] R(input int f7, input int rs2, input int rs1, input int f3, input int rd);
        R = (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|7'b0110011; endfunction
    function automatic logic [31:0] I(input int imm, input int rs1, input int f3, input int rd, input logic [6:0] op);
        I = ((imm&12'hfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op; endfunction
    function automatic logic [31:0] S(input int imm, input int rs2, input int rs1, input int f3);
        S = (((imm>>5)&7'h7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&5'h1f)<<7)|7'b0100011; endfunction
    function automatic logic [31:0] B(input int imm, input int rs2, input int rs1, input int f3);
        B = (((imm>>12)&1)<<31)|(((imm>>5)&6'h3f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|
            (((imm>>1)&4'hf)<<8)|(((imm>>11)&1)<<7)|7'b1100011; endfunction
    function automatic logic [31:0] U(input int imm20, input int rd, input logic [6:0] op);
        U = ((imm20&20'hfffff)<<12)|(rd<<7)|op; endfunction
    function automatic logic [31:0] J(input int imm, input int rd);
        J = (((imm>>20)&1)<<31)|(((imm>>1)&10'h3ff)<<21)|(((imm>>11)&1)<<20)|
            (((imm>>12)&8'hff)<<12)|(rd<<7)|7'b1101111; endfunction

    localparam logic [31:0] NOP  = 32'h0000_0013;
    localparam logic [6:0] ADDI = 7'b0010011;
    localparam logic [6:0] LW   = 7'b0000011;
    localparam logic [6:0] SW_  = 7'b0100011;
    localparam logic [6:0] BR   = 7'b1100011;
    localparam logic [6:0] LUI  = 7'b0110111;
    localparam logic [6:0] AUIPC= 7'b0010111;
    localparam logic [6:0] JALR = 7'b1100111;
    localparam logic [6:0] RT   = 7'b0110011;

    //------------------------------------------------------------------
    // 测试程序：每 4 字节一条
    //   x20 = RAM 基址 0x1000_0000
    //   结果除寄存器外还写进 RAM 若干字，便于逐项核对
    //------------------------------------------------------------------
    logic [31:0] prog [0:255];
    int n_insn = 0;
    task automatic emit(input logic [31:0] w); prog[n_insn] = w; n_insn = n_insn + 1; endtask

    // 期望值检查
    int errors = 0, checks = 0;
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks = checks + 1;
        if (g !== e) begin errors = errors + 1;
            $display("  [FAIL] %-40s got=%h exp=%h", n, g, e); end
    endtask
    function automatic logic [31:0] X(input int i); X = u_cpu.u_Regs.regs[i]; endfunction

    // 访存事务探针（TRACE_MEM=1 打开）
    bit TRACE_MEM = 1'b0;
    always @(posedge clk) begin
        if (TRACE_MEM && rst_sys == `RESET_DIS && (ram_we || ram_re))
            $display("[MEM] t=%0t addr=%h we=%b re=%b wdata=%h mem0=%h",
                     $time, ram_addr, ram_we, ram_re, ram_data_o, u_ram.mem[0]);
    end

    int i, jal_idx, jalr_idx;
    initial begin
        // 导出 VCD 供波形分析（路径相对仿真运行目录 sim/unit）
        $dumpfile("cpu_wave.vcd");
        $dumpvars(0, tb_cpu);
    end

    initial begin
        $display("==========================================================");
        $display(" tb_cpu - 完整 CPU 功能验证（行为级存储器）");
        $display("==========================================================");

        for (i = 0; i < 256; i = i + 1) prog[i] = NOP;

        //=== 算术/逻辑 ===
        emit(I(10, 0, 3'b000, 1, ADDI));       // 0x00 addi x1, x0, 10
        emit(I(20, 0, 3'b000, 2, ADDI));       // 0x04 addi x2, x0, 20
        emit(R(7'h00, 2, 1, 3'b000, 3));       // 0x08 add  x3, x1, x2
        emit(R(7'h20, 2, 3, 3'b000, 4));       // 0x0c sub  x4, x3, x2
        emit(R(7'h00, 2, 1, 3'b111, 5));       // 0x10 and
        emit(R(7'h00, 2, 1, 3'b110, 6));       // 0x14 or
        emit(R(7'h00, 2, 1, 3'b100, 7));       // 0x18 xor
        emit(R(7'h00, 2, 1, 3'b001, 8));       // 0x1c sll
        emit(R(7'h00, 2, 1, 3'b010, 9));       // 0x20 slt
        emit(R(7'h00, 2, 1, 3'b011, 10));      // 0x24 sltu
        emit(R(7'h00, 2, 1, 3'b101, 11));      // 0x28 srl
        emit(R(7'h20, 2, 1, 3'b101, 12));      // 0x2c sra
        emit(I(-1, 1, 3'b000, 13, ADDI));      // 0x30 addi x13, x1, -1
        emit(I('h7ff, 0, 3'b000, 14, ADDI));   // 0x34 addi x14
        emit(I(5, 1, 3'b001, 15, ADDI));       // 0x38 slli x15, x1, 5
        emit(I(1, 1, 3'b010, 16, ADDI));       // 0x3c slti
        emit(I('h123, 0, 3'b111, 17, ADDI));   // 0x40 andi
        emit(U('hABCDE, 18, LUI));             // 0x44 lui x18
        //=== 访存基础 ===
        emit(U('h10000, 20, LUI));             // 0x48 lui x20, 0x10000  = RAM 基址
        emit(I('h123, 0, 3'b000, 21, ADDI));   // 0x4c addi x21 = 0x123
        emit(S(0, 21, 20, 3'b010));            // 0x50 sw   x21, 0(x20)   mem[0]=0x123
        emit(I(4, 20, 3'b000, 22, ADDI));      // 0x54 addi x22 = x20+4   (RAW 前递)
        emit(I('h55, 0, 3'b000, 23, ADDI));    // 0x58 addi x23 = 0x55
        emit(S(0, 23, 22, 3'b000));            // 0x5c sb   x23, 0(x22)   mem[1] byte0=0x55
        emit(I(0, 22, 3'b100, 24, LW));        // 0x60 lbu  x24, 0(x22)   = 0x55
        emit(I(0, 20, 3'b010, 25, LW));        // 0x64 lw   x25, 0(x20)   = 0x123
        emit(I('h7F, 0, 3'b000, 26, ADDI));    // 0x68 addi x26 = 0x7F
        emit(S(2, 26, 20, 3'b001));            // 0x6c sh   x26, 2(x20)   mem[0] 高半字=0x7F
        emit(I(2, 20, 3'b101, 27, LW));        // 0x70 lhu  x27, 2(x20)   = 0x7F
        //=== load-use / 背靠背 load / store 数据源 ===
        emit(I(0, 20, 3'b010, 19, LW));        // 0x74 lw   x19, 0(x20)   = 0x007F0123
        emit(R(7'h00, 19, 19, 3'b000, 26));    // 0x78 add  x26, x19, x19 ★load-use = 0x00FE0246
        emit(S(8, 26, 20, 3'b010));            // 0x7c sw   x26, 8(x20)   mem[2]=0x00FE0246
        emit(S(12, 18, 20, 3'b010));           // 0x80 sw   x18, 12(x20)  ★rs2 无前递 = 0xABCDE000
        emit(I(12, 20, 3'b010, 19, LW));       // 0x84 lw   x19, 12(x20)  store→load 同址
        emit(I(8, 20, 3'b010, 26, LW));        // 0x88 lw   x26, 8(x20)   ★背靠背 load
        emit(R(7'h00, 26, 19, 3'b000, 28));    // 0x8c add  x28, x19, x26 = 0xACCBE246
        emit(S(16, 28, 20, 3'b010));           // 0x90 sw   x28, 16(x20)  mem[4]=0xACCBE246
        //=== 字节 / 半字 读写与符号扩展 ===
        emit(S(4, 19, 20, 3'b010));            // 0x94 sw   x19, 4(x20)   mem[1]=0xABCDE000
        emit(S(2, 28, 22, 3'b000));            // 0x98 sb   x28, 2(x22)   mem[1] byte2=0x46
        emit(I(2, 22, 3'b000, 26, LW));        // 0x9c lb   x26, 2(x22)   = 0x46
        emit(S(24, 26, 20, 3'b010));           // 0xa0 sw   x26, 24(x20)  mem[6]=0x46
        emit(I(-5, 0, 3'b000, 28, ADDI));      // 0xa4 addi x28 = 0xFFFFFFFB
        emit(S(3, 28, 22, 3'b000));            // 0xa8 sb   x28, 3(x22)   mem[1] byte3=0xFB
        emit(I(3, 22, 3'b000, 26, LW));        // 0xac lb   x26, 3(x22)   = 0xFFFFFFFB
        emit(S(28, 26, 20, 3'b010));           // 0xb0 sw   x26, 28(x20)  mem[7]=0xFFFFFFFB
        emit(I(3, 22, 3'b100, 26, LW));        // 0xb4 lbu  x26, 3(x22)   = 0xFB
        emit(S(32, 26, 20, 3'b010));           // 0xb8 sw   x26, 32(x20)  mem[8]=0xFB
        emit(I(-1, 0, 3'b000, 28, ADDI));      // 0xbc addi x28 = 0xFFFFFFFF
        emit(S(6, 28, 20, 3'b001));            // 0xc0 sh   x28, 6(x20)   mem[1] 高半字=0xFFFF
        emit(I(6, 20, 3'b001, 26, LW));        // 0xc4 lh   x26, 6(x20)   = 0xFFFFFFFF
        emit(S(36, 26, 20, 3'b010));           // 0xc8 sw   x26, 36(x20)  mem[9]=0xFFFFFFFF
        emit(I(6, 20, 3'b101, 26, LW));        // 0xcc lhu  x26, 6(x20)   = 0xFFFF
        emit(S(40, 26, 20, 3'b010));           // 0xd0 sw   x26, 40(x20)  mem[10]=0xFFFF
        //=== 分支 ===
        emit(I(5, 0, 3'b000, 29, ADDI));       // 0xd4 addi x29, x0, 5
        emit(B(8, 29, 29, 3'b000));            // 0xd8 beq x29,x29,+8 → 0xe0
        emit(I(99, 0, 3'b000, 29, ADDI));      // 0xdc 跳过
        emit(I(7, 0, 3'b000, 30, ADDI));       // 0xe0 addi x30, x0, 7
        emit(B(8, 30, 29, 3'b001));            // 0xe4 bne x29,x30,+8 → 0xec
        emit(I(99, 0, 3'b000, 29, ADDI));      // 0xe8 跳过
        emit(I(1, 0, 3'b000, 31, ADDI));       // 0xec addi x31, x0, 1
        //=== JAL ===
        emit(J(8, 0));                         // 0xf0 jal x0, +8 → 0xf8
        emit(I(99, 0, 3'b000, 31, ADDI));      // 0xf4 跳过
        emit(I(2, 0, 3'b000, 31, ADDI));       // 0xf8 addi x31, x0, 2
        //=== 循环：分支目标是「非幂等」指令 ===
        emit(I(0, 0, 3'b000, 19, ADDI));       // 0xfc  addi x19, x0, 0   计数
        emit(I(0, 0, 3'b000, 26, ADDI));       // 0x100 addi x26, x0, 0   迭代变量
        emit(I(1, 19, 3'b000, 19, ADDI));      // 0x104 ← 循环目标 addi x19,x19,1
        emit(I(1, 26, 3'b000, 26, ADDI));      // 0x108 addi x26,x26,1
        emit(I(3, 0, 3'b000, 28, ADDI));       // 0x10c addi x28, x0, 3
        emit(B(-12, 28, 26, 3'b001));          // 0x110 bne x26,x28,-12 → 0x104
        emit(S(44, 19, 20, 3'b010));           // 0x114 sw   x19, 44(x20)  mem[11]=3
        //=== JAL / JALR 带链接：返回地址必须写回 rd ===
        emit(I(0, 0, 3'b000, 23, ADDI));       // 清除毒药寄存器 x23
        jal_idx = n_insn;
        emit(J(8, 22));                        // jal  x22, +8        x22 = jal_idx*4+4
        emit(I(99, 0, 3'b000, 23, ADDI));      // 跳过（跳转失败会写 x23=99）
        jalr_idx = n_insn;
        emit(I(n_insn*4 + 16, 0, 3'b000, 19, ADDI)); // addi x19, x0, <jalr 之后第 3 条>
        emit(I(0, 19, 3'b000, 26, JALR));      // jalr x26, 0(x19)    x26 = jalr_idx*4+8
        emit(I(99, 0, 3'b000, 23, ADDI));      // 跳过
        emit(I(99, 0, 3'b000, 23, ADDI));      // 跳过
        emit(I(77, 0, 3'b000, 28, ADDI));      // 落点：x28 = 77
        //=== 结束 ===
        emit(I(48, 20, 3'b000, 21, ADDI));     // addi x21, x20, 48 = mem[12]
        emit(S(0, 30, 21, 3'b010));            // 0x11c sw   x30, 0(x21)   mem[12]=7 完成标志
        emit(J(0, 0));                         // 0x120 挂死

        // ---- 载入 ROM ----
        for (i = 0; i < 4096; i = i + 1) u_rom.mem[i] = NOP;
        for (i = 0; i < n_insn; i = i + 1) u_rom.mem[i] = prog[i];
        $display("==> 已载入 %0d 条指令", n_insn);

        // ---- 复位 ----
        rst_sys = `RESET_EN;
        repeat (5) @(posedge clk);
        rst_sys = `RESET_DIS;

        // ---- 等待程序跑到自跳挂死（完成标志：mem[12] == 7）----
        begin : wait_done
            bit done = 1'b0;
            for (i = 0; i < 8000; i = i + 1) begin
                @(posedge clk);
                if (u_ram.mem[12] === 32'd7) begin done = 1'b1; i = 8000; end
            end
            $display("==> 等待结束：完成标志 %s（等待 %0d 拍）PC=%h",
                     done ? "已置位" : "未置位！程序未跑完", i, u_cpu.if_pc);
        end
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            $display("[HANG] t=%0t if_pc=%h id_pc=%h id_instr=%h",
                     $time, u_cpu.if_pc, u_cpu.id_pc, u_cpu.id_instr);
        end

        $display("\n-- 寄存器检查 --");
        ck32("x1  addi 10",      X(1),  32'd10);
        ck32("x2  addi 20",      X(2),  32'd20);
        ck32("x3  add 10+20",    X(3),  32'd30);
        ck32("x4  sub",          X(4),  32'd10);
        ck32("x5  and",          X(5),  32'd0);
        ck32("x6  or",           X(6),  32'd30);
        ck32("x7  xor",          X(7),  32'd30);
        ck32("x8  sll",          X(8),  32'd10 << 20);
        ck32("x9  slt",          X(9),  32'd1);
        ck32("x10 sltu",         X(10), 32'd1);
        ck32("x11 srl",          X(11), 32'd0);
        ck32("x12 sra",          X(12), 32'd0);
        ck32("x13 addi -1",      X(13), 32'd9);
        ck32("x14 addi 0x7FF",   X(14), 'h7FF);
        ck32("x15 slli",         X(15), 32'd320);
        ck32("x16 slti",         X(16), 32'd0);
        ck32("x17 andi",         X(17), 32'd0);
        ck32("x18 lui",          X(18), 'hABCD_E000);
        ck32("x24 lbu",          X(24), 'h55);
        ck32("x25 lw",           X(25), 'h123);
        ck32("x27 lhu",          X(27), 'h7F);
        ck32("x29 分支未误跳",   X(29), 32'd5);
        ck32("x30 beq/bne",      X(30), 32'd7);
        ck32("x31 jal",          X(31), 32'd2);
        ck32("x22 jal 链接值 pc+4", X(22), jal_idx*4 + 4);
        ck32("x26 jalr 链接值 pc+4", X(26), jalr_idx*4 + 8);
        ck32("x28 jalr 落点",     X(28), 32'd77);
        ck32("x23 跳转未失败",    X(23), 32'd0);

        $display("\n-- 存储器检查（访存数据通路）--");
        ck32("mem[0] sw 0x123 + sh 0x7F@2", u_ram.mem[0], 'h007F_0123);
        ck32("mem[1] sw/sb/sb/sh 组合",      u_ram.mem[1], 'hFFFF_E000);
        ck32("mem[2] load-use 结果",        u_ram.mem[2], 'h00FE_0246);
        ck32("mem[3] store rs2 无前递",     u_ram.mem[3], 'hABCD_E000);
        ck32("mem[4] 依赖两个 load",        u_ram.mem[4], 'hACCB_E246);
        ck32("mem[6] lb 正字节",            u_ram.mem[6], 32'h46);
        ck32("mem[7] lb 符号扩展",          u_ram.mem[7], 'hFFFF_FFFB);
        ck32("mem[8] lbu 零扩展",           u_ram.mem[8], 32'hFB);
        ck32("mem[9] lh 符号扩展",          u_ram.mem[9], 'hFFFF_FFFF);
        ck32("mem[10] lhu 零扩展",          u_ram.mem[10], 32'hFFFF);
        ck32("mem[11] 循环计数（非幂等目标）", u_ram.mem[11], 32'd3);
        ck32("mem[12] 完成标志",            u_ram.mem[12], 32'd7);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_cpu 全部通过"); else $display("==> tb_cpu 存在失败");
        $display("==========================================================");
        $finish;
    end

    // 超时
    initial begin
        #2000000;
        $display("[FATAL] 仿真超时，程序未跑完");
        $display("  PC=%h  x30=%0d  mem[12]=%h", u_cpu.if_pc, X(30), u_ram.mem[12]);
        $finish;
    end
endmodule
