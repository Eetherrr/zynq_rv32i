`include "../../sys_define.svh"

module Jump (
  input  logic [`DATA_BUS] pc,
  input  logic [`DATA_BUS] rs1,           // 前递后的 rs1（JALR 用）
  input  logic [`DATA_BUS] imm,
  input  logic             jump,          // 是跳转指令
  input  logic             jump_reg,      // 1 = JALR, 0 = JAL
  output logic             jump_taken,
  output logic [`DATA_BUS] jump_target
);

  logic [`DATA_BUS] target;

  assign target = jump_reg ? ((rs1 + imm) & ~32'd1)   // JALR
                           : (pc  + imm);             // JAL

  assign jump_taken  = jump;
  assign jump_target = target;

endmodule
