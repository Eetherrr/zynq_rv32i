`include "../sys_define.svh"

module DFFSetHold #(
    parameter DATA_WIDTH = 32
)(
    input wire clk_sys,
    input wire rst_sys,

    input wire hold_flag,
    input wire [DATA_WIDTH-1:0] set_data,

    input wire [DATA_WIDTH-1:0] data_i,
    output reg [DATA_WIDTH-1:0] data_o
);

  always @(posedge clk_sys or negedge rst_sys) begin
    if (rst_sys == `RESET_EN || hold_flag)
        data_o <= set_data;
    else
        data_o <= data_i;
  end

endmodule
