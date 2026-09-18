`include "sys_define.sv"

module CPU_SOC_top(
        input wire clk_sys,
        input wire rst_async,
        // UART Interface
        input wire rx,
        input wire tx
    );

    reg rst_sys;
    always @(posedge clk_sys or negedge rst_async) begin
        if (!rst_async)
            rst_sys <= `RESET_EN;
        else
            rst_sys <= `RESET_DIS;
    end

    // cpu wire
    wire rom_instr_i, rom_instr_addr_i;

    CPU_top u_cpu (
                .clk_sys         (clk_sys),
                .rst_sys         (rst_sys),
                .rom_instr_i     (rom_instr_i),
                .rom_instr_addr_i(rom_instr_addr_i),
                .ram_addr_o      (ram_addr_o),
                .ram_data_o      (ram_data_o),
                .ram_we_flag     (ram_we_flag),
                .ram_re_flag     (ram_re_flag),
                .data_size       (data_size),
                .ram_data_i      (ram_data_i),
                .int_i           (int_i),
                .hold_flag_i     (hold_flag_i)
            );

    ROM u_rom (
            .rst_sys(rst_sys),
            .addr   (rom_instr_addr_i),
            .we_flag(we_flag),
            .wr_data(wr_data),
            .rd_data(rom_instr_i)
        );



endmodule
