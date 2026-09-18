`include "../sys_define.svh"

module Control (
    input  wire              clk_sys,
    input  wire              rst_sys,

    // 来自 EX 阶段
    input  wire              ex_branch_taken,
    input  wire              ex_jump_taken,
    input  wire [`DATA_BUS]  ex_branch_target,
    input  wire [`DATA_BUS]  ex_jump_target,
    input  wire              ex_illegal,
    input  wire              ex_ecall,
    input  wire              ex_ebreak,

    // EX 阶段当前指令 (来自 ID2EX)
    input  wire [`ADDR_BUS]  id_ex_rd_addr,
    input  wire              id_ex_rd_we,
    input  wire              id_ex_mem_read,

    // ID 阶段当前指令
    input  wire [`INST_BUS]  id_instr,
    input  wire [`ADDR_BUS]  id_rs1_addr,
    input  wire [`ADDR_BUS]  id_rs2_addr,

    // 输出
    output logic             flush_if2id,
    output logic             flush_id2ex,
    output logic             flush_ex2mem,
    output logic             flush_mem2wb,
    output logic             stall_pc,
    output logic             stall_if2id,
    output logic             stall_id2ex,

    // 重定向
    output logic             redirect_en,
    output logic [`DATA_BUS] redirect_pc,
    output logic             exception_en
);

    logic        id_uses_rs1, id_uses_rs2;
    logic [6:0]  id_opcode;

    assign id_opcode = id_instr[6:0];

    always @(*) begin
        id_uses_rs1 = `FALSE;
        id_uses_rs2 = `FALSE;
        case (id_opcode)
            `INST_JALR,
            `INST_TYPE_I,
            `INST_TYPE_L: begin
                id_uses_rs1 = `TRUE;
            end
            `INST_TYPE_S,
            `INST_TYPE_B,
            `INST_TYPE_R: begin
                id_uses_rs1 = `TRUE;
                id_uses_rs2 = `TRUE;
            end
            default: ;
        endcase
    end

    logic redirect, exception, load_use_hazard;

    assign redirect  = ex_branch_taken | ex_jump_taken;
    assign exception = ex_illegal | ex_ecall | ex_ebreak;

    assign load_use_hazard =
           id_ex_mem_read
        && (id_ex_rd_addr != `REG_ZERO)
        && (   (id_uses_rs1 && (id_ex_rd_addr == id_rs1_addr))
            || (id_uses_rs2 && (id_ex_rd_addr == id_rs2_addr)));

    // flush: 全部下游流水寄存器清 NOP
    assign flush_if2id  = redirect | exception;
    assign flush_id2ex  = redirect | exception | load_use_hazard;
    assign flush_ex2mem = redirect | exception;
    assign flush_mem2wb = 1'b0;   // WB 阶段无需 flush

    // stall: 仅 PC 与 IF2ID
    assign stall_pc     = load_use_hazard;
    assign stall_if2id  = load_use_hazard;
    assign stall_id2ex  = 1'b0;

    // 重定向
    assign redirect_en  = redirect;
    assign redirect_pc  = ex_branch_taken ? ex_branch_target
                                          : ex_jump_target;
    assign exception_en = exception;

endmodule
