`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// RAM : 数据存储器
//   - 容量 : 16384 x 32 bit = 64 KiB，对应 RAM_BASE / RAM_MASK
//   - 读   : 组合读，单周期返回（与 MEM 阶段「读写同拍返回」假设一致）
//   - 写   : 同步写，支持 B / H / W 三种宽度（由 size 决定字节通道）
//
//   注意：addr 为字节地址，需右移 2 位取字地址。
//=====================================================================
module RAM #(
        parameter int unsigned WORDS = 16384
    ) (
        input  wire        clk_sys,
        input  wire        rst_sys,

        // ---- 从 RIB ----
        input  wire        sel,
        input  wire [31:0] addr,
        input  wire [31:0] wdata,
        input  wire [ 1:0] size,
        input  wire        we,
        input  wire        re,
        output logic [31:0] rdata
    );

    (* ram_style = "block" *) logic [31:0] mem[0:WORDS-1];

    //---- 组合读 ----
    always_comb begin
        if (rst_sys == `RESET_EN)
            rdata = 32'b0;
        else
            rdata = mem[addr[31:2]];
    end

    //---- 同步写（按字节使能）----
    //  注意：addr 是 RIB 裁好的「从机内偏移」，范围 0 ~ WORDS*4-1，
    //        因此 addr[31:2] 一定落在 mem 的下标范围内。
    always_ff @(posedge clk_sys) begin
        if (we) begin
            if (size == `MSZ_B) begin
                mem[addr[31:2]][8*addr[1:0]+:8] <= wdata[8*addr[1:0]+:8];
            end
            else if (size == `MSZ_H) begin
                mem[addr[31:2]][16*addr[1]+:16] <= wdata[16*addr[1]+:16];
            end
            else begin
                mem[addr[31:2]] <= wdata;
            end
        end
    end

endmodule
