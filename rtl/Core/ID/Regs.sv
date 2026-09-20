`timescale 1ns / 1ps

`include "../../sys_define.svh"

module Regs (
    input  wire             clk_sys,
    input  wire             rst_sys,
    input  wire [`ADDR_BUS] rs1_addr,
    input  wire [`ADDR_BUS] rs2_addr,
    output reg  [`DATA_BUS] rs1_data,
    output reg  [`DATA_BUS] rs2_data,
    input  wire [`ADDR_BUS] rd_addr,
    input  wire [`DATA_BUS] rd_data,
    input  wire             we_flag
);

    (* ram_style = "block" *) reg [`DATA_BUS] regs [0:`REG_NUM-1];

    integer i;

    // 同步写
    always @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            for (i = 0; i < `REG_NUM; i = i + 1) regs[i] <= 32'b0;
        end
        else if (we_flag && rd_addr != `REG_ZERO) begin
            regs[rd_addr] <= rd_data;
        end
    end

    // 组合读 + 同拍写优先前递
    // 说明: 与 WB 同拍写读时读新值，这是标准 5 级流水线行为，
    //       因为 ID 指令在程序序上一定比 WB 指令更新。
    always @(*) begin
        if (rst_sys == `RESET_EN || rs1_addr == `REG_ZERO)
            rs1_data = 32'b0;
        else if (rs1_addr == rd_addr && we_flag)
            rs1_data = rd_data;
        else
            rs1_data = regs[rs1_addr];
    end

    always @(*) begin
        if (rst_sys == `RESET_EN || rs2_addr == `REG_ZERO)
            rs2_data = 32'b0;
        else if (rs2_addr == rd_addr && we_flag)
            rs2_data = rd_data;
        else
            rs2_data = regs[rs2_addr];
    end

endmodule

