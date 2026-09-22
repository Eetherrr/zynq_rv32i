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
//     - RAM 为寄存输出（读延迟 1 拍），支持字节写
//   程序镜像由本文件内的 prog 数组提供（test_prog 中逐条编码）。
//
//   运行： vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//            -tclargs tb_cpu rtl/Core/CPU_top.sv rtl/Core/Control.sv \
//              rtl/Core/IF/IF.sv rtl/Core/IF/PCReg.sv rtl/Core/IF/IF2ID.sv \
//              rtl/Core/ID/Decoder.sv rtl/Core/ID/Regs.sv rtl/Core/ID/ID.sv \
//              rtl/Core/ID/ID2EX.sv rtl/Core/EX/ALU.sv rtl/Core/EX/Branch.sv \
//              rtl/Core/EX/Jump.sv rtl/Core/EX/EX.sv rtl/Core/EX/EX2MEM.sv \
//              rtl/Core/MEM/MEM.sv rtl/Core/MEM/MEM2WB.sv rtl/Core/WB/WB.sv
//=====================================================================

//---------------------------------------------------------------------
// 行为级 ROM（1 拍寄存输出，与 IP 配置一致）
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
//---------------------------------------------------------------------
module beh_ram #(parameter int WORDS = 16384) (
    input  wire        clk,
    input  wire        ena,
    input  wire [31:0] addr,
    input  wire [31:0] din,
    input  wire [ 3:0] wea,
    output logic [31:0] dout
);
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] addr_q;
    always_ff @(posedge clk) begin
        addr_q <= addr;
        if (ena) begin
            if (wea[0]) mem[addr[15:2]][ 7: 0] <= din[ 7: 0];
            if (wea[1]) mem[addr[15:2]][15: 8] <= din[15: 8];
            if (wea[2]) mem[addr[15:2]][23:16] <= din[23:16];
            if (wea[3]) mem[addr[15:2]][31:24] <= din[31:24];
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

    // 访问 RAM 时使能，否则保持
    wire ram_sel = (ram_addr[31:16] == 16'h1000);
    wire ram_ena = ram_sel & (ram_we | ram_re);
    beh_ram u_ram (.clk(clk), .ena(ram_ena), .addr(ram_addr),
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
    //------------------------------------------------------------------
    logic [31:0] prog [0:127];
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

    // 写通路探针
    always @(posedge clk) begin
        if (rst_sys == `RESET_DIS && (ram_we || ram_re))
            $display("[MEM] addr=%h we=%b re=%b be=%b wdata=%h | ena=%b mem0=%h",
                     ram_addr, ram_we, ram_re, ram_be, ram_data_o, ram_ena,
                     u_ram.mem[0]);
    end

    // 执行轨迹：只看 EX 级真实执行的指令（rd_we 或访存或分支，排除 NOP/气泡）
    logic [31:0] tr_q;
    int tr_n = 0;
    // IF2ID 锁存出的指令 = 该 PC 对应的指令（同沿同源）
    logic [7:0] tr_bytes [0:3];
    assign tr_bytes[0] = u_cpu.id_instr[7:0];
    assign tr_bytes[1] = u_cpu.id_instr[15:8];
    assign tr_bytes[2] = u_cpu.id_instr[23:16];
    assign tr_bytes[3] = u_cpu.id_instr[31:24];
    always @(posedge clk) begin
        tr_q <= u_cpu.id_ex_pc;
        if (rst_sys == `RESET_DIS && tr_n < 60 &&
            (u_cpu.id_ex_pc !== tr_q) && u_cpu.id_ex_pc !== 32'h0) begin
            tr_n = tr_n + 1;
            $display("[PC] 0x%03x  bytes=%h_%h", u_cpu.id_pc, tr_bytes[3], tr_bytes[0]);
        end
    end

    int i;
    initial begin
        $display("==========================================================");
        $display(" tb_cpu - 完整 CPU 功能验证（行为级存储器）");
        $display("==========================================================");

        for (i = 0; i < 128; i = i + 1) prog[i] = NOP;

        //=== 最小复现：store 后 load 同地址 ===
        emit(U('h10000, 20, LUI));        // 0x00 lui  x20, 0x10000
        emit(I('h123, 0, 3'b000, 21, ADDI)); // 0x04 addi x21, x0, 0x123
        emit(S(0, 21, 20, 3'b010));       // 0x08 sw   x21, 0(x20)
        emit(I(0, 20, 3'b010, 25, LW));   // 0x0c lw   x25, 0(x20)
        emit(J(0, 0));                    // 0x10 挂死

        // ---- 载入 ROM ----
        for (i = 0; i < 4096; i = i + 1) u_rom.mem[i] = NOP;
        for (i = 0; i < n_insn; i = i + 1) u_rom.mem[i] = prog[i];
        $display("==> 已载入 %0d 条指令", n_insn);

        // ---- 复位 ----
        rst_sys = `RESET_EN;
        repeat (5) @(posedge clk);
        rst_sys = `RESET_DIS;

        // ---- 等待程序跑到自跳挂死（检测 RAM+8 被写入 7）----
        for (i = 0; i < 800; i = i + 1) begin
            @(posedge clk);
            if (u_ram.mem[2] === 32'd7) i = 800;   // RAM base + 8 -> word 2
        end
        repeat (3) @(posedge clk);

        $display("\n-- 最小复现检查 --");
        ck32("x20 = RAM base",  X(20), 'h1000_0000);
        ck32("x21 = 0x123",     X(21), 'h123);
        ck32("x25 = lw 读回",   X(25), 'h123);
        ck32("RAM[0] 被写入",   u_ram.mem[0], 'h123);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_cpu 全部通过"); else $display("==> tb_cpu 存在失败");
        $display("==========================================================");
        $finish;
    end

    // 超时
    initial begin
        #200000;
        $display("[FATAL] 仿真超时，程序未跑完");
        $display("  PC=%h  x30=%0d  RAM[2]=%h", u_cpu.if_pc, X(30), u_ram.mem[2]);
        $finish;
    end
endmodule
