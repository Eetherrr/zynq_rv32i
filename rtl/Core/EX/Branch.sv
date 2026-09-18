`include "../../sys_define.svh"

module Branch (
  input  logic [`DATA_BUS] op1,           // 前递后的 rs1
  input  logic [`DATA_BUS] op2,           // 前递后的 rs2
  input  logic [`DATA_BUS] pc,
  input  logic [`DATA_BUS] imm,           // imm_b
  input  logic             branch,        // 是分支指令
  input  logic [      2:0] br_sel,        // 分支类型
  output logic             branch_taken,  // branch=1 且条件成立
  output logic [`DATA_BUS] branch_target
);

  logic cond;

  always_comb begin
    case (br_sel)
      `INST_BEQ : cond = (op1 == op2);
      `INST_BNE : cond = (op1 != op2);
      `INST_BLT : cond = ($signed(op1) <  $signed(op2));
      `INST_BGE : cond = ($signed(op1) >= $signed(op2));
      `INST_BLTU: cond = (op1 <  op2);
      `INST_BGEU: cond = (op1 >= op2);
      default   : cond = `FALSE;
    endcase
  end

  assign branch_taken  = branch && cond;
  assign branch_target = pc + imm;

endmodule
