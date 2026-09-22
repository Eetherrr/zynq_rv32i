`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// RAM : 数据存储器（封装 Xilinx Block Memory Generator 例化核）
//
//   IP 位置 : prj/zynq_rv32i.srcs/sources_1/ip/RAM
//     单口 RAM，16384 x 32 bit = 64 KiB，带 ena 与 4 位字节写使能 wea
//     输出寄存器已启用（C_READ_LATENCY_A = 1）
//     -> T 拍给 addra，T+1 拍 douta 有效
//
//   时序语义（与流水线对齐，重要）
//     本模块的 rdata 是「上一拍 addr 的响应」，不是同拍组合结果。
//     CPU 侧的对齐关系：
//       读 : MEM 级在 T 拍给出 mem_addr，rdata 在 T+1 拍沿被 MEM2WB 锁存，
//            与旧的「组合读」在流水线时序上完全等价，无需等待周期。
//       写 : wea/dina/addra 在 T 拍有效，在 T 拍沿写入，与旧行为一致。
//
//   端口与旧版本保持一致，便于 CPU_top / RIB 少改。
//=====================================================================
module RAM_Ctrl #(
        parameter int unsigned WORDS = 16384
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

    // IP 的 addra 是字地址
    logic [13:0] word_addr;
    assign word_addr = addr[15:2];

    // 字节写使能：由 size + 地址低位展开成 4 位 wea
    logic [3:0] byte_we;
    always_comb begin
        if (!we)
            byte_we = 4'b0000;
        else begin
            case (size)
                `MSZ_B:  byte_we = 4'b0001 << addr[1:0];
                `MSZ_H:  byte_we = addr[1] ? 4'b1100 : 4'b0011;
                default: byte_we = 4'b1111;
            endcase
        end
    end

    // 使能与写使能都只在被选中时有效，避免未选中时误改内容
    logic        ip_ena;
    logic [ 3:0] ip_wea;
    logic [31:0] ip_dout;

    assign ip_ena = sel & (we | re);
    assign ip_wea = sel ? byte_we : 4'b0000;

    RAM u_RAM_IP (
        .clka  (clk_sys),
        .ena   (ip_ena),
        .wea   (ip_wea),
        .addra (word_addr),
        .dina  (wdata),
        .douta (ip_dout)
    );

    // 寄存输出直接送下游（MEM2WB / MEM 的加载数据通路）
    assign rdata = ip_dout;

endmodule
