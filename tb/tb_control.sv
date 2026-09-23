`timescale 1ns / 1ps
`include "sys_define.svh"
// tb_control — 冒险检测 / 冲刷 / 重定向
//
//   ★ 本设计的微架构：全前递 + EX 级发起访存。
//     - RAW：EX/MEM、MEM/WB 前递解决；
//     - load-use：**不需要停顿**。访存地址在 EX 级发起，BRAM 的 1 拍读延迟
//       落在 MEM 级，MEM 级组合提取出的 load 数据直接前递给紧随其后的指令
//       （EX.sv 的 ex_mem_load_data）。因此 Control 不再产生数据冒险停顿，
//       stall_* 恒为 0（保留端口给将来的多周期外设 / 结构冒险）。
//     - 取指与数据访问抢总线时的 PC 冻结由 CPU_top 用 RIB 授权信号处理。
// 运行: vivado -nolog -nojournal -mode batch -source scripts/run_unit.tcl \
//        -tclargs tb_control rtl/Core/Control.sv
module tb_control;
    logic clk=0, rst_sys=`RESET_DIS;
    logic ex_branch_taken, ex_jump_taken;
    logic [`DATA_BUS] ex_branch_target, ex_jump_target;
    logic [`DATA_BUS] ex_pc;
    logic ex_illegal, ex_ecall, ex_ebreak;
    logic ex_load_misaligned, ex_store_misaligned, ex_csr_illegal;
    logic interrupt_req, mret_en;
    logic [`DATA_BUS] mtvec, mepc;
    logic trap_en;
    logic [`DATA_BUS] trap_cause, trap_pc;
    logic [`ADDR_BUS] id_ex_rd_addr;
    logic id_ex_rd_we, id_ex_mem_read;
    logic [`INST_BUS] id_instr;
    logic [`ADDR_BUS] id_rs1_addr, id_rs2_addr;
    logic flush_if2id, flush_id2ex, flush_ex2mem, flush_mem2wb;
    logic stall_pc, stall_if2id, stall_id2ex;
    logic redirect_en, exception_en;
    logic [`DATA_BUS] redirect_pc;
    always #5 clk = ~clk;

    Control u_dut (.clk_sys(clk), .rst_sys(rst_sys),
        .ex_pc(ex_pc),
        .ex_branch_taken(ex_branch_taken), .ex_jump_taken(ex_jump_taken),
        .ex_branch_target(ex_branch_target), .ex_jump_target(ex_jump_target),
        .ex_illegal(ex_illegal), .ex_ecall(ex_ecall), .ex_ebreak(ex_ebreak),
        .ex_load_misaligned(ex_load_misaligned),
        .ex_store_misaligned(ex_store_misaligned),
        .ex_csr_illegal(ex_csr_illegal),
        .interrupt_req(interrupt_req), .mtvec(mtvec),
        .mret_en(mret_en), .mepc(mepc),
        .trap_en(trap_en), .trap_cause(trap_cause), .trap_pc(trap_pc),
        .id_ex_rd_addr(id_ex_rd_addr), .id_ex_rd_we(id_ex_rd_we),
        .id_ex_mem_read(id_ex_mem_read),
        .id_instr(id_instr), .id_rs1_addr(id_rs1_addr), .id_rs2_addr(id_rs2_addr),
        .flush_if2id(flush_if2id), .flush_id2ex(flush_id2ex),
        .flush_ex2mem(flush_ex2mem), .flush_mem2wb(flush_mem2wb),
        .stall_pc(stall_pc), .stall_if2id(stall_if2id), .stall_id2ex(stall_id2ex),
        .redirect_en(redirect_en), .redirect_pc(redirect_pc), .exception_en(exception_en));

    int errors=0, checks=0;
    task automatic ck1(input string n, input logic g, input logic e);
        checks=checks+1;
        if (g!==e) begin errors=errors+1; $display("  [FAIL] %-46s got=%b exp=%b",n,g,e); end
    endtask
    task automatic ck32(input string n, input logic [31:0] g, input logic [31:0] e);
        checks=checks+1;
        if (g!==e) begin errors=errors+1; $display("  [FAIL] %-46s got=%h exp=%h",n,g,e); end
    endtask

    // 指令编码助手
    function automatic logic [31:0] r_type(input int rs2, input int rs1, input int rd);
        r_type = (7'h00<<25)|(rs2<<20)|(rs1<<15)|(3'b000<<12)|(rd<<7)|7'b0110011;
    endfunction
    function automatic logic [31:0] lw_type(input int rs1, input int rd);
        lw_type = (12'd0<<20)|(rs1<<15)|(3'b010<<12)|(rd<<7)|7'b0000011;
    endfunction
    function automatic logic [31:0] i_type(input int rs1, input int rd);
        i_type = (12'd1<<20)|(rs1<<15)|(3'b000<<12)|(rd<<7)|7'b0010011;  // addi
    endfunction
    function automatic logic [31:0] s_type(input int rs1, input int rs2);
        s_type = (7'h00<<25)|(rs2<<20)|(rs1<<15)|(3'b010<<12)|7'b0100011; // sw
    endfunction

    task automatic idle();
        ex_pc=32'h0;
        ex_branch_taken=0; ex_jump_taken=0; ex_illegal=0; ex_ecall=0; ex_ebreak=0;
        ex_load_misaligned=0; ex_store_misaligned=0; ex_csr_illegal=0;
        interrupt_req=0; mret_en=0; mtvec=32'h0; mepc=32'h0;
        id_ex_rd_addr=0; id_ex_rd_we=0; id_ex_mem_read=0;
        id_instr=i_type(0,0); id_rs1_addr=0; id_rs2_addr=0;
        ex_branch_target=0; ex_jump_target=0;
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_control - 冒险/冲刷/重定向验证");
        $display("==========================================================");
        idle(); #1;

        $display("\n-- 无冒险时不应停顿/冲刷 --");
        ck1("stall_pc=0", stall_pc, 1'b0);
        ck1("stall_if2id=0", stall_if2id, 1'b0);
        ck1("flush_if2id=0", flush_if2id, 1'b0);
        ck1("redirect_en=0", redirect_en, 1'b0);

        $display("\n-- load-use：本设计不停顿（靠 MEM→EX 数据前递）--");
        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = r_type(0,5,1);  id_rs1_addr=5; id_rs2_addr=0; #1;   // add x1,x5,x0 用 rs1
        ck1("rs1 命中 load: 不 stall_pc",    stall_pc,    1'b0);
        ck1("rs1 命中 load: 不 stall_if2id", stall_if2id, 1'b0);
        ck1("rs1 命中 load: 不 flush_id2ex", flush_id2ex, 1'b0);

        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = r_type(5,0,1); id_rs1_addr=0; id_rs2_addr=5; #1;    // 用 rs2
        ck1("rs2 命中 load: 不 stall_pc",    stall_pc,    1'b0);

        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = s_type(5,0); id_rs1_addr=5; #1;                     // store 用 rs1
        ck1("store 命中 load: 不 stall_pc",  stall_pc,    1'b0);

        $display("\n-- 其它情形同样不停顿 --");
        // 不是 load
        idle(); id_ex_mem_read=0; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = r_type(0,5,1); id_rs1_addr=5; #1;
        ck1("非 load 不 stall", stall_pc, 1'b0);
        // 目的寄存器是 x0
        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=0;
        id_instr = r_type(0,5,1); id_rs1_addr=5; #1;
        ck1("rd=x0 不 stall", stall_pc, 1'b0);
        // rd_we=0
        idle(); id_ex_mem_read=1; id_ex_rd_we=0; id_ex_rd_addr=5;
        id_instr = r_type(0,5,1); id_rs1_addr=5; #1;
        ck1("rd_we=0 不 stall", stall_pc, 1'b0);
        // 地址不同
        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = r_type(0,6,1); id_rs1_addr=6; #1;
        ck1("地址不同 不 stall", stall_pc, 1'b0);
        // lui 不用源寄存器
        idle(); id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = (20'h12345<<12)|(1<<7)|7'b0110111; id_rs1_addr=5; id_rs2_addr=0; #1;
        ck1("lui 不用源寄存器 不 stall", stall_pc, 1'b0);

        $display("\n-- 分支重定向 --");
        idle(); ex_branch_taken=1; ex_branch_target=32'h0000_1234; #1;
        ck1("分支: redirect_en", redirect_en, 1'b1);
        ck32("分支: redirect_pc", redirect_pc, 32'h0000_1234);
        ck1("分支: flush_if2id", flush_if2id, 1'b1);
        ck1("分支: flush_id2ex", flush_id2ex, 1'b1);
        // ★ 重定向不能冲刷 EX2MEM：JAL/JALR 还要靠它把返回地址写到 rd
        ck1("分支: flush_ex2mem=0（链接值要写回）", flush_ex2mem, 1'b0);
        ck1("分支: flush_mem2wb=0", flush_mem2wb, 1'b0);

        $display("\n-- 跳转重定向（JAL/JALR 的链接值必须能写回）--");
        idle(); ex_jump_taken=1; ex_jump_target=32'h0000_5678; #1;
        ck1("跳转: redirect_en", redirect_en, 1'b1);
        ck32("跳转: redirect_pc", redirect_pc, 32'h0000_5678);
        ck1("跳转: flush_if2id", flush_if2id, 1'b1);
        ck1("跳转: flush_id2ex", flush_id2ex, 1'b1);
        ck1("跳转: flush_ex2mem=0", flush_ex2mem, 1'b0);

        $display("\n-- 两者同时：分支优先 --");
        idle(); ex_branch_taken=1; ex_jump_taken=1;
        ex_branch_target=32'hAAAA_0000; ex_jump_target=32'hBBBB_0000; #1;
        ck32("同时发生时取分支目标", redirect_pc, 32'hAAAA_0000);

        $display("\n-- 异常（进入陷阱：redirect 到 mtvec）--");
        idle(); mtvec=32'h0000_0F00; ex_pc=32'h0000_0123; ex_illegal=1; #1;
        ck1("illegal: trap_en", trap_en, 1'b1);
        ck1("illegal: redirect_en", redirect_en, 1'b1);
        ck32("illegal: redirect_pc = mtvec", redirect_pc, 32'h0000_0F00);
        ck32("illegal: trap_cause = 2", trap_cause, `CAUSE_ILLEGAL_INSTR);
        ck32("illegal: trap_pc = 出错指令 PC", trap_pc, 32'h0000_0123);
        ck1("illegal: exception_en", exception_en, 1'b1);
        ck1("illegal: flush_if2id", flush_if2id, 1'b1);
        ck1("illegal: flush_id2ex", flush_id2ex, 1'b1);
        ck1("illegal: flush_ex2mem（出错指令不写回）", flush_ex2mem, 1'b1);
        idle(); mtvec=32'h0000_0F00; ex_ecall=1; #1;
        ck1("ecall: exception_en", exception_en, 1'b1);
        ck32("ecall: cause = 11", trap_cause, `CAUSE_ECALL_M);
        idle(); mtvec=32'h0000_0F00; ex_ebreak=1; #1;
        ck1("ebreak: exception_en", exception_en, 1'b1);
        ck32("ebreak: cause = 3", trap_cause, `CAUSE_BREAKPOINT);
        idle(); ex_load_misaligned=1; mtvec=32'h0000_0F00; #1;
        ck32("load 非对齐: cause = 4", trap_cause, `CAUSE_LOAD_MISALIGN);
        idle(); ex_store_misaligned=1; mtvec=32'h0000_0F00; #1;
        ck32("store 非对齐: cause = 6", trap_cause, `CAUSE_STORE_MISALIGN);
        idle(); ex_csr_illegal=1; mtvec=32'h0000_0F00; #1;
        ck32("非法 CSR: cause = 2", trap_cause, `CAUSE_ILLEGAL_INSTR);
        idle(); #1;
        ck1("无异常: exception_en=0", exception_en, 1'b0);
        ck1("无异常: trap_en=0", trap_en, 1'b0);

        $display("\n-- 陷阱与分支的优先级 / 冲刷范围 --");
        idle(); mtvec=32'h0000_0F00; interrupt_req=1; ex_pc=32'h0000_0200; #1;
        ck1("中断: trap_en", trap_en, 1'b1);
        ck32("中断: cause = 0x8000_0007", trap_cause, `CAUSE_IRQ_M_TIMER);
        ck1("中断: flush_ex2mem", flush_ex2mem, 1'b1);
        // 异常优先于中断
        idle(); mtvec=32'h0000_0F00; interrupt_req=1; ex_illegal=1; #1;
        ck32("异常优先于中断", trap_cause, `CAUSE_ILLEGAL_INSTR);
        // 陷阱优先于分支
        idle(); mtvec=32'h0000_0F00; ex_branch_taken=1;
        ex_branch_target=32'hAAAA_0000; interrupt_req=1; #1;
        ck32("陷阱优先于分支目标", redirect_pc, 32'h0000_0F00);
        // MRET：返回 mepc
        idle(); mret_en=1; mepc=32'h0000_0456; #1;
        ck1("MRET: redirect_en", redirect_en, 1'b1);
        ck32("MRET: redirect_pc = mepc", redirect_pc, 32'h0000_0456);
        idle(); #1;

        $display("\n-- 重定向与访存并存：以重定向为准 --");
        ex_branch_taken=1; ex_branch_target=32'h1000;
        id_ex_mem_read=1; id_ex_rd_we=1; id_ex_rd_addr=5;
        id_instr = r_type(0,5,1); id_rs1_addr=5; #1;
        ck1("重定向时 redirect_en=1", redirect_en, 1'b1);
        ck32("重定向时 pc 正确", redirect_pc, 32'h1000);
        ck1("重定向时 flush_ex2mem=0", flush_ex2mem, 1'b0);
        ck1("重定向时 stall 保持 0", stall_pc, 1'b0);

        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors==0) $display("==> tb_control 全部通过"); else $display("==> tb_control 存在失败");
        $display("==========================================================");
        $finish;
    end
endmodule
