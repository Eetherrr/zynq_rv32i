`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// MEM_req : 访存请求生成（地址 / 写数据 / 字节使能）
//
//   ★ 本模块在 **EX 级** 例化，不是在 MEM 级 ★
//
//   为什么必须提前到 EX 级发起？
//     ROM / RAM 是 Block Memory Generator，寄存输出、读延迟 1 拍：
//       T 拍给 addra → T+1 拍 douta 才是该地址的数据。
//     load 的地址由 EX 级 ALU 算出。如果等到 MEM 级才把地址送出去，
//     数据要到 MEM 的下一拍才回来，而 MEM 的字节通道提取用的是
//     mem_alu_result[1:0]，那时地址早已前进 —— 通道选择与数据永远差一拍
//     （这正是本项目此前 lw / lbu / lhu 读回错误的原因）。
//
//     地址连同 we/be/wdata 一起在 EX 级发起后，BRAM 的 1 拍延迟正好落在
//     MEM 级：
//       EX 拍 ：给出 addr（BRAM 在本拍沿寄存该地址）
//       MEM 拍：douta = mem[addr]，而 mem_alu_result 正是同一个地址
//               （EX 拍 ALU 结果的流水寄存器值），通道选择天然对齐。
//
//   代价与约束：
//     - 地址通路变成「EX 级 ALU → BRAM 地址」，是 EX 级组合通路的一部分；
//     - 访问在 EX 拍提交（写在同一拍沿落盘），仍是严格程序序；
//     - EX 级指令不可能被更老的指令冲刷（分支/异常都在 EX 级由它自己
//       产生），因此提前发起访存不会被误发。
//
//   写数据对齐 / 字节使能的规则与旧 MEM 模块完全一致（tb_mem 逐项验证）。
//=====================================================================
module MEM_req (
    // ---------- 来自 EX 级 ----------
    input  wire [`DATA_BUS]  mem_alu_result,   // EX 级 ALU 结果 = 访存地址
    input  wire [`DATA_BUS]  mem_rs2_data,     // store 数据（前递后的 rs2）
    input  wire [      1:0]  mem_size,         // MSZ_B / MSZ_H / MSZ_W
    input  wire              mem_read,
    input  wire              mem_write,

    // ---------- 输出到存储器接口（RIB 主机侧）----------
    output logic [`DATA_BUS] mem_addr,         // 字节地址
    output logic [`DATA_BUS] mem_wdata,        // 已对齐到正确字节通道
    output logic [      3:0] mem_be,           // 字节使能
    output logic             mem_req,          // 读或写请求（本拍有效）
    output logic             mem_we,           // 1=写, 0=读
    output logic             mem_align_err     // 地址不对齐（非对齐访问不得触内存）
);

    //------------------------------------------------------------------
    // 0. 地址对齐检查（必须在发起之前做）
    //    非对齐访问要在 EX 级就拦下来并报异常，否则：
    //      · 非对齐 store 会先写坏内存再报异常（副作用先于陷阱）
    //      · 该指令还要在 MRET 后重放，等于写两次
    //    因此 mem_req/mem_we 都对 mem_align_err 做门控。
    //------------------------------------------------------------------
    always_comb begin
        case (mem_size)
            `MSZ_B : mem_align_err = `FALSE;
            `MSZ_H : mem_align_err = mem_alu_result[0];
            `MSZ_W : mem_align_err = (mem_alu_result[1:0] != 2'b00);
            default: mem_align_err = `FALSE;
        endcase
        if (!(mem_read | mem_write)) mem_align_err = `FALSE;
    end

    //------------------------------------------------------------------
    // 1. 地址直接来自 ALU 结果
    //------------------------------------------------------------------
    assign mem_addr = mem_alu_result;
    assign mem_req  = (mem_read | mem_write) & ~mem_align_err;
    assign mem_we   = mem_write & ~mem_align_err;

    //------------------------------------------------------------------
    // 2. 存储数据对齐
    //    把 rs2 的低字节挪到目标字节通道上
    //    B : 按 addr[1:0] 选通道
    //    H : 按 addr[1]   选半字
    //    W : 整字
    //------------------------------------------------------------------
    always_comb begin
        case (mem_size)
            `MSZ_B : begin
                case (mem_alu_result[1:0])
                    2'b00  : mem_wdata = {24'b0,            mem_rs2_data[7:0]};
                    2'b01  : mem_wdata = {16'b0, mem_rs2_data[7:0], 8'b0};
                    2'b10  : mem_wdata = { 8'b0, mem_rs2_data[7:0], 16'b0};
                    2'b11  : mem_wdata = {        mem_rs2_data[7:0], 24'b0};
                endcase
            end
            `MSZ_H : begin
                case (mem_alu_result[1])
                    1'b0   : mem_wdata = {16'b0, mem_rs2_data[15:0]};
                    1'b1   : mem_wdata = {mem_rs2_data[15:0], 16'b0};
                endcase
            end
            default: mem_wdata = mem_rs2_data;   // MSZ_W
        endcase
    end

    //------------------------------------------------------------------
    // 3. 字节使能
    //    MEM 保证 be 是「连续若干位」，CPU_SOC_top 据此反推访问宽度
    //    （B → 1 位、H → 2 位、W → 4 位），因此这里不能改编码。
    //------------------------------------------------------------------
    always_comb begin
        case (mem_size)
            `MSZ_B : mem_be = 4'b0001 << mem_alu_result[1:0];
            `MSZ_H : mem_be = mem_alu_result[1] ? 4'b1100 : 4'b0011;
            default: mem_be = 4'b1111;
        endcase
    end

endmodule
