`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// UART : 串口收发（8N1，无校验，无流控）
//
//   寄存器映射（偏移，按字对齐）
//     0x00  TXDATA  [RW]  写：发送数据（写低 8 位即启动一次发送）
//                          读：上次写入的发送数据
//     0x04  RXDATA  [R ]  接收数据（bit8 = READY，bit9 = TX_BUSY）
//     0x08  STATUS  [RW]  bit0 TX_BUSY   发送中
//                         bit1 RX_READY  收到一个字节（写 1 清除）
//     0x0C  BAUD    [RW]  波特率分频：位周期 = BAUD+1 个 clk_sys
//
//   波特率计算： BAUD = clk_sys / baud - 1
//   例：clk = 100 MHz，115200 bps → BAUD = 100e6/115200 - 1 = 867
//
//   时序说明：收发状态机各自以「一个位周期」为步长推进，波特率计数器
//             在计数到 0 时产生 tick，并在此刻重装 BAUD。
//   已知简化：接收端在起始位下降沿把计数器预置为半个位周期以对准位中间，
//             该预置滞后一个 clk_sys，高波特率（BAUD 很小）时采样点略偏，
//             未做多数表决；如需更稳健的接收可后续增强。
//=====================================================================
module UART #(
        parameter int unsigned BAUD_DEFAULT = 867
    ) (
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

        // ---- 物理接口 ----
        input  wire  rx_i,
        output logic tx_o
    );

    //---- 寄存器偏移 ----
    localparam logic [3:0] REG_TXDATA = 4'h0;
    localparam logic [3:0] REG_RXDATA = 4'h1;
    localparam logic [3:0] REG_STATUS = 4'h2;
    localparam logic [3:0] REG_BAUD   = 4'h3;

    logic [3:0] reg_sel;
    assign reg_sel = addr[3:2];

    //---- 发送状态编码 ----
    localparam logic [1:0] TX_IDLE  = 2'd0;
    localparam logic [1:0] TX_START = 2'd1;
    localparam logic [1:0] TX_DATA  = 2'd2;
    localparam logic [1:0] TX_STOP  = 2'd3;

    //---- 接收状态编码 ----
    localparam logic [1:0] RX_IDLE  = 2'd0;
    localparam logic [1:0] RX_START = 2'd1;
    localparam logic [1:0] RX_DATA  = 2'd2;
    localparam logic [1:0] RX_STOP  = 2'd3;

    //---- 状态与寄存器 ----
    logic [1:0]  tx_state, rx_state;
    logic [2:0]  tx_idx, rx_idx;
    logic [7:0]  tx_shift, rx_shift;
    logic [7:0]  tx_data, rx_data;
    logic        tx_line, tx_busy, rx_ready;
    logic [31:0] baud_reg, baud_cnt;
    logic        baud_busy_d1;      // 波特率「忙」的上一拍（见 baud_tick / 计数器）

    logic        tx_start;      // 写 TXDATA 产生的启动脉冲
    logic        baud_preset;   // 接收起始沿：把计数器预置半个位周期

    wire we_hit    = we & sel;
    // baud_tick 只在计数器「已经在跑」时有效：空闲时计数器停在 0，
    // 若不加 baud_busy_d1 这一项，刚进入发送状态的那一拍就会误判为
    // 一个 tick，导致起始位只持续 1 拍、整帧短一个位周期。
    wire baud_tick = (baud_cnt == 32'd0) && baud_busy_d1;
    wire baud_busy = tx_busy | (rx_state != RX_IDLE);

    //==================================================================
    // 单块时序逻辑：写寄存器 + 波特率计数 + 收发状态机
    //   （保证 baud_cnt / 各寄存器都只有一个驱动源）
    //==================================================================
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            baud_reg     <= BAUD_DEFAULT[31:0];
            baud_cnt     <= 32'd0;
            baud_busy_d1 <= `FALSE;
            tx_data     <= 8'b0;
            rx_data     <= 8'b0;
            tx_start    <= `FALSE;
            baud_preset <= `FALSE;
            tx_state    <= TX_IDLE;
            rx_state    <= RX_IDLE;
            tx_idx      <= 3'd0;
            rx_idx      <= 3'd0;
            tx_shift    <= 8'b0;
            rx_shift    <= 8'b0;
            tx_line     <= 1'b1;
            tx_busy     <= `FALSE;
            rx_ready    <= `FALSE;
        end
        else begin
            tx_start    <= `FALSE;
            baud_preset <= `FALSE;

            //==========================================================
            // 1) 寄存器写
            //==========================================================
            if (we_hit) begin
                case (reg_sel)
                    REG_TXDATA: begin
                        tx_data  <= wdata[7:0];
                        tx_start <= `TRUE;      // 写 TXDATA 即启动发送
                    end
                    REG_BAUD:   baud_reg <= wdata;
                    REG_STATUS: begin
                        if (wdata[1]) rx_ready <= `FALSE;   // 写 1 清 READY
                    end
                    default: ;
                endcase
            end

            //==========================================================
            // 2) 波特率计数器
            //    空闲时直接停在 0，避免 tick 连续有效。
            //    ★ 刚进入「忙」的那一拍必须先装一个完整位周期：否则计数器
            //      停在 0 会让 baud_tick 立刻有效，起始位只持续 1 拍，
            //      整帧短一个位周期，接收方按位中点采样就会整体错一位。
            //==========================================================
            if (baud_preset)
                baud_cnt <= {1'b0, baud_reg[31:1]};     // 半个位周期
            else if (baud_busy && !baud_busy_d1)
                baud_cnt <= baud_reg;                   // 刚进入忙：装整位周期
            else if (baud_busy)
                baud_cnt <= baud_tick ? baud_reg : (baud_cnt - 32'd1);
            else
                baud_cnt <= 32'd0;

            baud_busy_d1 <= baud_busy;

            //==========================================================
            // 3) 发送状态机
            //    TX_IDLE → TX_START → TX_DATA(8 位, LSB first) → TX_STOP
            //==========================================================
            case (tx_state)
                TX_IDLE: begin
                    tx_line <= 1'b1;
                    if (tx_start) begin
                        // 同拍又写 TXDATA 时用新写入的数据；否则用寄存器值。
                        // （tx_data 是非阻塞赋值，下一拍才会更新，这里必须
                        //   在本拍就把要发送的字节装进移位寄存器。）
                        tx_shift <= (we_hit && (reg_sel == REG_TXDATA)) ? wdata[7:0]
                                                                        : tx_data;
                        tx_state <= TX_START;
                        tx_line  <= 1'b0;       // 起始位
                        tx_busy  <= `ENABLE;
                    end
                end

                TX_START: begin
                    if (baud_tick) begin
                        tx_state <= TX_DATA;
                        tx_idx   <= 3'd0;
                        tx_line  <= tx_shift[0]; // 数据位 0（LSB first）
                    end
                end

                TX_DATA: begin
                    if (baud_tick) begin
                        if (tx_idx == 3'd7) begin
                            tx_state <= TX_STOP;
                            tx_line  <= 1'b1;   // 停止位
                        end
                        else begin
                            tx_idx   <= tx_idx + 3'd1;
                            tx_shift <= {1'b0, tx_shift[7:1]};
                            tx_line  <= tx_shift[1];
                        end
                    end
                end

                TX_STOP: begin
                    if (baud_tick) begin
                        tx_state <= TX_IDLE;
                        tx_busy  <= `DISABLE;
                        tx_line  <= 1'b1;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase

            //==========================================================
            // 4) 接收状态机（在位中间采样）
            //==========================================================
            case (rx_state)
                RX_IDLE: begin
                    if (!rx_i) begin                // 起始位下降沿
                        rx_state    <= RX_START;
                        baud_preset <= `TRUE;
                    end
                end

                RX_START: begin
                    if (baud_tick) begin
                        // 位中间仍为低 → 确认起始位，否则视为毛刺
                        rx_state <= rx_i ? RX_IDLE : RX_DATA;
                        rx_idx   <= 3'd0;
                    end
                end

                RX_DATA: begin
                    if (baud_tick) begin
                        rx_shift <= {rx_i, rx_shift[7:1]};
                        if (rx_idx == 3'd7) begin
                            rx_data  <= {rx_i, rx_shift[7:1]};
                            rx_state <= RX_STOP;
                        end
                        else begin
                            rx_idx <= rx_idx + 3'd1;
                        end
                    end
                end

                RX_STOP: begin
                    if (baud_tick) begin
                        rx_state <= RX_IDLE;
                        rx_ready <= `TRUE;          // 停止位结束，数据有效
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    //==================================================================
    // 读回
    //   寄存一拍输出，与 ROM/RAM（BMG 寄存输出）统一为
    //   「T 拍给地址、T+1 拍数据有效」：CPU 在 EX 级发起地址，
    //   MEM 级取回数据，RIB 读回按「上一拍片选」对齐。
    //==================================================================
    logic [31:0] rdata_comb;

    always_comb begin
        if (rst_sys == `RESET_EN)
            rdata_comb = 32'b0;
        else if (!sel || !re)
            rdata_comb = 32'b0;
        else begin
            case (reg_sel)
                REG_TXDATA: rdata_comb = {24'b0, tx_data};
                REG_RXDATA: rdata_comb = {22'b0, tx_busy, rx_ready, rx_data};
                REG_STATUS: rdata_comb = {30'b0, rx_ready, tx_busy};
                REG_BAUD:   rdata_comb = baud_reg;
                default:    rdata_comb = 32'b0;
            endcase
        end
    end

    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) rdata <= 32'b0;
        else if (sel && re)       rdata <= rdata_comb;
    end

    assign tx_o = tx_line;

endmodule
