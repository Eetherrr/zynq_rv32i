`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// ROM : 指令存储器
//   - 容量 : 4096 x 32 bit = 16 KiB，对应 ROM_BASE / ROM_MASK
//   - 读   : 组合读，单周期返回（IF 阶段假设指令同拍可用）
//   - 写   : 留作程序加载 / 在线更新用途，正常运行时 we 恒为 0
//   - 初始化 : 可通过 ROM_INIT_FILE 指定 $readmemh 文件
//
//   注意：addr 为字节地址，需右移 2 位取字地址。
//=====================================================================
module ROM #(
        parameter              INIT_EN   = 0,
        parameter              INIT_FILE = "",
        parameter int unsigned WORDS     = 4096
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

    //---- 可选初始化 ----
    generate
        if (INIT_EN && INIT_FILE != "") begin : g_init
            initial begin
                $readmemh(INIT_FILE, mem);
            end
        end
    endgenerate

    //---- 组合读 ----
    always_comb begin
        if (rst_sys == `RESET_EN)
            rdata = 32'b0;
        else
            rdata = mem[addr[31:2]];
    end

    //---- 同步写（按字节使能）----
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
