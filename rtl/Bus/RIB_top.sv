`timescale 1ns / 1ps

`include "../sys_define.svh"

//=====================================================================
// RIB (RISC-V Internal Bus) 顶层
//
//   结构： 4 主机 ──► Arbiter ──► 共享从机通路 ──► 6 从机
//                                    │
//                                    └── 读数据 MUX 回送授权主机
//
//   - 仲裁：固定优先级，m0 > m1 > m2 > m3
//   - 译码：s_sel = (addr & MASK) == BASE，见 sys_define.svh
//   - 时序：单周期、纯组合读通路（与 MEM 阶段「读写同拍返回」的假设一致）
//           若将来接入需要等待的从机，应由从机拉高 CPU 的 hold_flag_i
//           冻结流水线，而不是在本模块内引入 valid/ready 状态机。
//
//   主机端口：mN_req/we/re/size/addr/wdata 由主机驱动，mN_rdata 由 RIB 回送
//   从机端口：s_*_req/re/we/size/addr/wdata 由 RIB 驱动，s_*_rdata 由从机回送
//             s_*_sel 为地址译码结果，作为从机片选（读 MUX 选择亦使用它）
//=====================================================================
module RIB (
        input  wire        clk_sys,
        input  wire        rst_sys,

        // ---- 仲裁状态（引出给 CPU 用于取指停顿 / 调试）----
        output logic [ 3:0] grant_o,        // 独热授权
        output logic        valid_o,        // 本拍有主机获得授权
        output logic        m1_grant_o,     // 取指口（m1）是否获得授权

        // ---------------- Master 0 ----------------
        input  wire [31:0] m0_addr,
        input  wire [31:0] m0_wdata,
        output logic [31:0] m0_rdata,
        input  wire        m0_req,
        input  wire        m0_we,
        input  wire        m0_re,
        input  wire [ 1:0] m0_size,

        // ---------------- Master 1 ----------------
        input  wire [31:0] m1_addr,
        input  wire [31:0] m1_wdata,
        output logic [31:0] m1_rdata,
        input  wire        m1_req,
        input  wire        m1_we,
        input  wire        m1_re,
        input  wire [ 1:0] m1_size,

        // ---------------- Master 2 ----------------
        input  wire [31:0] m2_addr,
        input  wire [31:0] m2_wdata,
        output logic [31:0] m2_rdata,
        input  wire        m2_req,
        input  wire        m2_we,
        input  wire        m2_re,
        input  wire [ 1:0] m2_size,

        // ---------------- Master 3 ----------------
        input  wire [31:0] m3_addr,
        input  wire [31:0] m3_wdata,
        output logic [31:0] m3_rdata,
        input  wire        m3_req,
        input  wire        m3_we,
        input  wire        m3_re,
        input  wire [ 1:0] m3_size,

        // ---------------- Slave : ROM ----------------
        output logic [31:0] s_rom_addr,
        output logic [31:0] s_rom_wdata,
        output logic        s_rom_we,
        output logic        s_rom_re,
        output logic        s_rom_req,
        output logic [ 1:0] s_rom_size,
        input  wire [31:0] s_rom_rdata,
        output logic        s_rom_sel,

        // ---------------- Slave : RAM ----------------
        output logic [31:0] s_ram_addr,
        output logic [31:0] s_ram_wdata,
        output logic        s_ram_we,
        output logic        s_ram_re,
        output logic        s_ram_req,
        output logic [ 1:0] s_ram_size,
        input  wire [31:0] s_ram_rdata,
        output logic        s_ram_sel,

        // ---------------- Slave : TIMER ----------------
        output logic [31:0] s_timer_addr,
        output logic [31:0] s_timer_wdata,
        output logic        s_timer_we,
        output logic        s_timer_re,
        output logic        s_timer_req,
        output logic [ 1:0] s_timer_size,
        input  wire [31:0] s_timer_rdata,
        output logic        s_timer_sel,

        // ---------------- Slave : SPI ----------------
        output logic [31:0] s_spi_addr,
        output logic [31:0] s_spi_wdata,
        output logic        s_spi_we,
        output logic        s_spi_re,
        output logic        s_spi_req,
        output logic [ 1:0] s_spi_size,
        input  wire [31:0] s_spi_rdata,
        output logic        s_spi_sel,

        // ---------------- Slave : UART ----------------
        output logic [31:0] s_uart_addr,
        output logic [31:0] s_uart_wdata,
        output logic        s_uart_we,
        output logic        s_uart_re,
        output logic        s_uart_req,
        output logic [ 1:0] s_uart_size,
        input  wire [31:0] s_uart_rdata,
        output logic        s_uart_sel,

        // ---------------- Slave : GPIO ----------------
        output logic [31:0] s_gpio_addr,
        output logic [31:0] s_gpio_wdata,
        output logic        s_gpio_we,
        output logic        s_gpio_re,
        output logic        s_gpio_req,
        output logic [ 1:0] s_gpio_size,
        input  wire [31:0] s_gpio_rdata,
        output logic        s_gpio_sel
    );

    //==================================================================
    // 1. 仲裁：收集各主机请求，产生独热授权
    //==================================================================
    logic [3:0] grant;
    logic       grant_valid;
    logic [1:0] grant_id;

    Arbiter #(
        .MASTER_NUM (4)
    ) u_Arbiter (
        .m_req_i   ({m3_req, m2_req, m1_req, m0_req}),
        .grant_o   (grant),
        .valid_o   (grant_valid),
        .grant_id_o(grant_id)
    );

    // 引出仲裁状态
    assign grant_o    = grant;
    assign valid_o    = grant_valid;
    assign m1_grant_o = grant[1];

    //==================================================================
    // 2. 主机侧 MUX：把授权主机的地址 / 数据 / 控制送到共享从机通路
    //==================================================================
    logic [31:0] bus_addr;
    logic [31:0] bus_wdata;
    logic        bus_req;
    logic        bus_we;
    logic        bus_re;
    logic [ 1:0] bus_size;

    always_comb begin
        case (grant)
            4'b0001: begin
                bus_addr  = m0_addr;
                bus_wdata = m0_wdata;
                bus_we    = m0_we;
                bus_re    = m0_re;
                bus_size  = m0_size;
            end
            4'b0010: begin
                bus_addr  = m1_addr;
                bus_wdata = m1_wdata;
                bus_we    = m1_we;
                bus_re    = m1_re;
                bus_size  = m1_size;
            end
            4'b0100: begin
                bus_addr  = m2_addr;
                bus_wdata = m2_wdata;
                bus_we    = m2_we;
                bus_re    = m2_re;
                bus_size  = m2_size;
            end
            4'b1000: begin
                bus_addr  = m3_addr;
                bus_wdata = m3_wdata;
                bus_we    = m3_we;
                bus_re    = m3_re;
                bus_size  = m3_size;
            end
            default: begin
                bus_addr  = 32'b0;
                bus_wdata = 32'b0;
                bus_we    = 1'b0;
                bus_re    = 1'b0;
                bus_size  = `MSZ_W;
            end
        endcase
    end

    assign bus_req = grant_valid;

    //==================================================================
    // 3. 地址译码：为每个从机产生片选
    //==================================================================
    assign s_rom_sel   = ((bus_addr & `ROM_MASK)   == `ROM_BASE);
    assign s_ram_sel   = ((bus_addr & `RAM_MASK)   == `RAM_BASE);
    assign s_timer_sel = ((bus_addr & `TIMER_MASK) == `TIMER_BASE);
    assign s_spi_sel   = ((bus_addr & `SPI_MASK)   == `SPI_BASE);
    assign s_uart_sel  = ((bus_addr & `UART_MASK)  == `UART_BASE);
    assign s_gpio_sel  = ((bus_addr & `GPIO_MASK)  == `GPIO_BASE);

    //==================================================================
    // 4. 从机请求分发：只有被选中的从机收到 req，避免误写
    //==================================================================
    assign s_rom_req   = bus_req & s_rom_sel;
    assign s_ram_req   = bus_req & s_ram_sel;
    assign s_timer_req = bus_req & s_timer_sel;
    assign s_spi_req   = bus_req & s_spi_sel;
    assign s_uart_req  = bus_req & s_uart_sel;
    assign s_gpio_req  = bus_req & s_gpio_sel;

    // 从机内部地址 = 总线地址裁掉高位后的小范围偏移，
    // 使从机无需实现和基址等大的存储空间（见 sys_define.svh 的 *_ALIAS_MASK）
    assign s_rom_addr   = bus_addr & `ROM_ALIAS_MASK;
    assign s_ram_addr   = bus_addr & `RAM_ALIAS_MASK;
    assign s_timer_addr = bus_addr & `TIMER_ALIAS_MASK;
    assign s_spi_addr   = bus_addr & `SPI_ALIAS_MASK;
    assign s_uart_addr  = bus_addr & `UART_ALIAS_MASK;
    assign s_gpio_addr  = bus_addr & `GPIO_ALIAS_MASK;

    assign s_rom_wdata   = bus_wdata;
    assign s_ram_wdata   = bus_wdata;
    assign s_timer_wdata = bus_wdata;
    assign s_spi_wdata   = bus_wdata;
    assign s_uart_wdata  = bus_wdata;
    assign s_gpio_wdata  = bus_wdata;

    assign s_rom_we   = bus_we & s_rom_sel;
    assign s_ram_we   = bus_we & s_ram_sel;
    assign s_timer_we = bus_we & s_timer_sel;
    assign s_spi_we   = bus_we & s_spi_sel;
    assign s_uart_we  = bus_we & s_uart_sel;
    assign s_gpio_we  = bus_we & s_gpio_sel;

    assign s_rom_re   = bus_re & s_rom_sel;
    assign s_ram_re   = bus_re & s_ram_sel;
    assign s_timer_re = bus_re & s_timer_sel;
    assign s_spi_re   = bus_re & s_spi_sel;
    assign s_uart_re  = bus_re & s_uart_sel;
    assign s_gpio_re  = bus_re & s_gpio_sel;

    assign s_rom_size   = bus_size;
    assign s_ram_size   = bus_size;
    assign s_timer_size = bus_size;
    assign s_spi_size   = bus_size;
    assign s_uart_size  = bus_size;
    assign s_gpio_size  = bus_size;

    //==================================================================
    // 5. 主机读回片选（与从机「1 拍读延迟」对齐）
    //   从机（ROM / RAM 是 BMG 寄存输出，外设也寄存一拍）统一为
    //     T 拍给 addr → T+1 拍 rdata 才是该地址的数据。
    //   因此每个主机的读数据必须按「它上一拍获得授权时选中的从机」
    //   回送，而不是按当前片选：
    //     - 取指口持续请求，上一拍片选 == 当前片选，行为与旧版一致；
    //     - 数据口一次读只占「地址拍」，数据在下一拍才回来。若不记住
    //       上一拍的片选，下一拍总线已还给取指口，读回就会丢。
    //   （这也是 CPU 侧「EX 级发起地址、MEM 级取数据」的对应实现。）
    //==================================================================
    function automatic logic [5:0] slave_dec(input logic [31:0] a);
        slave_dec = {((a & `GPIO_MASK)  == `GPIO_BASE),
                     ((a & `UART_MASK)  == `UART_BASE),
                     ((a & `SPI_MASK)   == `SPI_BASE),
                     ((a & `TIMER_MASK) == `TIMER_BASE),
                     ((a & `RAM_MASK)   == `RAM_BASE),
                     ((a & `ROM_MASK)   == `ROM_BASE)};
    endfunction

    logic [5:0] m_sel_q [0:3];      // 各主机上一拍命中从机（独热）

    integer mi;
    always_ff @(posedge clk_sys or negedge rst_sys) begin
        if (rst_sys == `RESET_EN) begin
            for (mi = 0; mi < 4; mi = mi + 1)
                m_sel_q[mi] <= 6'b0;
        end
        else begin
            m_sel_q[0] <= grant[0] ? slave_dec(m0_addr) : 6'b0;
            m_sel_q[1] <= grant[1] ? slave_dec(m1_addr) : 6'b0;
            m_sel_q[2] <= grant[2] ? slave_dec(m2_addr) : 6'b0;
            m_sel_q[3] <= grant[3] ? slave_dec(m3_addr) : 6'b0;
        end
    end

    // 有效读回片选：
    //   上一拍有访问 → 用上一拍片选（此时从机 rdata 正是那笔访问的数据）；
    //   上一拍没有访问（复位后第一拍 / 被抢占后）→ 退回「当前授权主机」
    //   的片选，与旧版组合读回一致，避免复位后第一拍读回 0 被当成
    //   一条全 0（非法）指令执行。
    logic [5:0]  m_sel_eff [0:3];
    logic [31:0] m_addr_i  [0:3];

    always_comb begin
        m_addr_i[0] = m0_addr;
        m_addr_i[1] = m1_addr;
        m_addr_i[2] = m2_addr;
        m_addr_i[3] = m3_addr;

        for (int m = 0; m < 4; m = m + 1)
            m_sel_eff[m] = (m_sel_q[m] != 6'b0) ? m_sel_q[m]
                          : (grant[m] ? slave_dec(m_addr_i[m]) : 6'b0);
    end

    logic [31:0] m_rdata [0:3];

    always_comb begin
        for (int m = 0; m < 4; m = m + 1) begin
            case (m_sel_eff[m])
                6'b000001: m_rdata[m] = s_rom_rdata;
                6'b000010: m_rdata[m] = s_ram_rdata;
                6'b000100: m_rdata[m] = s_timer_rdata;
                6'b001000: m_rdata[m] = s_spi_rdata;
                6'b010000: m_rdata[m] = s_uart_rdata;
                6'b100000: m_rdata[m] = s_gpio_rdata;
                default:   m_rdata[m] = 32'b0;      // 未映射地址
            endcase
        end

        m0_rdata = m_rdata[0];
        m1_rdata = m_rdata[1];
        m2_rdata = m_rdata[2];
        m3_rdata = m_rdata[3];
    end

endmodule
