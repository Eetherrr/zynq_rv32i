`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// GPIO : 通用输入输出
//
//   寄存器映射（偏移，按字对齐）
//     0x00  DATA   [RW]  读：引脚当前电平（无论方向）
//                        写：更新输出数据寄存器（仅对输出引脚生效）
//     0x04  DIR    [RW]  方向：1 = 输出，0 = 输入
//     0x08  SET    [ W]  写 1 置位对应输出位（原子读改写，读回 0）
//     0x0C  CLR    [ W]  写 1 清零对应输出位（原子读改写，读回 0）
//     0x10  IN     [R ]  只读引脚电平（与 DATA 读回相同，便于区分语义）
//
//   实现要点：
//     - 每个引脚用 IOBUF 原语实现三态；dir=0 时输出高阻，引脚可作输入。
//     - 写 DATA 使用「与方向掩码相与」的方式更新，避免误改输入位对应的
//       输出寄存器；SET / CLR 提供无读改写风险的原子操作。
//     - 所有寄存器写入均按字节使能（size）掩码，支持 SB / SH / SW。
//=====================================================================
module GPIO #(
        parameter int unsigned WIDTH = 8
    ) (
        input  wire              clk_sys,
        input  wire              rst_sys,

        // ---- 从 RIB ----
        input  wire              sel,
        input  wire [31:0]       addr,
        input  wire [31:0]       wdata,
        input  wire [     1:0]   size,
        input  wire              we,
        input  wire              re,
        output logic [31:0]      rdata,

        // ---- 物理接口 ----
        input  wire [WIDTH-1:0]  gpio_i,
        output wire [WIDTH-1:0]  gpio_o,
        output wire [WIDTH-1:0]  gpio_t   // 1 = 输出（三态门使能）
    );

    //---- 寄存器偏移 ----
    localparam logic [3:0] REG_DATA = 4'h0;
    localparam logic [3:0] REG_DIR  = 4'h1;
    localparam logic [3:0] REG_SET  = 4'h2;
    localparam logic [3:0] REG_CLR  = 4'h3;
    localparam logic [3:0] REG_IN   = 4'h4;

    logic [3:0] reg_sel;
    assign reg_sel = addr[4:2];

    //---- 寄存器 ----
    logic [WIDTH-1:0] data_reg;
    logic [WIDTH-1:0] dir_reg;

    wire we_hit = we & sel;

    //---- 字节使能掩码：把 size 展开为 32 bit 位掩码 ----
    logic [31:0] be_mask;
    always_comb begin
        case (size)
            `MSZ_B:  be_mask = 32'h0000_00FF << (8 * addr[1:0]);
            `MSZ_H:  be_mask = 32'h0000_FFFF << (16 * addr[1]);
            default: be_mask = 32'hFFFF_FFFF;
        endcase
    end

    //==================================================================
    // 寄存器写
    //==================================================================
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            data_reg <= {WIDTH{1'b0}};
            dir_reg  <= {WIDTH{1'b0}};      // 复位后全部为输入
        end
        else if (we_hit) begin
            case (reg_sel)
                REG_DATA: begin
                    // 只更新输出方向对应的位
                    data_reg <= (data_reg & ~be_mask[WIDTH-1:0])
                              | (wdata[WIDTH-1:0] & be_mask[WIDTH-1:0]
                                 & dir_reg);
                end
                REG_DIR: begin
                    dir_reg <= (dir_reg  & ~be_mask[WIDTH-1:0])
                             | (wdata[WIDTH-1:0] & be_mask[WIDTH-1:0]);
                end
                REG_SET: begin
                    data_reg <= data_reg
                              | (wdata[WIDTH-1:0] & be_mask[WIDTH-1:0]
                                 & dir_reg);
                end
                REG_CLR: begin
                    data_reg <= data_reg
                              & ~(wdata[WIDTH-1:0] & be_mask[WIDTH-1:0]
                                  & dir_reg);
                end
                default: ;
            endcase
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
                REG_DATA: rdata = {{(32 - WIDTH) {1'b0}}, gpio_i};
                REG_DIR:  rdata = {{(32 - WIDTH) {1'b0}}, dir_reg};
                REG_IN:   rdata = {{(32 - WIDTH) {1'b0}}, gpio_i};
                default:  rdata = 32'b0;    // SET / CLR 读回 0
            endcase
        end
    end

    //==================================================================
    // 物理接口
    //==================================================================
    assign gpio_o = data_reg;
    assign gpio_t = dir_reg;

endmodule
