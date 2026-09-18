`include "../../sys_define.svh"

module ID (
  input logic [1:0] op1_sel,
  input logic [0:0] op2_sel,

  input logic [`DATA_BUS] imm,
  input logic [`DATA_BUS] rs1_data,
  input logic [`DATA_BUS] rs2_data,
  input logic [`INST_BUS] instr_addr,

  output logic [`DATA_BUS] op1,
  output logic [`DATA_BUS] op2
);

  always_comb begin
    case (op1_sel)
      `OP1_RS1:  op1 = rs1_data;
      `OP1_PC :  op1 = instr_addr;
      `OP1_ZERO: op1 = 32'b0;
      default :  op1 = 32'b0;
    endcase
  end

  always_comb begin
    case (op2_sel)
      `OP2_RS2: op2 = rs2_data;
      `OP2_IMM: op2 = imm;
      default : op2 = 32'b0;
    endcase
  end

endmodule

