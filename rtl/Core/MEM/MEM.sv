`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// MEM : 访存阶段
//   - 地址对齐检查
//   - 存储数据字节通道对齐
//   - 字节使能生成
//   - 加载数据提取 + 符号 / 零扩展
//
//   假设 : 单周期数据存储器（读写同拍返回），
//          若对接 RIB 从机（带 valid/ready），在顶层做握手适配即可。
//=====================================================================
module MEM (
    // ---------- 来自 EX2MEM ----------
    input  wire [`DATA_BUS]  mem_alu_result,   // 访存地址
    input  wire [`DATA_BUS]  mem_rs2_data,     // 存储数据 (前递后的 rs2)
    input  wire [      1:0]  mem_size,         // MSZ_B / MSZ_H / MSZ_W
    input  wire              mem_read,
    input  wire              mem_write,
    input  wire              mem_unsigned,

    // ---------- 来自数据存储器 ----------
    input  wire [`DATA_BUS]  mem_rdata,

    // ---------- 输出到存储器接口 ----------
    output logic [`DATA_BUS] mem_addr,
    output logic [`DATA_BUS] mem_wdata,        // 已对齐到正确字节通道
    output logic [      3:0] mem_be,           // 字节使能
    output logic             mem_req,          // 读或写请求
    output logic             mem_we,           // 1=写, 0=读

    // ---------- 输出到 MEM2WB ----------
    output logic [`DATA_BUS] mem_rdata_ext,    // 提取 + 扩展后的加载数据
    output logic             mem_align_err     // 地址不对齐异常
);

    //------------------------------------------------------------------
    // 1. 地址直接来自 ALU 结果
    //------------------------------------------------------------------
    assign mem_addr = mem_alu_result;
    assign mem_req  = mem_read | mem_write;
    assign mem_we   = mem_write;

    //------------------------------------------------------------------
    // 2. 地址对齐检查
    //    B : 无对齐要求
    //    H : addr[0] == 0
    //    W : addr[1:0] == 00
    //------------------------------------------------------------------
    always_comb begin
        case (mem_size)
            `MSZ_B : mem_align_err = `FALSE;
            `MSZ_H : mem_align_err = mem_alu_result[0];
            `MSZ_W : mem_align_err = (mem_alu_result[1:0] != 2'b00);
            default: mem_align_err = `FALSE;
        endcase
        // 只有访存指令才需要报对齐异常
        if (!(mem_read | mem_write)) mem_align_err = `FALSE;
    end

    //------------------------------------------------------------------
    // 3. 存储数据对齐
    //    把 rs2 的低字节挪到目标字节通道上
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
    // 4. 字节使能
    //------------------------------------------------------------------
    always_comb begin
        case (mem_size)
            `MSZ_B : mem_be = 4'b0001 << mem_alu_result[1:0];
            `MSZ_H : mem_be = mem_alu_result[1] ? 4'b1100 : 4'b0011;
            default: mem_be = 4'b1111;
        endcase
    end

    //------------------------------------------------------------------
    // 5. 加载数据提取（按地址低位选字节/半字）
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
    // 6. 符号 / 零扩展
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
