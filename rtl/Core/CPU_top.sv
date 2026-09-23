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
    input  wire        hold_flag_i,

    // 取指总线授权（来自 RIB）：用于在数据访问占用总线的周期冻结 IF
    input  wire        if_grant_i,
    input  wire        bus_grant_valid_i
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
    wire             id_csr_en, id_csr_imm, id_csr_we, id_mret;
    wire [2:0]       id_csr_op;
    wire [11:0]      id_csr_addr;
    wire [4:0]       id_csr_uimm;

    // ---- ID2EX ----
    wire [`DATA_BUS] id_ex_pc, id_ex_op1, id_ex_op2, id_ex_rs2_data, id_ex_imm;
    wire [`ADDR_BUS] id_ex_rs1_addr, id_ex_rs2_addr, id_ex_rd_addr;
    wire             id_ex_rd_we;
    wire [3:0]       id_ex_alu_op;
    wire [1:0]       id_ex_op1_sel, id_ex_wb_sel, id_ex_mem_size;
    wire [0:0]       id_ex_op2_sel;
    wire             id_ex_mem_read, id_ex_mem_write, id_ex_mem_unsigned;
    wire             id_ex_branch, id_ex_jump, id_ex_jump_reg;
    wire [2:0]       id_ex_br_sel;
    wire             id_ex_illegal, id_ex_ecall, id_ex_ebreak, id_ex_fence;
    wire             id_ex_csr_en, id_ex_csr_imm, id_ex_csr_we, id_ex_mret;
    wire [2:0]       id_ex_csr_op;
    wire [11:0]      id_ex_csr_addr;
    wire [4:0]       id_ex_csr_uimm;
    wire             id_ex_valid;

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
    wire             mem_csr_we;
    wire [11:0]      mem_csr_addr;
    wire [31:0]      mem_csr_wdata, mem_csr_rdata;

    // ---- MEM ----
    wire [`DATA_BUS] mem_rdata_ext_c;    // MEM 级组合提取出的 load 数据
    // 访存地址/数据/字节使能由 EX 级的 MEM_req 产生，见下方第 5 节

    // ---- MEM2WB ----
    wire [`DATA_BUS] wb_alu_result, wb_rdata, wb_pc4, wb_wdata, wb_csr_rdata;
    wire [`ADDR_BUS] wb_rd_addr;
    wire             wb_rd_we;
    wire [1:0]       wb_sel;

    // ---- Control ----
    wire        flush_if2id, flush_id2ex, flush_ex2mem, flush_mem2wb;
    wire        stall_pc, stall_if2id, stall_id2ex;
    wire        redirect_en, exception_en, trap_en;
    wire        mret_en;
    wire [`DATA_BUS] redirect_pc, trap_cause, trap_pc;

    // ---- PC 重定向 ----
    // 说明：PC 的跳转/停顿实际由 PCReg 的 jmp_flag / stall 端口完成
    //       （见下方 u_PCReg 例化），此处不再保留冗余的 pc_load 逻辑。

    // ---- CSR / 陷阱 ----
    wire [31:0] csr_rdata, csr_src;
    logic [31:0] csr_new;
    wire        csr_valid, csr_writable, csr_wr;
    wire        ex_load_misaligned, ex_store_misaligned, ex_csr_illegal;
    wire        irq_pending, interrupt_req;
    wire [31:0] mtvec, mepc_csr, mcause_csr, mstatus_csr, mie_csr;
    wire [15:0] _unused_csr_dbg;

    assign mret_en = id_ex_mret & id_ex_valid;

    // 取指侧与 ROM 1 拍读延迟的配合（重要）
    //
    //  ROM 是寄存输出：T 拍给出地址 A(T)，T+1 拍 douta = I(A(T))。
    //  IF2ID 在 T+1 拍沿锁存到的是「T-1 拍给出的地址」对应的指令，所以：
    //      · instr_addr_i 必须用延后一拍的 PC（if_pc_d1），否则锁存的
    //        (指令, 地址) 会差 4 字节，EX 算出的一切分支/跳转目标都偏移；
    //      · 想让 IF2ID 锁存到地址 A，就要在 A 出现在 if_pc 的那一拍
    //        （而不是下一拍）准备好 —— 由此得到下面两条控制规则：
    //          注入 NOP ：丢弃「本拍 ROM 输出」→ 下一拍沿写入 NOP；
    //          冻结 PC  ：让同一地址连出两拍 → 下一拍沿会再收到一次同样的
    //                     指令（配合 IF2ID 保持，就得到一次「停顿」）。
    //
    //  取指与数据访问共用 RIB，数据口（m0）优先级高于取指口（m1）。
    //  数据访问的那一拍，ROM 的地址输入被换成数据地址并被寄存，于是：
    //      T   拍：本应取的地址没送进 ROM → 冻结 PC，让 T+1 拍重发同地址
    //      T+1 拍：ROM 输出的是数据地址对应的内容（对取指无意义）
    //              → 在 T+1 拍注入 NOP，把它在 T+2 拍沿丢弃
    //  注意「冻结比注入早一拍」；两者同拍会把指令流弄乱。
    wire if_bus_stall = bus_grant_valid_i & ~if_grant_i;   // 本拍取指口被抢

    logic if_bus_stall_d1;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) if_bus_stall_d1 <= 1'b0;
        else                      if_bus_stall_d1 <= if_bus_stall;
    end

    // ---- 重定向后的两个气泡 ----
    //   分支/跳转在 EX 级解析后 PC 当拍跳到目标；ROM 又要再等一拍才给出目标
    //   地址的指令，因此「重定向当拍」与「重定向后一拍」各注入一个 NOP，
    //   把错误路径上已进入取指流水线的一条指令和一条在途指令丢掉。
    //   ★ 这里不能冻结 PC：地址连出两拍会让目标指令被锁进 IF2ID 两次
    //     （现象为分支目标指令重复执行，例如循环变量被多加一次）。
    logic redirect_d1;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) redirect_d1 <= 1'b0;
        else                      redirect_d1 <= redirect_en;
    end
    wire flush_bubble = redirect_d1;

    // 取指地址配对：见上面说明，必须用延后一拍的 PC
    logic [`DATA_BUS] if_pc_d1;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) if_pc_d1 <= `PC_RESET;
        else                      if_pc_d1 <= if_pc;
    end

    // PC 停顿：数据访问抢占总线的当拍冻结 PC（下一拍重发同一地址）；
    // load-use / RAW 都不需要停顿（全前递，见 Control.sv）
    wire if_stall = stall_pc | hold_flag_i | if_bus_stall;
    wire id_stall = stall_if2id;

    // ---- 复位释放后的第一个取指槽 ----
    //   复位期间 PC 一直停在复位向量上，ROM 会反复寄存该地址，于是复位
    //   释放后头两拍 ROM 输出的是同一条指令，IF2ID 会把首条指令锁两次
    //   （表现为复位后第一条指令执行两遍）。这里在复位释放后的第一拍
    //   注入一个 NOP，把重复的那一拍吃掉，取指流从复位向量开始连续。
    logic rst_sys_d1;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) rst_sys_d1 <= `RESET_EN;
        else                      rst_sys_d1 <= `RESET_DIS;
    end
    wire fetch_warmup = (rst_sys != `RESET_EN) && (rst_sys_d1 == `RESET_EN);

    // 气泡注入：总线抢占用「延后一拍」，重定向用「当拍 + 延后一拍」
    wire [`DATA_BUS] if_instr_gated =
        (if_bus_stall_d1 | flush_bubble | fetch_warmup) ? `INST_NOP : if_instr;

    //==================================================================
    // 2. IF 阶段
    //==================================================================
    PCReg u_PCReg (
        .clk_sys  (clk_sys),
        .rst_sys  (rst_sys),
        .stall    (if_stall),
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
        .stall        (id_stall),
        // flush 时指令被清为 NOP，PC 仍锁存重定向目标，便于调试观察流水线
        .flush_pc     (redirect_en ? redirect_pc : if_pc),
        .instr_i      (if_instr_gated),
        .instr_addr_i (if_pc_d1),
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
        .fence        (id_fence),
        .csr_en       (id_csr_en),
        .csr_op       (id_csr_op),
        .csr_addr     (id_csr_addr),
        .csr_imm      (id_csr_imm),
        .csr_uimm     (id_csr_uimm),
        .csr_we       (id_csr_we),
        .mret         (id_mret)
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
        .id_rs2_data     (id_rs2_data),     // 原始 rs2（store 数据源）
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
        .id_csr_en       (id_csr_en),
        .id_csr_op       (id_csr_op),
        .id_csr_addr     (id_csr_addr),
        .id_csr_imm      (id_csr_imm),
        .id_csr_uimm     (id_csr_uimm),
        .id_csr_we       (id_csr_we),
        .id_mret         (id_mret),

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
        .id_ex_rs2_data     (id_ex_rs2_data),
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
        .id_ex_fence        (id_ex_fence),
        .id_ex_csr_en       (id_ex_csr_en),
        .id_ex_csr_op       (id_ex_csr_op),
        .id_ex_csr_addr     (id_ex_csr_addr),
        .id_ex_csr_imm      (id_ex_csr_imm),
        .id_ex_csr_uimm     (id_ex_csr_uimm),
        .id_ex_csr_we       (id_ex_csr_we),
        .id_ex_mret         (id_ex_mret),
        .id_ex_valid        (id_ex_valid)
    );

    //==================================================================
    // 4. EX 阶段
    //==================================================================
    EX u_EX (
        .id_ex_op1        (id_ex_op1),
        .id_ex_op2        (id_ex_op2),
        .id_ex_rs2_data   (id_ex_rs2_data),   // store 数据用它，不用 op2
        .id_ex_rs1_addr   (id_ex_rs1_addr),
        .id_ex_rs2_addr   (id_ex_rs2_addr),
        .id_ex_op1_sel    (id_ex_op1_sel),
        .id_ex_op2_sel    (id_ex_op2_sel),

        // EX/MEM 前递源 —— 用「当前 MEM 级」的原值。
        //   · 非 load：前递 ALU 结果；
        //   · load   ：前递 MEM 级组合提取出的 load 数据（ex_mem_load_data）。
        //     访存地址在 EX 级发起，BRAM 的 1 拍延迟正好落在 MEM 级，所以
        //     依赖指令在 EX 级的那一拍，load 正在 MEM 级且数据已可用 ——
        //     这正是本设计不需要 load-use 停顿的原因。
        .ex_mem_rd_addr   (mem_rd_addr),
        .ex_mem_alu_result(mem_alu_result),
        .ex_mem_rd_we     (mem_rd_we),
        .ex_mem_mem_read  (mem_read_from_ex),    // MEM 级是否为 load
        .ex_mem_load_data (mem_rdata_ext_c),     // load 数据（MEM 级组合提取）
        .ex_mem_is_csr    (mem_wb_sel_from_ex == `WB_CSR),  // MEM 级是否为 CSR 指令
        .ex_mem_csr_data  (mem_csr_rdata),       // CSR 指令读出的旧值

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
        .ex_csr_we       (csr_wr),
        .ex_csr_addr     (id_ex_csr_addr),
        .ex_csr_wdata    (csr_new),
        .ex_csr_rdata    (csr_rdata),

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
        .mem_unsigned    (mem_unsigned_from_ex),
        .mem_csr_we      (mem_csr_we),
        .mem_csr_addr    (mem_csr_addr),
        .mem_csr_wdata   (mem_csr_wdata),
        .mem_csr_rdata   (mem_csr_rdata)
    );

    //==================================================================
    // 5. MEM 阶段
    //
    // 访存读数据对齐（ROM/RAM 均为 IP 寄存输出，读延迟 1 拍）
    //   IP 语义：T 拍给 addr，T+1 拍 douta 才是该 addr 的数据。
    //
    //   旧做法在 MEM 级才给地址，于是提取用的 mem_alu_result[1:0] 与
    //   ram_data_i 永远差一拍（数据回来时地址已前进），lw/lbu/lhu 读回错。
    //
    //   现做法：**地址连同 we/be/wdata 提前到 EX 级发起**（MEM_req），
    //   BRAM 的 1 拍延迟正好落在 MEM 级 ——
    //     EX 拍 ：mem_addr = ALU 结果（BRAM 在本拍沿寄存该地址）
    //     MEM 拍：ram_data_i = mem[mem_alu_result]，而 mem_alu_result 就是
    //             EX 拍那个 ALU 结果的流水寄存器值 → 通道选择天然对齐，
    //             MEM2WB 与写回控制同拍锁存，无需任何额外延迟或停顿。
    //   同时 MEM 级组合提取出的 mem_rdata_ext 也直接前递给 EX 级
    //   （ex_mem_load_data），load-use 因此不需要停顿。
    //==================================================================

    // ---- MEM 级：读数据提取 / 扩展 / 对齐检查 ----
    MEM_load u_MEM_load (
        .mem_alu_result (mem_alu_result),
        .mem_size       (mem_size_from_ex),
        .mem_read       (mem_read_from_ex),
        .mem_unsigned   (mem_unsigned_from_ex),
        .mem_rdata      (ram_data_i),        // 1 拍前给出的地址的数据
        .mem_rdata_ext  (mem_rdata_ext_c)
    );

    // ---- EX 级：访存请求（地址 / 写数据 / 字节使能）----
    //   放在 EX 级是本设计的关键（见 MEM_req 文件头）：
    //   地址提前一拍，BRAM 的读延迟才落在 MEM 级。
    logic [`DATA_BUS] ex_mem_addr, ex_mem_wdata;
    logic [      3:0] ex_mem_be;
    logic             ex_mem_req, ex_mem_we, ex_mem_align_err;

    MEM_req u_MEM_req (
        .mem_alu_result (ex_alu_result),     // EX 级 ALU 结果 = 访存地址
        .mem_rs2_data   (ex_rs2_data),       // 前递后的 rs2
        .mem_size       (id_ex_mem_size),
        .mem_read       (id_ex_mem_read),
        .mem_write      (id_ex_mem_write),

        .mem_addr       (ex_mem_addr),
        .mem_wdata      (ex_mem_wdata),
        .mem_be         (ex_mem_be),
        .mem_req        (ex_mem_req),
        .mem_we         (ex_mem_we),
        .mem_align_err  (ex_mem_align_err)
    );

    //------------------------------------------------------------------
    // CSR：EX 级组合读 + 展开成最终新值，MEM 级提交（见 CSR.sv 说明）
    //   · 非立即数形式的源操作数走前递后的 rs1（ex_br_op1 就是 rs1_fwd）
    //   · 立即数形式用 rs1 字段零扩展成 5 bit 无符号数
    //------------------------------------------------------------------
    assign csr_src = id_ex_csr_imm ? {27'b0, id_ex_csr_uimm} : ex_br_op1;

    always_comb begin
        case (id_ex_csr_op)
            `CSR_OP_RW, `CSR_OP_RWI: csr_new = csr_src;
            `CSR_OP_RS, `CSR_OP_RSI: csr_new = csr_rdata |  csr_src;
            default:                 csr_new = csr_rdata & ~csr_src;   // RC / RCI
        endcase
    end

    assign csr_wr = id_ex_csr_we & id_ex_valid;

    // 非法 CSR 访问：地址未实现，或写只读寄存器（在 EX 级判定 → mcause = 2）
    assign ex_csr_illegal = id_ex_csr_en & id_ex_valid &
                            (~csr_valid | (csr_wr & ~csr_writable));

    // 地址非对齐（MEM_req 在 EX 级拦下并门控访存请求）
    assign ex_load_misaligned  = id_ex_mem_read  & ex_mem_align_err;
    assign ex_store_misaligned = id_ex_mem_write & ex_mem_align_err;

    // 中断受理条件：EX 级是真实指令、且不是访存指令
    //   （访存请求已在 EX 级发出，打断它会让「指令部分执行」；推迟一拍即可）
    assign interrupt_req = irq_pending & id_ex_valid &
                           ~(id_ex_mem_read | id_ex_mem_write);

    CSR u_CSR (
        .clk_sys      (clk_sys),
        .rst_sys      (rst_sys),

        .csr_addr     (id_ex_csr_addr),
        .csr_rdata    (csr_rdata),
        .csr_valid    (csr_valid),
        .csr_writable (csr_writable),

        .csr_we       (mem_csr_we),
        .csr_addr_w   (mem_csr_addr),
        .csr_wdata    (mem_csr_wdata),

        .trap_en      (trap_en),
        .trap_cause   (trap_cause),
        .trap_pc      (trap_pc),
        .mret_en      (mret_en),
        .trap_vector  (mtvec),

        .int_i        (int_i),
        .mip_mtip     (),
        .irq_pending  (irq_pending),

        .mstatus_o    (mstatus_csr),
        .mepc_o       (mepc_csr),
        .mcause_o     (mcause_csr),
        .mie_o        (mie_csr)
    );

    // 写请求只占 EX 一拍（在本拍沿落盘），读请求同样只占一拍，
    // 数据由 RIB 在下一拍（MEM 级）按「上一拍片选」回送。
    assign ram_addr_o = ex_mem_addr;
    assign ram_data_o = ex_mem_wdata;
    assign ram_be_o   = ex_mem_be;
    assign ram_we_o   = ex_mem_we;
    assign ram_re_o   = ex_mem_req & ~ex_mem_we;

    MEM2WB u_MEM2WB (
        .clk_sys        (clk_sys),
        .rst_sys        (rst_sys),
        .flush          (flush_mem2wb),
        .stall          (1'b0),

        .mem_alu_result (mem_alu_result),
        .mem_rdata      (mem_rdata_ext_c),   // 提取+扩展结果，与写回控制同拍
        .mem_pc4        (mem_pc4),
        .mem_rd_addr    (mem_rd_addr),
        .mem_rd_we      (mem_rd_we),
        .mem_wb_sel     (mem_wb_sel_from_ex),
        .mem_csr_rdata  (mem_csr_rdata),

        .wb_alu_result  (wb_alu_result),
        .wb_rdata       (wb_rdata),
        .wb_pc4         (wb_pc4),
        .wb_rd_addr     (wb_rd_addr),
        .wb_rd_we       (wb_rd_we),
        .wb_sel         (wb_sel),
        .wb_csr_rdata   (wb_csr_rdata)
    );

    //==================================================================
    // 6. WB 阶段
    //==================================================================
    WB u_WB (
        .wb_alu_result (wb_alu_result),
        .wb_rdata      (wb_rdata),
        .wb_pc4        (wb_pc4),
        .wb_csr_rdata  (wb_csr_rdata),
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

        .ex_pc            (id_ex_pc),
        .ex_branch_taken  (ex_branch_taken),
        .ex_jump_taken    (ex_jump_taken),
        .ex_branch_target (ex_branch_target),
        .ex_jump_target   (ex_jump_target),
        .ex_illegal       (id_ex_illegal),
        .ex_ecall         (id_ex_ecall),
        .ex_ebreak        (id_ex_ebreak),
        .ex_load_misaligned  (ex_load_misaligned),
        .ex_store_misaligned (ex_store_misaligned),
        .ex_csr_illegal      (ex_csr_illegal),
        .interrupt_req    (interrupt_req),
        .mtvec            (mtvec),
        .mret_en          (mret_en),
        .mepc             (mepc_csr),

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
        .exception_en     (exception_en),
        .trap_en          (trap_en),
        .trap_cause       (trap_cause),
        .trap_pc          (trap_pc)
    );

endmodule
