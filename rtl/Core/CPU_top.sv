`timescale 1ns / 1ps

`include "../sys_define.svh"

module CPU_top (
    input  wire        clk_sys,
    input  wire        rst_sys,

    // 指令 ROM
    input  wire [31:0] rom_instr_i,
    output wire [31:0] rom_instr_addr_o,

    // 数据 RAM
    output wire [31:0] ram_addr_o,
    output wire [31:0] ram_data_o,
    output wire [ 3:0] ram_be_o,
    output wire        ram_we_o,
    output wire        ram_re_o,
    input  wire [31:0] ram_data_i,

    // 中断
    input  wire [ 7:0] int_i,
    input  wire        hold_flag_i
);

    //==================================================================
    // 1. 流水线寄存器 / 中间信号声明
    //==================================================================

    // ---- IF ----
    wire [`DATA_BUS] if_pc;
    wire [`DATA_BUS] if_instr;

    // ---- IF2ID ----
    wire [`DATA_BUS] id_pc;
    wire [`DATA_BUS] id_instr;

    // ---- ID ----
    wire [`ADDR_BUS] id_rs1_addr, id_rs2_addr, id_rd_addr;
    wire             id_rd_we;
    wire [3:0]       id_alu_op;
    wire [1:0]       id_op1_sel, id_wb_sel, id_mem_size;
    wire [0:0]       id_op2_sel;
    wire [`DATA_BUS] id_imm, id_op1, id_op2;
    wire [`DATA_BUS] id_rs1_data, id_rs2_data;
    wire             id_mem_read, id_mem_write, id_mem_unsigned;
    wire             id_branch, id_jump, id_jump_reg;
    wire [2:0]       id_br_sel;
    wire             id_illegal, id_ecall, id_ebreak, id_fence;

    // ---- ID2EX ----
    wire [`DATA_BUS] id_ex_pc, id_ex_op1, id_ex_op2, id_ex_imm;
    wire [`ADDR_BUS] id_ex_rs1_addr, id_ex_rs2_addr, id_ex_rd_addr;
    wire             id_ex_rd_we;
    wire [3:0]       id_ex_alu_op;
    wire [1:0]       id_ex_op1_sel, id_ex_wb_sel, id_ex_mem_size;
    wire [0:0]       id_ex_op2_sel;
    wire             id_ex_mem_read, id_ex_mem_write, id_ex_mem_unsigned;
    wire             id_ex_branch, id_ex_jump, id_ex_jump_reg;
    wire [2:0]       id_ex_br_sel;
    wire             id_ex_illegal, id_ex_ecall, id_ex_ebreak, id_ex_fence;

    // ---- EX ----
    wire [`DATA_BUS] ex_alu_op1, ex_alu_op2, ex_alu_result;
    wire [`DATA_BUS] ex_br_op1, ex_br_op2;
    wire [`DATA_BUS] ex_jump_rs1;
    wire             ex_branch_taken, ex_jump_taken;
    wire [`DATA_BUS] ex_branch_target, ex_jump_target;
    wire [`DATA_BUS] ex_pc4;
    wire [`DATA_BUS] ex_rs2_data;

    // ---- EX2MEM ----
    wire [`DATA_BUS] mem_alu_result, mem_rs2_data, mem_pc, mem_pc4;
    wire [`ADDR_BUS] mem_rd_addr;
    wire             mem_rd_we;
    wire [1:0]       mem_wb_sel_from_ex, mem_size_from_ex;
    wire             mem_read_from_ex, mem_write_from_ex, mem_unsigned_from_ex;

    // ---- MEM ----
    wire [`DATA_BUS] mem_addr, mem_wdata, mem_rdata_ext;
    wire [3:0]       mem_be;
    wire             mem_req, mem_we, mem_align_err;

    // ---- MEM2WB ----
    wire [`DATA_BUS] wb_alu_result, wb_rdata, wb_pc4, wb_wdata;
    wire [`ADDR_BUS] wb_rd_addr;
    wire             wb_rd_we;
    wire [1:0]       wb_sel;

    // ---- Control ----
    wire        flush_if2id, flush_id2ex, flush_ex2mem, flush_mem2wb;
    wire        stall_pc, stall_if2id, stall_id2ex;
    wire        redirect_en, exception_en;
    wire [`DATA_BUS] redirect_pc;

    // ---- PC 重定向 ----
    // 说明：PC 的跳转/停顿实际由 PCReg 的 jmp_flag / stall 端口完成
    //       （见下方 u_PCReg 例化），此处不再保留冗余的 pc_load 逻辑。

    //==================================================================
    // 2. IF 阶段
    //==================================================================
    PCReg u_PCReg (
        .clk_sys  (clk_sys),
        .rst_sys  (rst_sys),
        .stall    (stall_pc | hold_flag_i),
        .jmp_flag (redirect_en),
        .jmp_addr (redirect_pc),
        .pc       (if_pc)
    );

    IF u_IF (
        .pc         (if_pc),
        .rom_data   (rom_instr_i),
        .rom_addr   (rom_instr_addr_o),
        .instr_addr (),
        .instr      (if_instr)
    );

    IF2ID u_IF2ID (
        .clk_sys      (clk_sys),
        .rst_sys      (rst_sys),
        .flush        (flush_if2id),
        .stall        (stall_if2id),
        // flush 时指令被清为 NOP，PC 仍锁存重定向目标，便于调试观察流水线
        .flush_pc     (redirect_en ? redirect_pc : if_pc),
        .instr_i      (if_instr),
        .instr_addr_i (if_pc),
        .instr_o      (id_instr),
        .instr_addr_o (id_pc)
    );

    //==================================================================
    // 3. ID 阶段
    //==================================================================
    Decoder u_Decoder (
        .instr        (id_instr),
        .rs1_addr     (id_rs1_addr),
        .rs2_addr     (id_rs2_addr),
        .rd_addr      (id_rd_addr),
        .rd_we        (id_rd_we),
        .alu_op       (id_alu_op),
        .op1_sel      (id_op1_sel),
        .op2_sel      (id_op2_sel),
        .imm          (id_imm),
        .wb_sel       (id_wb_sel),
        .mem_size     (id_mem_size),
        .mem_read     (id_mem_read),
        .mem_write    (id_mem_write),
        .mem_unsigned (id_mem_unsigned),
        .branch       (id_branch),
        .br_sel       (id_br_sel),
        .jump         (id_jump),
        .jump_reg     (id_jump_reg),
        .illegal      (id_illegal),
        .ecall        (id_ecall),
        .ebreak       (id_ebreak),
        .fence        (id_fence)
    );

    Regs u_Regs (
        .clk_sys  (clk_sys),
        .rst_sys  (rst_sys),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs1_data (id_rs1_data),
        .rs2_data (id_rs2_data),
        .rd_addr  (wb_rd_addr),
        .rd_data  (wb_wdata),
        .we_flag  (wb_rd_we)
    );

    ID u_ID (
        .op1_sel    (id_op1_sel),
        .op2_sel    (id_op2_sel),
        .imm        (id_imm),
        .rs1_data   (id_rs1_data),
        .rs2_data   (id_rs2_data),
        .instr_addr (id_pc),
        .op1        (id_op1),
        .op2        (id_op2)
    );

    ID2EX u_ID2EX (
        .clk_sys         (clk_sys),
        .rst_sys         (rst_sys),
        .flush           (flush_id2ex),
        .stall           (stall_id2ex),
        .id_pc           (id_pc),
        .id_rs1_addr     (id_rs1_addr),
        .id_rs2_addr     (id_rs2_addr),
        .id_rd_addr      (id_rd_addr),
        .id_rd_we        (id_rd_we),
        .id_alu_op       (id_alu_op),
        .id_op1_sel      (id_op1_sel),
        .id_op2_sel      (id_op2_sel),
        .id_op1          (id_op1),
        .id_op2          (id_op2),
        .id_imm          (id_imm),
        .id_wb_sel       (id_wb_sel),
        .id_mem_size     (id_mem_size),
        .id_mem_read     (id_mem_read),
        .id_mem_write    (id_mem_write),
        .id_mem_unsigned (id_mem_unsigned),
        .id_branch       (id_branch),
        .id_br_sel       (id_br_sel),
        .id_jump         (id_jump),
        .id_jump_reg     (id_jump_reg),
        .id_illegal      (id_illegal),
        .id_ecall        (id_ecall),
        .id_ebreak       (id_ebreak),
        .id_fence        (id_fence),

        .id_ex_pc           (id_ex_pc),
        .id_ex_rs1_addr     (id_ex_rs1_addr),
        .id_ex_rs2_addr     (id_ex_rs2_addr),
        .id_ex_rd_addr      (id_ex_rd_addr),
        .id_ex_rd_we        (id_ex_rd_we),
        .id_ex_alu_op       (id_ex_alu_op),
        .id_ex_op1_sel      (id_ex_op1_sel),
        .id_ex_op2_sel      (id_ex_op2_sel),
        .id_ex_op1          (id_ex_op1),
        .id_ex_op2          (id_ex_op2),
        .id_ex_imm          (id_ex_imm),
        .id_ex_wb_sel       (id_ex_wb_sel),
        .id_ex_mem_size     (id_ex_mem_size),
        .id_ex_mem_read     (id_ex_mem_read),
        .id_ex_mem_write    (id_ex_mem_write),
        .id_ex_mem_unsigned (id_ex_mem_unsigned),
        .id_ex_branch       (id_ex_branch),
        .id_ex_br_sel       (id_ex_br_sel),
        .id_ex_jump         (id_ex_jump),
        .id_ex_jump_reg     (id_ex_jump_reg),
        .id_ex_illegal      (id_ex_illegal),
        .id_ex_ecall        (id_ex_ecall),
        .id_ex_ebreak       (id_ex_ebreak),
        .id_ex_fence        (id_ex_fence)
    );

    //==================================================================
    // 4. EX 阶段
    //==================================================================
    EX u_EX (
        .id_ex_op1        (id_ex_op1),
        .id_ex_op2        (id_ex_op2),
        .id_ex_rs1_addr   (id_ex_rs1_addr),
        .id_ex_rs2_addr   (id_ex_rs2_addr),
        .id_ex_op1_sel    (id_ex_op1_sel),
        .id_ex_op2_sel    (id_ex_op2_sel),

        // EX/MEM 前递源
        .ex_mem_rd_addr   (mem_rd_addr),
        .ex_mem_alu_result(mem_alu_result),
        .ex_mem_rd_we     (mem_rd_we),
        .ex_mem_mem_read  (mem_read_from_ex),    // 关键: load 时禁止 EX/MEM 前递

        // MEM/WB 前递源
        .mem_wb_rd_addr   (wb_rd_addr),
        .mem_wb_wdata     (wb_wdata),
        .mem_wb_rd_we     (wb_rd_we),

        .alu_op1   (ex_alu_op1),
        .alu_op2   (ex_alu_op2),
        .br_op1    (ex_br_op1),
        .br_op2    (ex_br_op2),
        .jump_rs1  (ex_jump_rs1)
    );

    ALU u_ALU (
        .op1    (ex_alu_op1),
        .op2    (ex_alu_op2),
        .alu_op (id_ex_alu_op),
        .result (ex_alu_result)
    );

    Branch u_Branch (
        .op1           (ex_br_op1),
        .op2           (ex_br_op2),
        .pc            (id_ex_pc),
        .imm           (id_ex_imm),
        .branch        (id_ex_branch),
        .br_sel        (id_ex_br_sel),
        .branch_taken  (ex_branch_taken),
        .branch_target (ex_branch_target)
    );

    Jump u_Jump (
        .pc          (id_ex_pc),
        .rs1         (ex_jump_rs1),
        .imm         (id_ex_imm),
        .jump        (id_ex_jump),
        .jump_reg    (id_ex_jump_reg),
        .jump_taken  (ex_jump_taken),
        .jump_target (ex_jump_target)
    );

    // store 数据 = 前递后的 rs2 (从 Branch 端口借用，语义上就是 rs2)
    assign ex_pc4      = id_ex_pc + 32'd4;
    assign ex_rs2_data = ex_br_op2;

    EX2MEM u_EX2MEM (
        .clk_sys         (clk_sys),
        .rst_sys         (rst_sys),
        .flush           (flush_ex2mem),
        .stall           (1'b0),

        .ex_alu_result   (ex_alu_result),
        .ex_rs2_data     (ex_rs2_data),
        .ex_pc           (id_ex_pc),
        .ex_pc4          (ex_pc4),
        .ex_rd_addr      (id_ex_rd_addr),
        .ex_rd_we        (id_ex_rd_we),
        .ex_wb_sel       (id_ex_wb_sel),
        .ex_mem_size     (id_ex_mem_size),
        .ex_mem_read     (id_ex_mem_read),
        .ex_mem_write    (id_ex_mem_write),
        .ex_mem_unsigned (id_ex_mem_unsigned),

        .mem_alu_result  (mem_alu_result),
        .mem_rs2_data    (mem_rs2_data),
        .mem_pc          (mem_pc),
        .mem_pc4         (mem_pc4),
        .mem_rd_addr     (mem_rd_addr),
        .mem_rd_we       (mem_rd_we),
        .mem_wb_sel      (mem_wb_sel_from_ex),
        .mem_size        (mem_size_from_ex),
        .mem_read        (mem_read_from_ex),
        .mem_write       (mem_write_from_ex),
        .mem_unsigned    (mem_unsigned_from_ex)
    );

    //==================================================================
    // 5. MEM 阶段
    //==================================================================
    MEM u_MEM (
        .mem_alu_result (mem_alu_result),
        .mem_rs2_data   (mem_rs2_data),
        .mem_size       (mem_size_from_ex),
        .mem_read       (mem_read_from_ex),
        .mem_write      (mem_write_from_ex),
        .mem_unsigned   (mem_unsigned_from_ex),

        .mem_rdata      (ram_data_i),

        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_be         (mem_be),
        .mem_req        (mem_req),
        .mem_we         (mem_we),

        .mem_rdata_ext  (mem_rdata_ext),
        .mem_align_err  (mem_align_err)
    );

    assign ram_addr_o = mem_addr;
    assign ram_data_o = mem_wdata;
    assign ram_be_o   = mem_be;
    assign ram_we_o   = mem_we;
    assign ram_re_o   = mem_req & ~mem_we;

    MEM2WB u_MEM2WB (
        .clk_sys        (clk_sys),
        .rst_sys        (rst_sys),
        .flush          (flush_mem2wb),
        .stall          (1'b0),

        .mem_alu_result (mem_alu_result),
        .mem_rdata      (mem_rdata_ext),   // 注意: 传扩展后的数据
        .mem_pc4        (mem_pc4),
        .mem_rd_addr    (mem_rd_addr),
        .mem_rd_we      (mem_rd_we),
        .mem_wb_sel     (mem_wb_sel_from_ex),

        .wb_alu_result  (wb_alu_result),
        .wb_rdata       (wb_rdata),
        .wb_pc4         (wb_pc4),
        .wb_rd_addr     (wb_rd_addr),
        .wb_rd_we       (wb_rd_we),
        .wb_sel         (wb_sel)
    );

    //==================================================================
    // 6. WB 阶段
    //==================================================================
    WB u_WB (
        .wb_alu_result (wb_alu_result),
        .wb_rdata      (wb_rdata),
        .wb_pc4        (wb_pc4),
        .wb_sel        (wb_sel),
        .wb_rd_addr    (wb_rd_addr),
        .wb_rd_we      (wb_rd_we),
        .rd_data       (wb_wdata),
        .rd_addr       (),                 // 直接由 Regs 消费 wb_rd_addr
        .rd_we         ()
    );

    //==================================================================
    // 7. Control 单元
    //==================================================================
    Control u_Control (
        .clk_sys          (clk_sys),
        .rst_sys          (rst_sys),

        .ex_branch_taken  (ex_branch_taken),
        .ex_jump_taken    (ex_jump_taken),
        .ex_branch_target (ex_branch_target),
        .ex_jump_target   (ex_jump_target),
        .ex_illegal       (id_ex_illegal),
        .ex_ecall         (id_ex_ecall),
        .ex_ebreak        (id_ex_ebreak),

        .id_ex_rd_addr    (id_ex_rd_addr),
        .id_ex_rd_we      (id_ex_rd_we),
        .id_ex_mem_read   (id_ex_mem_read),

        .id_instr         (id_instr),
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),

        .flush_if2id      (flush_if2id),
        .flush_id2ex      (flush_id2ex),
        .flush_ex2mem     (flush_ex2mem),
        .flush_mem2wb     (flush_mem2wb),

        .stall_pc         (stall_pc),
        .stall_if2id      (stall_if2id),
        .stall_id2ex      (stall_id2ex),

        .redirect_en      (redirect_en),
        .redirect_pc      (redirect_pc),
        .exception_en     (exception_en)
    );

endmodule
