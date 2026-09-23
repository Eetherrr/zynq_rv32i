`timescale 1ns / 1ps

`include "../../sys_define.svh"

//=====================================================================
// CSR — 机器模式控制状态寄存器 + 陷阱入口（RV32I + Zicsr 最小集）
//
//   实现的 CSR（其余地址访问 → 非法指令）：
//     0x300 mstatus   bit3 MIE / bit7 MPIE / MPP(=3, M 模式)
//     0x301 misa      只读：MXL=1(32bit) + I 扩展 = 0x4000_0100
//     0x304 mie       bit7 MTIE
//     0x305 mtvec     direct 模式（写入时 mode 强制 0）
//     0x340 mscratch
//     0x341 mepc      写入时低 2 位强制 0（IALIGN=32）
//     0x342 mcause
//     0x343 mtval     只读 0（本核不提供出错附加信息）
//     0x344 mip       只读：bit7 MTIP（来自定时器中断输入）
//
//   时序约定（与流水线配合）
//     · 读：EX 级组合读出（csr_rdata 直接进 ALU 旁路，随指令带到 WB）
//     · 写：由 CPU_top 在 EX 级把「最终新值」算好（RW/RS/RC 已展开），
//           经 EX2MEM 带到 MEM 级才提交 —— 这样陷阱是精确的：
//           若该 CSR 指令在 EX 级被中断/异常冲刷，写就不会发生。
//     · 陷阱入口 / MRET 在 EX 级生效，优先级高于同拍的 CSR 写（它们是
//       更晚发生的架构事件），低于同拍 CSR 写的是「更老的指令」。
//
//   中断：irq_pending = mip.MTIP & mie.MTIE & mstatus.MIE
//         交给 CPU_top 在「EX 级是真实指令且不是访存指令」时才受理。
//=====================================================================
module CSR (
    input  wire              clk_sys,
    input  wire              rst_sys,

    // ---- 读端口（EX 级组合读）----
    input  wire [11:0]       csr_addr,
    output logic [31:0]      csr_rdata,
    output logic             csr_valid,      // 地址已实现
    output logic             csr_writable,   // 该地址可写（misa/mtval/mip 为只读）

    // ---- 写端口（MEM 级提交）----
    input  wire              csr_we,         // 该指令写 CSR（已按 rs1/uimm=0 规则门控）
    input  wire [11:0]       csr_addr_w,
    input  wire [31:0]       csr_wdata,      // 已展开成最终要写入的值

    // ---- 陷阱（EX 级）----
    input  wire              trap_en,
    input  wire [31:0]       trap_cause,
    input  wire [31:0]       trap_pc,
    input  wire              mret_en,
    output logic [31:0]      trap_vector,    // mtvec

    // ---- 中断 ----
    input  wire [7:0]        int_i,          // bit0 = 定时器中断（TIMER.irq_o）
    output logic             mip_mtip,
    output logic             irq_pending,

    // ---- 观测（调试 / 测试平台）----
    output logic [31:0]      mstatus_o,
    output logic [31:0]      mepc_o,
    output logic [31:0]      mcause_o,
    output logic [31:0]      mie_o
);

    localparam logic [31:0] MISA_VALUE = 32'h4000_0100;   // MXL=1, I

    logic [31:0] mstatus_q, mie_q, mtvec_q, mscratch_q, mepc_q, mcause_q;

    //---- 中断挂起 ----
    assign mip_mtip    = int_i[0];          // 定时器 → MTIP
    assign irq_pending = mip_mtip & mie_q[`MIE_MTIE] & mstatus_q[`MSTATUS_MIE];

    // 陷阱向量见下方（需要用到写端口的译码结果，故放在声明之后）

    //---- 地址译码 ----
    //   read 侧：给 CPU 判断「非法 CSR 访问」
    //   write 侧：由写端口的地址独立判定（读地址与写地址来自不同流水级，
    //            写提交时读端口可能已指向别的 CSR）
    function automatic logic is_impl(input logic [11:0] a);
        is_impl = (a == `CSR_MSTATUS) || (a == `CSR_MISA) || (a == `CSR_MIE)
               || (a == `CSR_MTVEC)   || (a == `CSR_MSCRATCH)
               || (a == `CSR_MEPC)    || (a == `CSR_MCAUSE)
               || (a == `CSR_MTVAL)   || (a == `CSR_MIP);
    endfunction

    function automatic logic is_writable(input logic [11:0] a);
        is_writable = is_impl(a) && (a != `CSR_MISA)
                                 && (a != `CSR_MTVAL)
                                 && (a != `CSR_MIP);
    endfunction

    logic csr_writable_w;      // 写端口地址是否可写

    always_comb begin
        csr_valid      = is_impl(csr_addr);
        csr_writable   = is_writable(csr_addr);
        csr_writable_w = is_writable(csr_addr_w);
    end

    // 陷阱向量：本拍若有更老的指令正在提交 mtvec 的写，前递新值
    //   （否则「csrw mtvec, x」的下一条指令就陷入时，会跳到旧的向量上）
    assign trap_vector = (csr_we && csr_writable_w && (csr_addr_w == `CSR_MTVEC))
                       ? {csr_wdata[31:2], 2'b00} : mtvec_q;

    //---- 读（单个 always_comb：寄存器值 + 同拍写前递）----
    always_comb begin
        case (csr_addr)
            `CSR_MSTATUS:  csr_rdata = mstatus_q;
            `CSR_MISA:     csr_rdata = MISA_VALUE;
            `CSR_MIE:      csr_rdata = mie_q;
            `CSR_MTVEC:    csr_rdata = mtvec_q;
            `CSR_MSCRATCH: csr_rdata = mscratch_q;
            `CSR_MEPC:     csr_rdata = mepc_q;
            `CSR_MCAUSE:   csr_rdata = mcause_q;
            `CSR_MTVAL:    csr_rdata = 32'b0;
            `CSR_MIP:      csr_rdata = {24'b0, mip_mtip, 7'b0};
            default:       csr_rdata = 32'b0;
        endcase
        // CSR 写要到 MEM 级才提交，而读在 EX 级组合进行；连续两条 CSR 指令
        // 操作同一寄存器时，后一条必须看到前一条的结果 —— 同拍前递。
        if (csr_we && (csr_addr_w == csr_addr))
            csr_rdata = csr_wdata;
    end

    //---- 写 ----
    //   mstatus 只实现 MIE(3) / MPIE(7) / MPP(12:11)，用移位拼装不易错位
    function automatic logic [31:0] mstat(input logic mie, input logic mpie);
        mstat = (32'd3 << 11)                                  // MPP = M 模式
              | ({31'b0, mpie} << `MSTATUS_MPIE)
              | ({31'b0, mie}  << `MSTATUS_MIE);
    endfunction

    wire [31:0] mstatus_w = mstat(csr_wdata[`MSTATUS_MIE],
                                  csr_wdata[`MSTATUS_MPIE]);

    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            mstatus_q  <= 32'b0;
            mie_q      <= 32'b0;
            mtvec_q    <= 32'b0;
            mscratch_q <= 32'b0;
            mepc_q     <= 32'b0;
            mcause_q   <= 32'b0;
        end
        else begin
            //----------------------------------------------------------
            // 同一拍可能同时发生：
            //   (a) 一条更老的 CSR 指令在 MEM 级提交它的写
            //   (b) EX 级的陷阱入口 / MRET（更晚发生的架构事件）
            // 顺序必须是「先 (a) 后 (b)」：
            //   · 陷阱紧跟在 `csrw mtvec, x` 之后就跳转时，mtvec 必须已经写好，
            //     否则会跳到旧的（复位值 0）向量上；
            //   · 若两者写同一个 CSR（如 csrw mstatus + 陷阱），后写的陷阱覆盖，
            //     这也符合「陷阱更晚发生」的语义。
            //----------------------------------------------------------
            if (csr_we && csr_writable_w) begin
                case (csr_addr_w)
                    `CSR_MSTATUS:  mstatus_q  <= mstatus_w;
                    `CSR_MIE:      mie_q      <= {24'b0, csr_wdata[`MIE_MTIE], 7'b0};
                    `CSR_MTVEC:    mtvec_q    <= {csr_wdata[31:2], 2'b00};  // direct
                    `CSR_MSCRATCH: mscratch_q <= csr_wdata;
                    `CSR_MEPC:     mepc_q     <= {csr_wdata[31:2], 2'b00};
                    `CSR_MCAUSE:   mcause_q   <= csr_wdata;
                    default:       ;                       // misa/mtval/mip：只读
                endcase
            end

            if (trap_en) begin
                // 陷阱入口：mepc/mcause 记录现场，MIE→MPIE 并关中断
                mepc_q    <= {trap_pc[31:2], 2'b00};
                mcause_q  <= trap_cause;
                mstatus_q <= mstat(1'b0, mstatus_q[`MSTATUS_MIE]);
            end
            else if (mret_en) begin
                // MRET：MIE←MPIE，MPIE←1，MPP←M
                mstatus_q <= mstat(mstatus_q[`MSTATUS_MPIE], 1'b1);
            end
        end
    end

    assign mstatus_o = mstatus_q;
    assign mepc_o    = mepc_q;
    assign mcause_o  = mcause_q;
    assign mie_o     = mie_q;

endmodule
