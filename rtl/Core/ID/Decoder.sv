`include "../../sys_define.svh"

module Decoder (
        input  logic [`INST_BUS] instr,         // Instruction Input

        output logic [`ADDR_BUS] rs1_addr,
        output logic [`ADDR_BUS] rs2_addr,
        output logic [`ADDR_BUS] rd_addr,
        output logic             rd_we,
        output logic [      3:0] alu_op,        // ALU运算类型
        output logic [      1:0] op1_sel,       // 操作数1选择
        output logic [      0:0] op2_sel,       // 操作数2选择
        output logic [`DATA_BUS] imm,
        output logic [      1:0] wb_sel,        // 写回源选择
        output logic [      1:0] mem_size,      // 访存宽度
        output logic             mem_read,
        output logic             mem_write,
        output logic             mem_unsigned,  // 无符号加载
        output logic             branch,        // 分支指令
        output logic [      2:0] br_sel,        // 分支类型
        output logic             jump,          // 跳转指令
        output logic             jump_reg,      // JALR
        output logic             illegal,       // 非法指令
        output logic             ecall,
        output logic             ebreak,
        output logic             fence
    );

    // 公共字段提取
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [`ADDR_BUS] rs1, rs2, rd;

    assign opcode   = instr[6:0];
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign rd       = instr[11:7];
    assign funct3   = instr[14:12];
    assign funct7   = instr[31:25];

    assign rs1_addr = rs1;
    assign rs2_addr = rs2;

    // 立即数生成
    logic [`DATA_BUS] imm_i, imm_s, imm_b, imm_u, imm_j;

    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'b0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // 组合逻辑译码
    always_comb begin
        rd_addr      = rd;
        rd_we        = `DISABLE;
        alu_op       = `ALU_ADD;
        op1_sel      = `OP1_RS1;
        op2_sel      = `OP2_RS2;
        imm          = 32'b0;
        wb_sel       = `WB_ALU;
        mem_size     = `MSZ_W;
        mem_read     = `DISABLE;
        mem_write    = `DISABLE;
        mem_unsigned = `FALSE;
        branch    = `FALSE;
        br_sel       = `INST_BEQ;
        jump    = `FALSE;
        jump_reg   = `FALSE;
        illegal      = `FALSE;
        ecall        = `FALSE;
        ebreak       = `FALSE;
        fence        = `FALSE;

        case (opcode)
            `INST_LUI: begin
                rd_we   = `ENABLE;
                op1_sel = `OP1_ZERO;
                op2_sel = `OP2_IMM;
                alu_op  = `ALU_ADD;
                wb_sel  = `WB_ALU;
                imm     = imm_u;
            end
            `INST_AUIPC: begin
                rd_we   = `ENABLE;
                op1_sel = `OP1_PC;
                op2_sel = `OP2_IMM;
                alu_op  = `ALU_ADD;
                wb_sel  = `WB_ALU;
                imm     = imm_u;
            end
            `INST_JAL: begin
                rd_we     = `ENABLE;
                jump = `TRUE;
                wb_sel    = `WB_PC4;
                imm       = imm_j;
            end
            `INST_JALR: begin
                if (funct3 == `FCT3_JALR) begin
                    rd_we      = `ENABLE;
                    jump  = `TRUE;
                    jump_reg = `TRUE;
                    op1_sel    = `OP1_RS1;
                    op2_sel    = `OP2_IMM;
                    alu_op     = `ALU_ADD;
                    wb_sel     = `WB_PC4;
                    imm        = imm_i;
                end
                else begin
                    illegal = `TRUE;
                end
            end
            `INST_TYPE_B: begin
                branch = `TRUE;
                op1_sel   = `OP1_RS1;
                op2_sel   = `OP2_RS2;
                imm       = imm_b;
                case (funct3)
                    `INST_BEQ, `INST_BNE, `INST_BLT, `INST_BGE, `INST_BLTU, `INST_BGEU: begin
                        br_sel = funct3;
                    end
                    default:
                        illegal = `TRUE;
                endcase
            end
            `INST_TYPE_L: begin
                rd_we    = `ENABLE;
                mem_read = `ENABLE;
                op1_sel  = `OP1_RS1;
                op2_sel  = `OP2_IMM;
                alu_op   = `ALU_ADD;
                wb_sel   = `WB_MEM;
                imm      = imm_i;
                case (funct3)
                    `INST_LB: begin
                        mem_size = `MSZ_B;
                        mem_unsigned = `FALSE;
                    end
                    `INST_LH: begin
                        mem_size = `MSZ_H;
                        mem_unsigned = `FALSE;
                    end
                    `INST_LW: begin
                        mem_size = `MSZ_W;
                        mem_unsigned = `FALSE;
                    end
                    `INST_LBU: begin
                        mem_size = `MSZ_B;
                        mem_unsigned = `TRUE;
                    end
                    `INST_LHU: begin
                        mem_size = `MSZ_H;
                        mem_unsigned = `TRUE;
                    end
                    default:
                        illegal = `TRUE;
                endcase
            end
            `INST_TYPE_S: begin
                mem_write = `ENABLE;
                op1_sel   = `OP1_RS1;
                op2_sel   = `OP2_IMM;
                alu_op    = `ALU_ADD;
                imm       = imm_s;
                case (funct3)
                    `INST_SB: begin
                        mem_size = `MSZ_B;
                    end
                    `INST_SH: begin
                        mem_size = `MSZ_H;
                    end
                    `INST_SW: begin
                        mem_size = `MSZ_W;
                    end
                    default:
                        illegal = `TRUE;
                endcase
            end
            `INST_TYPE_I: begin
                rd_we   = `ENABLE;
                op1_sel = `OP1_RS1;
                op2_sel = `OP2_IMM;
                wb_sel  = `WB_ALU;
                imm     = imm_i;
                case (funct3)
                    `INST_ADDI:
                        alu_op = `ALU_ADD;
                    `INST_SLLI: begin
                        if (funct7 == `FCT7_L)
                            alu_op = `ALU_SLL;
                        else
                            illegal = `TRUE;
                    end
                    `INST_SLTI:
                        alu_op = `ALU_SLT;
                    `INST_SLTIU:
                        alu_op = `ALU_SLTU;
                    `INST_XORI:
                        alu_op = `ALU_XOR;
                    `INST_SRI: begin
                        if (funct7 == `FCT7_L)
                            alu_op = `ALU_SRL;
                        else if (funct7 == `FCT7_A)
                            alu_op = `ALU_SRA;
                        else
                            illegal = `TRUE;
                    end
                    `INST_ORI:
                        alu_op = `ALU_OR;
                    `INST_ANDI:
                        alu_op = `ALU_AND;
                    default:
                        illegal = `TRUE;
                endcase
            end
            `INST_TYPE_R: begin
                rd_we   = `ENABLE;
                op1_sel = `OP1_RS1;
                op2_sel = `OP2_RS2;
                wb_sel  = `WB_ALU;
                case ({
                              funct7, funct3
                          })
                    {`FCT7_L, `INST_ADD_SUB} :
                        alu_op = `ALU_ADD;
                    {`FCT7_A, `INST_ADD_SUB} :
                        alu_op = `ALU_SUB;
                    {`FCT7_L, `INST_SLL} :
                        alu_op = `ALU_SLL;
                    {`FCT7_L, `INST_SLT} :
                        alu_op = `ALU_SLT;
                    {`FCT7_L, `INST_SLTU} :
                        alu_op = `ALU_SLTU;
                    {`FCT7_L, `INST_XOR} :
                        alu_op = `ALU_XOR;
                    {`FCT7_L, `INST_SR} :
                        alu_op = `ALU_SRL;
                    {`FCT7_A, `INST_SR} :
                        alu_op = `ALU_SRA;
                    {`FCT7_L, `INST_OR} :
                        alu_op = `ALU_OR;
                    {`FCT7_L, `INST_AND} :
                        alu_op = `ALU_AND;
                    default:
                        illegal = `TRUE;
                endcase
            end
            `INST_TYPE_FENCE: begin
                if (funct3 == `INST_FENCE || funct3 == 3'b001) begin
                    fence = `TRUE;
                end
                else begin
                    illegal = `TRUE;
                end
            end
            `INST_TYPE_SYS: begin
                if (funct3 == `FCT3_PRIV) begin
                    case (instr[31:20])
                        12'h000:
                            ecall = `TRUE;
                        12'h001:
                            ebreak = `TRUE;
                        default:
                            illegal = `TRUE;
                    endcase
                end
                else begin
                    illegal = `TRUE;
                end
            end
            default: begin
                illegal = `TRUE;
            end
        endcase
    end

endmodule

