module ROM(
        input  wire clk_sys,
        input  wire rst_sys,

        input  wire [31:0] addr,

        input  wire we_flag,
        input  wire [31:0] wr_data,

        output reg [31:0] rd_data
    );

    (* ram_style = "block" *) reg [31:0] ROM[0:4095];

    always_comb  begin
        if (!rst_sys)
            rd_data = 0;
        else
            rd_data = ROM[addr>>2];
    end

    always @(posedge clk_sys) begin
        if (we_flag)
            ROM[addr>>2] <= wr_data;
    end

endmodule
