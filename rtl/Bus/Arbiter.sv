`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// Arbiter : 固定优先级仲裁器
//   - 优先级：m0 > m1 > m2 > m3（下标越小优先级越高）
//   - 纯组合逻辑，单周期出结果
//   - 无请求时 valid=0 / grant=0，从机请求被门控关闭
//
//   grant 为独热码，便于直接用作各主机端口的选择信号；
//   grant_id 为二进制下标，供 RIB 做读数据回送 MUX。
//=====================================================================
module Arbiter #(
        parameter int MASTER_NUM = 4
    ) (
        input  wire [MASTER_NUM-1:0] m_req_i,     // 各主机请求
        output logic [MASTER_NUM-1:0] grant_o,    // 独热授权
        output logic                  valid_o,    // 有主机获得授权
        output logic [           1:0] grant_id_o  // 授权主机下标
    );

    always_comb begin
        grant_o    = '0;
        grant_id_o = 2'd0;
        valid_o    = 1'b0;

        // 从高优先级（下标小）向低优先级扫描，命中即停
        for (int i = MASTER_NUM - 1; i >= 0; i--) begin
            if (m_req_i[i]) begin
                grant_o    = 32'(1) << i;
                grant_id_o = i[1:0];
                valid_o    = 1'b1;
            end
        end
    end

endmodule
