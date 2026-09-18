`include "../../sys_define.svh"

//=====================================================================
// MEM2WB : MEM -> WB 流水线寄存器
//   锁存访存结果 / ALU 结果 / PC+4 / 写回控制
//   WB 阶段组合选择 wb_data = (wb_sel == WB_ALU) ? alu_result :
//                             (wb_sel == WB_MEM) ? rdata      :
//                                                  pc4
//=====================================================================
module MEM2WB (
    // System
    input  wire              clk_sys,
    input  wire              rst_sys,
    // Control (通常恒为 0，WB 阶段一般不 flush / stall)
    input  wire              flush,
    input  wire              stall,

    // ---------- 来自 MEM 阶段 ----------
    input  wire [`DATA_BUS]  mem_alu_result,    // 来自 EX2MEM
    input  wire [`DATA_BUS]  mem_rdata,         // 来自访存子系统
    input  wire [`DATA_BUS]  mem_pc4,           // 来自 EX2MEM
    input  wire [`ADDR_BUS]  mem_rd_addr,
    input  wire              mem_rd_we,
    input  wire [      1:0]  mem_wb_sel,

    // ---------- 输出到 WB ----------
    output logic [`DATA_BUS] wb_alu_result,
    output logic [`DATA_BUS] wb_rdata,
    output logic [`DATA_BUS] wb_pc4,
    output logic [`ADDR_BUS] wb_rd_addr,
    output logic             wb_rd_we,
    output logic [      1:0] wb_sel
);

    always @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            // ---------------- 复位 ----------------
            wb_alu_result <= 32'b0;
            wb_rdata      <= 32'b0;
            wb_pc4        <= 32'b0;
            wb_rd_addr    <= 5'b0;
            wb_rd_we      <= `DISABLE;
            wb_sel        <= `WB_ALU;
        end
        else if (flush) begin
            // ---------------- 清空为 NOP ----------------
            wb_alu_result <= 32'b0;
            wb_rdata      <= 32'b0;
            wb_pc4        <= 32'b0;
            wb_rd_addr    <= 5'b0;
            wb_rd_we      <= `DISABLE;
            wb_sel        <= `WB_ALU;
        end
        else if (!stall) begin
            // ---------------- 正常流水 ----------------
            wb_alu_result <= mem_alu_result;
            wb_rdata      <= mem_rdata;
            wb_pc4        <= mem_pc4;
            wb_rd_addr    <= mem_rd_addr;
            wb_rd_we      <= mem_rd_we;
            wb_sel        <= mem_wb_sel;
        end
    end

endmodule
