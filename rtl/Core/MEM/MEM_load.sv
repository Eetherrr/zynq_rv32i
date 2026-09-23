`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// MEM_load : MEM 级读数据通路
//   - 加载数据字节通道提取
//   - 符号 / 零扩展
//
//   时序前提（见 MEM_req 的说明）：
//     访存地址在 **EX 级** 发起，BRAM 读延迟 1 拍，因此在本模块（MEM 级）
//     看到的 mem_rdata 就是 mem_alu_result 这个地址的数据 ——
//     通道选择用 mem_alu_result[1:0] / [1] 与数据同拍，天然对齐。
//
//   写通路（地址 / 数据 / 字节使能）不经过本模块，见 MEM_req。
//=====================================================================
module MEM_load (
    // ---------- 来自 EX2MEM ----------
    input  wire [`DATA_BUS]  mem_alu_result,   // 访存地址（EX 级 ALU 结果）
    input  wire [      1:0]  mem_size,         // MSZ_B / MSZ_H / MSZ_W
    input  wire              mem_read,
    input  wire              mem_unsigned,

    // ---------- 来自数据存储器 ----------
    input  wire [`DATA_BUS]  mem_rdata,

    // ---------- 输出到 MEM2WB ----------
    output logic [`DATA_BUS] mem_rdata_ext     // 提取 + 扩展后的加载数据
);

    //------------------------------------------------------------------
    // 地址对齐检查已前移到 MEM_req（EX 级，发起访存之前），见那边说明。
    //------------------------------------------------------------------

    //------------------------------------------------------------------
    // 1. 加载数据提取（按地址低位选字节/半字）
    //------------------------------------------------------------------
    logic [`DATA_BUS] load_data;

    always_comb begin
        case (mem_size)
            `MSZ_B : begin
                case (mem_alu_result[1:0])
                    2'b00  : load_data = {24'b0, mem_rdata[ 7: 0]};
                    2'b01  : load_data = {24'b0, mem_rdata[15: 8]};
                    2'b10  : load_data = {24'b0, mem_rdata[23:16]};
                    2'b11  : load_data = {24'b0, mem_rdata[31:24]};
                endcase
            end
            `MSZ_H : begin
                case (mem_alu_result[1])
                    1'b0   : load_data = {16'b0, mem_rdata[15: 0]};
                    1'b1   : load_data = {16'b0, mem_rdata[31:16]};
                endcase
            end
            default: load_data = mem_rdata;
        endcase
    end

    //------------------------------------------------------------------
    // 2. 符号 / 零扩展
    //    - 非 load 指令输出 0
    //    - mem_unsigned=1 : 零扩展
    //    - mem_unsigned=0 : 符号扩展
    //------------------------------------------------------------------
    always_comb begin
        if (mem_read == `DISABLE) begin
            mem_rdata_ext = 32'b0;
        end
        else if (mem_unsigned == `TRUE) begin
            mem_rdata_ext = load_data;
        end
        else begin
            case (mem_size)
                `MSZ_B : mem_rdata_ext = {{24{load_data[ 7]}}, load_data[ 7:0]};
                `MSZ_H : mem_rdata_ext = {{16{load_data[15]}}, load_data[15:0]};
                default: mem_rdata_ext = load_data;
            endcase
        end
    end

endmodule
