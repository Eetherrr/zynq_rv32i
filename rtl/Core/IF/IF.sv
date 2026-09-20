`timescale 1ns / 1ps

`include "../../sys_define.svh" 

module IF (
    input  wire [`DATA_BUS] pc,
    input  wire [`DATA_BUS] rom_data,
    output wire [`DATA_BUS] rom_addr,
    output wire [`DATA_BUS] instr_addr,
    output wire [`DATA_BUS] instr
);

    assign rom_addr   = pc;
    assign instr_addr = pc;
    assign instr      = rom_data;

endmodule
