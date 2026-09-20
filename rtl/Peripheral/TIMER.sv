`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// TIMER : 定时器 / 计数器
//
//   寄存器映射（偏移，按字对齐）
//     0x00  LOAD    [RW]  计数初值 / 重载值
//     0x04  COUNT   [R ]  当前计数值
//     0x08  CTRL    [RW]  bit0  EN      使能计数
//                         bit1  IRQ_EN  溢出时拉高 irq_o
//                         bit2  ONESHOT 1=溢出后停（单次）0=自动重载（周期）
//     0x0C  STATUS  [RW]  bit0  OVERFLOW 溢出标志（写 1 清除）
//
//   计数行为：COUNT 从 LOAD 开始递减，减到 0 时产生一个周期脉冲，
//             置位 OVERFLOW，并按 ONESHOT 决定停或重载。
//=====================================================================
module TIMER (
        input  wire        clk_sys,
        input  wire        rst_sys,

        // ---- 从 RIB ----
        input  wire        sel,
        input  wire [31:0] addr,
        input  wire [31:0] wdata,
        input  wire [ 1:0] size,
        input  wire        we,
        input  wire        re,
        output logic [31:0] rdata,

        // ---- 中断 ----
        output logic irq_o
    );

    //---- 寄存器偏移 ----
    localparam logic [3:0] REG_LOAD   = 4'h0;
    localparam logic [3:0] REG_COUNT  = 4'h1;
    localparam logic [3:0] REG_CTRL   = 4'h2;
    localparam logic [3:0] REG_STATUS = 4'h3;

    logic [3:0] reg_sel;
    assign reg_sel = addr[3:2];

    //---- 寄存器 ----
    logic [31:0] load_reg;
    logic [31:0] count_reg;
    logic        en_reg;
    logic        irq_en_reg;
    logic        oneshot_reg;
    logic        overflow_reg;

    wire overflow = en_reg && (count_reg == 32'd0);

    //---- 写使能：sel & we 同时成立 ----
    wire we_hit = we & sel;

    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            load_reg     <= 32'd0;
            count_reg    <= 32'd0;
            en_reg       <= `DISABLE;
            irq_en_reg   <= `DISABLE;
            oneshot_reg  <= `DISABLE;
            overflow_reg <= `FALSE;
        end
        else begin
            //==========================================================
            // 1) 写寄存器（软件写优先级最高）
            //==========================================================
            if (we_hit) begin
                case (reg_sel)
                    REG_LOAD: load_reg <= wdata;
                    REG_CTRL: begin
                        en_reg      <= wdata[0];
                        irq_en_reg  <= wdata[1];
                        oneshot_reg <= wdata[2];
                    end
                    REG_STATUS: begin
                        if (wdata[0]) overflow_reg <= `FALSE;   // 写 1 清标志
                    end
                    default: ;
                endcase
            end

            //==========================================================
            // 2) 计数（写 CTRL 的那一拍不计数，避免与装载冲突）
            //==========================================================
            if (we_hit && (reg_sel == REG_CTRL)) begin
                // 0 → 1 使能：把 LOAD 装入 COUNT
                if (wdata[0] && !en_reg)
                    count_reg <= load_reg;
            end
            else if (!en_reg) begin
                count_reg <= count_reg;             // 未使能：保持
            end
            else if (overflow) begin
                overflow_reg <= `TRUE;
                if (oneshot_reg)
                    en_reg    <= `DISABLE;          // 单次模式：溢出后停
                count_reg <= load_reg;              // 周期模式：自动重载
            end
            else begin
                count_reg <= count_reg - 32'd1;
            end
        end
    end

    //---- 读回 ----
    always_comb begin
        if (rst_sys == `RESET_EN)
            rdata = 32'b0;
        else if (!sel || !re)
            rdata = 32'b0;
        else begin
            case (reg_sel)
                REG_LOAD:   rdata = load_reg;
                REG_COUNT:  rdata = count_reg;
                REG_CTRL:   rdata = {29'b0, oneshot_reg, irq_en_reg, en_reg};
                REG_STATUS: rdata = {31'b0, overflow_reg};
                default:    rdata = 32'b0;
            endcase
        end
    end

    assign irq_o = overflow_reg & irq_en_reg;

endmodule
