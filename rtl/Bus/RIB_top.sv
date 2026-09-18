module RIB (
        input  wire clk_sys,
        input  wire rst_sys,

        input  wire [31:0] m0_addr_i,
        input  wire [31:0] m0_data_i,
        output reg  [31:0] m0_data_o,
        input  wire        m0_req_i,
        input  wire        m0_we_i,
        input  wire        m0_re_i,
        input  wire [ 2:0] m0_size_i,

        input  wire [31:0] m1_addr_i,
        input  wire [31:0] m1_data_i,
        output reg  [31:0] m1_data_o,
        input  wire        m1_req_i,
        input  wire        m1_we_i,
        input  wire        m1_re_i,
        input  wire [ 2:0] m1_size_i,

        input  wire [31:0] m2_addr_i,
        input  wire [31:0] m2_data_i,
        output reg  [31:0] m2_data_o,
        input  wire        m2_req_i,
        input  wire        m2_we_i,
        input  wire        m2_re_i,
        input  wire [ 2:0] m2_size_i,

        input  wire [31:0] m3_addr_i,
        input  wire [31:0] m3_data_i,
        output reg  [31:0] m3_data_o,
        input  wire        m3_req_i,
        input  wire        m3_we_i,
        input  wire        m3_re_i,
        input  wire [ 2:0] m3_size_i,

        output wire [31:0] s0_addr_o,
        output wire [31:0] s0_data_o,
        input  wire [31:0] s0_data_i,
        output reg         s0_we_o,
        output reg         s0_re_o,
        output reg  [ 2:0] s0_size_o
    );
    // Priority Arbiter
    localparam GRANT_0 = 4'b0001,
               GRANT_1 = 4'b0010,
               GRANT_2 = 4'b0100,
               GRANT_3 = 4'b1000;
    reg  [3:0] grant;
    wire [3:0] req;
    assign req = {m3_req_i, m2_req_i, m1_req_i, m0_req_i};  // 固定优先级
    always_comb begin
        if (req[0])
            grant = GRANT_3;
        else if (req[1])
            grant = GRANT_2;
        else if (req[2])
            grant = GRANT_1;
        else
            grant = GRANT_0;
    end

    // Slave Select
    localparam  SLAVE_0 = 4'b0000,
                SLAVE_1 = 4'b0001,
                SLAVE_2 = 4'b0010,
                SLAVE_3 = 4'b0011,
                SLAVE_4 = 4'b0100,
                SLAVE_5 = 4'b0101;



endmodule
