`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// ROM : 指令存储器（封装 Xilinx Block Memory Generator 例化核）
//
//   IP 位置 : prj/zynq_rv32i.srcs/sources_1/ip/ROM
//     单口 ROM，4096 x 32 bit = 16 KiB
//     输出寄存器已启用（C_READ_LATENCY_A = 1）
//     -> T 拍给 addra，T+1 拍 douta 有效
//
//   时序语义（与流水线对齐，重要）
//     本模块的 rdata 是「上一拍 addr 的响应」，不是同拍组合结果。
//     ROM 无使能引脚，每个时钟沿都会用当前 addra 读一次，因此：
//       - 在 CPU_top 中把 rdata 直接接到 IF2ID 的 instr_i；
//       - IF 阶段取指不再需要等待周期，也不需要为读操作冻结 PC；
//       - 但 addr 在响应回来那一拍必须已经稳定（PC 在同一拍不跳变即可）。
//
//   端口与旧版本保持一致，便于 CPU_top / RIB 少改。
//=====================================================================
module ROM_Ctrl #(
        parameter              INIT_EN   = 0,     // 保留参数：初始化由 IP 的 .coe 完成
        parameter              INIT_FILE = "",
        parameter int unsigned WORDS     = 4096
    ) (
        input  wire        clk_sys,
        input  wire        rst_sys,

        // ---- 从 RIB ----
        input  wire        sel,
        input  wire [31:0] addr,      // 从机内字节偏移（0 ~ WORDS*4-1）
        input  wire [31:0] wdata,
        input  wire [ 1:0] size,
        input  wire        we,
        input  wire        re,
        output logic [31:0] rdata     // 上一拍 addr 对应的字（IP 寄存输出）
    );

    // IP 的 addra 是字地址。显式声明位宽，避免把 32 位地址整段接进去。
    logic [11:0] word_addr;
    assign word_addr = addr[13:2];

    // 本设计把 ROM 当只读用（程序镜像由 IP 的 .coe 初始化）。
    // 仍保留写通路：只有显式的写请求（we & sel）才写，正常取指恒为 0。
    logic        ip_we;
    logic [31:0] ip_dout;

    assign ip_we = we & sel;

    ROM u_ROM_IP (
        .clka  (clk_sys),
        .wea   (ip_we),
        .addra (word_addr),
        .dina  (wdata),
        .douta (ip_dout)
    );

    // 寄存输出直接送下游流水寄存器
    assign rdata = ip_dout;

endmodule
