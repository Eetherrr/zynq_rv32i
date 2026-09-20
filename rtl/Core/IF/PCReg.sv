`timescale 1ns / 1ps

`include "../../sys_define.svh"

module PCReg (
    input  wire             clk_sys,
    input  wire             rst_sys,
    input  wire             stall,       // 新增: load-use 时保持 PC
    input  wire             jmp_flag,
    input  wire [`DATA_BUS] jmp_addr,
    output reg  [`DATA_BUS] pc
);

    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN)      pc <= `PC_RESET;
        else if (jmp_flag)             pc <= jmp_addr;
        else if (stall)                pc <= pc;
        else                           pc <= pc + 32'd4;
    end

endmodule
