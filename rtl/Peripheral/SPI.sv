`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// SPI : SPI 主机（Mode 0 ~ Mode 3，8 bit，MSB first）
//
//   寄存器映射（偏移，按字对齐）
//     0x00  TXDATA  [RW]  发送数据（写低 8 位启动一次传输）
//     0x04  RXDATA  [R ]  接收数据（bit8 DONE，bit9 BUSY）
//     0x08  CTRL    [RW]  bit0  EN      使能
//                         bit1  START   写 1 启动传输（忙时忽略）
//                         bit2  CPOL    时钟极性
//                         bit3  CPHA    时钟相位
//                         bit4  CS      软件片选（0 = 选中，低有效）
//     0x0C  DIV     [RW]  时钟分频：SCLK 半周期 = (DIV+1) 个 clk_sys
//     0x10  STATUS  [RW]  bit0  BUSY，bit1 DONE（写 1 清除）
//
//   时序：SCLK 半周期由 DIV 决定；CPHA=0 时第一个边沿采样（5.1 的经典实现），
//         CPHA=1 时第一个边沿移位、第二个边沿采样。
//   说明：SS 由 CTRL[4] 与「传输中」共同决定：
//         传输中必定拉低；空闲时跟随 CTRL[4] 的软件值。
//=====================================================================
module SPI (
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

        // ---- SPI 物理接口 ----
        output logic sclk_o,
        output logic mosi_o,
        input  wire  miso_i,
        output logic ss_n_o
    );

    //---- 寄存器偏移 ----
    localparam logic [3:0] REG_TXDATA = 4'h0;
    localparam logic [3:0] REG_RXDATA = 4'h1;
    localparam logic [3:0] REG_CTRL   = 4'h2;
    localparam logic [3:0] REG_DIV    = 4'h3;
    localparam logic [3:0] REG_STATUS = 4'h4;

    logic [3:0] reg_sel;
    assign reg_sel = addr[4:2];

    //---- 寄存器 ----
    logic [7:0]  tx_data;
    logic [7:0]  rx_data;
    logic        en_reg;
    logic        cpol_reg;
    logic        cpha_reg;
    logic        cs_reg;
    logic [15:0] div_reg;
    logic        busy_reg;
    logic        done_reg;

    //---- 移位寄存器 ----
    logic [7:0]  tx_shift;
    logic [7:0]  rx_shift;
    logic [3:0]  bit_cnt;
    logic        sclk_reg;
    logic [15:0] div_cnt;

    wire we_hit = we & sel;

    //---- 边沿检测 ----
    logic sclk_d;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) sclk_d <= 1'b0;
        else                      sclk_d <= sclk_reg;
    end

    // 采样边沿：CPOL=0 取上升沿，CPOL=1 取下降沿
    wire sample_edge = cpol_reg ? (sclk_d & ~sclk_reg)
                                : (~sclk_d & sclk_reg);
    // 移位边沿：与采样边沿相反
    wire shift_edge  = cpol_reg ? (~sclk_d & sclk_reg)
                                : (sclk_d & ~sclk_reg);

    // CPHA=0：第一个边沿即采样边沿；CPHA=1：第一个边沿是移位边沿
    wire do_sample = cpha_reg ? shift_edge  : sample_edge;
    wire do_shift  = cpha_reg ? sample_edge : shift_edge;

    wire ctrl_wr = we_hit && (reg_sel == REG_CTRL);

    // 启动条件：写 CTRL 且 START=1，且（本拍写入的 EN 或当前已使能的 EN）为 1。
    // 这样软件可以用一次写（EN=1, START=1）直接发起传输，不必先单独写 EN。
    wire start_req = ctrl_wr && wdata[1] && (wdata[0] | en_reg);

    //==================================================================
    // 寄存器写
    //==================================================================
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            tx_data  <= 8'b0;
            rx_data  <= 8'b0;
            en_reg   <= `DISABLE;
            cpol_reg <= `FALSE;
            cpha_reg <= `FALSE;
            cs_reg   <= `FALSE;
            div_reg  <= 16'd0;
            done_reg <= `FALSE;
        end
        else if (we_hit) begin
            case (reg_sel)
                REG_TXDATA: tx_data <= wdata[7:0];
                REG_CTRL: begin
                    en_reg   <= wdata[0];
                    cpol_reg <= wdata[2];
                    cpha_reg <= wdata[3];
                    cs_reg   <= wdata[4];
                end
                REG_DIV: div_reg <= wdata[15:0];
                REG_STATUS: begin
                    if (wdata[1]) done_reg <= `FALSE;   // 写 1 清 DONE
                end
                default: ;
            endcase
        end
    end

    //==================================================================
    // 分频计数 → SCLK
    //==================================================================
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            div_cnt  <= 16'd0;
            sclk_reg <= 1'b0;
        end
        else if (!busy_reg) begin
            // 空闲时 SCLK = CPOL
            div_cnt  <= 16'd0;
            sclk_reg <= cpol_reg;
        end
        else if (div_cnt >= div_reg) begin
            div_cnt  <= 16'd0;
            sclk_reg <= ~sclk_reg;
        end
        else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    //==================================================================
    // 传输状态机 + 移位
    //==================================================================
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            busy_reg <= `DISABLE;
            tx_shift <= 8'b0;
            rx_shift <= 8'b0;
            bit_cnt  <= 4'd0;
        end
        else if (!busy_reg) begin
            //---- 空闲：等待启动 ----
            if (start_req) begin
                busy_reg <= `ENABLE;
                // 同拍又写 TXDATA 时，使用新写入的数据
                tx_shift <= (we_hit && (reg_sel == REG_TXDATA)) ? wdata[7:0]
                                                                : tx_data;
                rx_shift <= 8'b0;
                bit_cnt  <= 4'd0;
            end
        end
        else begin
            //---- 传输中 ----
            if (do_sample) begin
                rx_shift <= {rx_shift[6:0], miso_i};
                if (bit_cnt == 4'd7) begin
                    busy_reg <= `DISABLE;
                    rx_data  <= {rx_shift[6:0], miso_i};
                    done_reg <= `TRUE;
                end
                bit_cnt <= bit_cnt + 4'd1;
            end
            else if (do_shift) begin
                tx_shift <= {tx_shift[6:0], 1'b0};
            end
        end
    end

    //==================================================================
    // 读回
    //==================================================================
    always_comb begin
        if (rst_sys == `RESET_EN)
            rdata = 32'b0;
        else if (!sel || !re)
            rdata = 32'b0;
        else begin
            case (reg_sel)
                REG_TXDATA: rdata = {24'b0, tx_data};
                REG_RXDATA: rdata = {22'b0, busy_reg, done_reg, rx_data};
                REG_CTRL:   rdata = {27'b0, cs_reg, cpha_reg, cpol_reg,
                                     1'b0, en_reg};
                REG_DIV:    rdata = {16'b0, div_reg};
                REG_STATUS: rdata = {30'b0, done_reg, busy_reg};
                default:    rdata = 32'b0;
            endcase
        end
    end

    //==================================================================
    // 物理接口
    //   - SCLK 空闲电平 = CPOL
    //   - MOSI 由移位寄存器高位输出（MSB first）
    //   - SS_N 低有效：传输中必拉低；空闲时跟随 CTRL[4] 软件值
    //==================================================================
    assign sclk_o = sclk_reg;
    assign mosi_o = tx_shift[7];
    assign ss_n_o = !(!cs_reg | busy_reg);

endmodule
