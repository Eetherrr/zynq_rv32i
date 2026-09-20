`timescale 1ns / 1ps

`include "../../sys_define.svh"

module ALU (
  input  logic [`DATA_BUS] op1,
  input  logic [`DATA_BUS] op2,
  input  logic [      3:0] alu_op,
  output logic [`DATA_BUS] result
);

  always_comb begin
    case (alu_op)
      `ALU_ADD : result = op1 + op2;
      `ALU_SUB : result = op1 - op2;
      `ALU_SLL : result = op1 << op2[4:0];
      `ALU_SLT : result = ($signed(op1) <  $signed(op2)) ? 32'd1 : 32'd0;
      `ALU_SLTU: result = (op1 <  op2)                  ? 32'd1 : 32'd0;
      `ALU_XOR : result = op1 ^ op2;
      `ALU_SRL : result = op1 >> op2[4:0];
      `ALU_SRA : result = $signed(op1) >>> op2[4:0];
      `ALU_OR  : result = op1 | op2;
      `ALU_AND : result = op1 & op2;
      default  : result = 32'b0;
    endcase
  end

endmodule
