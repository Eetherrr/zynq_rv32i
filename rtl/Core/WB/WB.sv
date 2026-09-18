`include "../../sys_define.svh"

//=====================================================================
// WB : 写回阶段
//   - 按 wb_sel 选择写回数据源
//       WB_ALU : ALU 结果
//       WB_MEM : 加载数据
//       WB_PC4 : PC + 4 (JAL/JALR)
//   - 输出到寄存器堆写端口
//=====================================================================
module WB (
    // ---------- 来自 MEM2WB ----------
    input  wire [`DATA_BUS]  wb_alu_result,
    input  wire [`DATA_BUS]  wb_rdata,
    input  wire [`DATA_BUS]  wb_pc4,
    input  wire [      1:0]  wb_sel,
    input  wire [`ADDR_BUS]  wb_rd_addr,
    input  wire              wb_rd_we,

    // ---------- 输出到寄存器堆 ----------
    output logic [`DATA_BUS] rd_data,
    output logic [`ADDR_BUS] rd_addr,
    output logic             rd_we
);

    always_comb begin
        case (wb_sel)
            `WB_ALU : rd_data = wb_alu_result;
            `WB_MEM : rd_data = wb_rdata;
            `WB_PC4 : rd_data = wb_pc4;
            default : rd_data = 32'b0;
        endcase
    end

    assign rd_addr = wb_rd_addr;
    assign rd_we   = wb_rd_we;

endmodule
