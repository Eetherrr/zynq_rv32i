`timescale 1ns / 1ps
`include "sys_define.svh"

//=====================================================================
// tb_decoder — Decoder 全指令集验证
//
//   逐条指令检查译码结果，覆盖 RV32I 的 R/I/S/B/U/J 型与系统指令。
//   检查项：rd/rs1/rs2、rd_we、alu_op、op1_sel/op2_sel、imm、
//           wb_sel、mem_size、mem_read/mem_write、mem_unsigned、
//           branch/br_sel、jump/jump_reg、illegal 等。
//
//   运行： vivado -mode batch -source scripts/run_unit.tcl \
//            -tclargs tb_decoder rtl/Core/ID/Decoder.sv
//=====================================================================
module tb_decoder;

    // ---- DUT 端口 ----
    logic [`INST_BUS] instr;
    logic [`ADDR_BUS] rs1_addr, rs2_addr, rd_addr;
    logic             rd_we;
    logic [      3:0] alu_op;
    logic [      1:0] op1_sel, wb_sel, mem_size;
    logic [      0:0] op2_sel;
    logic [`DATA_BUS] imm;
    logic             mem_read, mem_write, mem_unsigned;
    logic             branch;
    logic [      2:0] br_sel;
    logic             jump, jump_reg, illegal, ecall, ebreak, fence;

    Decoder u_dut (
        .instr        (instr),
        .rs1_addr     (rs1_addr),
        .rs2_addr     (rs2_addr),
        .rd_addr      (rd_addr),
        .rd_we        (rd_we),
        .alu_op       (alu_op),
        .op1_sel      (op1_sel),
        .op2_sel      (op2_sel),
        .imm          (imm),
        .wb_sel       (wb_sel),
        .mem_size     (mem_size),
        .mem_read     (mem_read),
        .mem_write    (mem_write),
        .mem_unsigned (mem_unsigned),
        .branch       (branch),
        .br_sel       (br_sel),
        .jump         (jump),
        .jump_reg     (jump_reg),
        .illegal      (illegal),
        .ecall        (ecall),
        .ebreak       (ebreak),
        .fence        (fence)
    );

    // ---- 指令构造 ----
    function automatic logic [31:0] enc_r(input int f7, input int rs2, input int rs1,
                                         input int f3, input int rd);
        enc_r = (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|7'b0110011;
    endfunction
    function automatic logic [31:0] enc_i(input int imm12, input int rs1,
                                         input int f3, input int rd, input int op);
        enc_i = ((imm12 & 12'hfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;
    endfunction
    function automatic logic [31:0] enc_s(input int imm12, input int rs2,
                                         input int rs1, input int f3);
        enc_s = (((imm12>>5)&7'h7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm12&5'h1f)<<7)|7'b0100011;
    endfunction
    function automatic logic [31:0] enc_b(input int imm13, input int rs2,
                                         input int rs1, input int f3);
        enc_b = (((imm13>>12)&1)<<31)|(((imm13>>5)&6'h3f)<<25)|(rs2<<20)|(rs1<<15)|
                (f3<<12)|(((imm13>>1)&4'hf)<<8)|(((imm13>>11)&1)<<7)|7'b1100011;
    endfunction
    function automatic logic [31:0] enc_u(input int imm20, input int rd, input int op);
        enc_u = ((imm20 & 20'hfffff)<<12)|(rd<<7)|op;
    endfunction
    function automatic logic [31:0] enc_j(input int imm21, input int rd);
        enc_j = (((imm21>>20)&1)<<31)|(((imm21>>1)&10'h3ff)<<21)|(((imm21>>11)&1)<<20)|
                (((imm21>>12)&8'hff)<<12)|(rd<<7)|7'b1101111;
    endfunction

    // ---- 检查计数 ----
    int errors = 0;
    int checks = 0;

    task automatic chk32(input string name, input logic [31:0] got, input logic [31:0] exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %-34s got=0x%08x exp=0x%08x", name, got, exp);
        end
    endtask

    task automatic chk1(input string name, input logic got, input logic exp);
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %-34s got=%b exp=%b", name, got, exp);
        end
    endtask

    // 取指后统一检查某条指令的「非法标志应为 0」
    task automatic expect_legal(input string name);
        chk1({name, " illegal=0"}, illegal, 1'b0);
    endtask

    task automatic dump();
        $display("       rd=%0d rs1=%0d rs2=%0d rd_we=%b alu=%b op1=%b op2=%b imm=%h wb=%b",
                 rd_addr, rs1_addr, rs2_addr, rd_we, alu_op, op1_sel, op2_sel, imm, wb_sel);
    endtask

    initial begin
        $display("==========================================================");
        $display(" tb_decoder - RV32I 译码器全指令验证");
        $display("==========================================================");

        //==============================================================
        $display("\n-- 1) R 型 ALU 指令 --");
        // add x5, x6, x7
        instr = enc_r(7'h00, 7, 6, 3'b000, 5);
        #1;
        chk32("add rd",  {27'b0, rd_addr}, 32'd5);
        chk1 ("add rd_we", rd_we, 1'b1);
        chk32("add alu_op", {28'b0, alu_op}, 32'h0);
        chk32("add op1_sel", {30'b0, op1_sel}, 32'h0);   // OP1_RS1
        chk32("add op2_sel", {31'b0, op2_sel}, 32'h0);   // OP2_RS2
        chk32("add wb_sel", {30'b0, wb_sel}, 32'h0);     // WB_ALU
        expect_legal("add");

        // sub x5, x6, x7
        instr = enc_r(7'h20, 7, 6, 3'b000, 5); #1;
        chk32("sub alu_op", {28'b0, alu_op}, 32'h1);
        expect_legal("sub");

        // sll / slt / sltu / xor / srl / sra / or / and
        instr = enc_r(7'h00, 7, 6, 3'b001, 5); #1; chk32("sll alu_op", {28'b0,alu_op}, 32'h2);
        instr = enc_r(7'h00, 7, 6, 3'b010, 5); #1; chk32("slt alu_op", {28'b0,alu_op}, 32'h3);
        instr = enc_r(7'h00, 7, 6, 3'b011, 5); #1; chk32("sltu alu_op",{28'b0,alu_op}, 32'h4);
        instr = enc_r(7'h00, 7, 6, 3'b100, 5); #1; chk32("xor alu_op", {28'b0,alu_op}, 32'h5);
        instr = enc_r(7'h00, 7, 6, 3'b101, 5); #1; chk32("srl alu_op", {28'b0,alu_op}, 32'h6);
        instr = enc_r(7'h20, 7, 6, 3'b101, 5); #1; chk32("sra alu_op", {28'b0,alu_op}, 32'h7);
        instr = enc_r(7'h00, 7, 6, 3'b110, 5); #1; chk32("or  alu_op", {28'b0,alu_op}, 32'h8);
        instr = enc_r(7'h00, 7, 6, 3'b111, 5); #1; chk32("and alu_op", {28'b0,alu_op}, 32'h9);

        // 非法 funct7（如 add 用了 0x40）
        instr = enc_r(7'h40, 7, 6, 3'b000, 5); #1;
        chk1("R 型非法 funct7 -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n-- 2) I 型算术 / 移位 / 逻辑 --");
        // addi x5, x6, -1
        instr = enc_i(12'hfff, 6, 3'b000, 5, 7'b0010011); #1;
        chk32("addi imm=-1", imm, 32'hFFFF_FFFF);
        chk32("addi alu_op", {28'b0,alu_op}, 32'h0);
        chk32("addi op2_sel", {31'b0,op2_sel}, 32'h1);   // OP2_IMM
        chk1 ("addi mem_read", mem_read, 1'b0);
        expect_legal("addi");

        instr = enc_i(12'h123, 6, 3'b000, 5, 7'b0010011); #1;
        chk32("addi imm=+123", imm, 32'h0000_0123);

        instr = enc_i(12'h7ff, 6, 3'b000, 5, 7'b0010011); #1;
        chk32("addi imm=+0x7FF", imm, 32'h0000_07FF);

        instr = enc_i(12'h800, 6, 3'b000, 5, 7'b0010011); #1;
        chk32("addi imm=0x800(-2048)", imm, 32'hFFFF_F800);

        // slli x5, x6, 3   (funct7=0, shamt=3)
        instr = enc_i((0<<5)|3, 6, 3'b001, 5, 7'b0010011); #1;
        chk32("slli shamt=3 -> imm", imm, 32'd3);
        chk32("slli alu_op", {28'b0,alu_op}, 32'h2);
        expect_legal("slli");

        // srli / srai
        instr = enc_i((0<<5)|5, 6, 3'b101, 5, 7'b0010011); #1;
        chk32("srli alu_op", {28'b0,alu_op}, 32'h6);
        instr = enc_i((7'h20<<5)|5, 6, 3'b101, 5, 7'b0010011); #1;
        chk32("srai alu_op", {28'b0,alu_op}, 32'h7);
        expect_legal("srai");
        // srai 用错 funct7
        instr = enc_i((7'h10<<5)|5, 6, 3'b101, 5, 7'b0010011); #1;
        chk1("非法移位 funct7 -> illegal", illegal, 1'b1);

        // slti / sltiu / xori / ori / andi
        instr = enc_i(12'd10, 6, 3'b010, 5, 7'b0010011); #1; chk32("slti alu_op", {28'b0,alu_op}, 32'h3);
        instr = enc_i(12'd10, 6, 3'b011, 5, 7'b0010011); #1; chk32("sltiu alu_op",{28'b0,alu_op}, 32'h4);
        instr = enc_i(12'd10, 6, 3'b100, 5, 7'b0010011); #1; chk32("xori alu_op", {28'b0,alu_op}, 32'h5);
        instr = enc_i(12'd10, 6, 3'b110, 5, 7'b0010011); #1; chk32("ori alu_op",  {28'b0,alu_op}, 32'h8);
        instr = enc_i(12'd10, 6, 3'b111, 5, 7'b0010011); #1; chk32("andi alu_op", {28'b0,alu_op}, 32'h9);

        //==============================================================
        $display("\n-- 3) LUI / AUIPC --");
        instr = enc_u(20'hABCDE, 5, 7'b0110111); #1;
        chk32("lui imm", imm, 32'hABCD_E000);
        chk32("lui op1_sel", {30'b0,op1_sel}, 32'h2);    // OP1_ZERO
        chk32("lui op2_sel", {31'b0,op2_sel}, 32'h1);
        chk1 ("lui rd_we", rd_we, 1'b1);
        expect_legal("lui");

        instr = enc_u(20'h12345, 5, 7'b0010111); #1;
        chk32("auipc imm", imm, 32'h1234_5000);
        chk32("auipc op1_sel", {30'b0,op1_sel}, 32'h1);  // OP1_PC
        expect_legal("auipc");

        //==============================================================
        $display("\n-- 4) 载入指令 --");
        // lw x5, -4(x6)
        instr = enc_i(12'hffc, 6, 3'b010, 5, 7'b0000011); #1;
        chk1 ("lw mem_read",  mem_read,  1'b1);
        chk1 ("lw mem_write", mem_write, 1'b0);
        chk32("lw mem_size", {30'b0, mem_size}, 32'h2);  // MSZ_W
        chk1 ("lw mem_unsigned", mem_unsigned, 1'b0);
        chk32("lw wb_sel", {30'b0, wb_sel}, 32'h1);      // WB_MEM
        chk32("lw imm=-4", imm, 32'hFFFF_FFFC);
        chk32("lw op2_sel", {31'b0, op2_sel}, 32'h1);
        expect_legal("lw");

        instr = enc_i(12'd0, 6, 3'b000, 5, 7'b0000011); #1;
        chk32("lb mem_size", {30'b0, mem_size}, 32'h0);
        chk1 ("lb signed",   mem_unsigned, 1'b0);
        expect_legal("lb");

        instr = enc_i(12'd0, 6, 3'b001, 5, 7'b0000011); #1;
        chk32("lh mem_size", {30'b0, mem_size}, 32'h1);
        chk1 ("lh signed",   mem_unsigned, 1'b0);
        expect_legal("lh");

        instr = enc_i(12'd0, 6, 3'b100, 5, 7'b0000011); #1;
        chk32("lbu mem_size", {30'b0, mem_size}, 32'h0);
        chk1 ("lbu unsigned", mem_unsigned, 1'b1);
        expect_legal("lbu");

        instr = enc_i(12'd0, 6, 3'b101, 5, 7'b0000011); #1;
        chk32("lhu mem_size", {30'b0, mem_size}, 32'h1);
        chk1 ("lhu unsigned", mem_unsigned, 1'b1);
        expect_legal("lhu");

        // 非法 load funct3 = 011 / 110 / 111
        instr = enc_i(12'd0, 6, 3'b011, 5, 7'b0000011); #1;
        chk1("非法 load funct3 -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n-- 5) 存储指令 --");
        instr = enc_s(12'hff8, 7, 6, 3'b010); #1;   // sw x7, -8(x6)
        chk1 ("sw mem_write", mem_write, 1'b1);
        chk1 ("sw mem_read",  mem_read,  1'b0);
        chk32("sw mem_size", {30'b0, mem_size}, 32'h2);
        chk32("sw imm=-8", imm, 32'hFFFF_FFF8);
        chk1 ("sw rd_we=0", rd_we, 1'b0);
        chk1 ("sw not branch", branch, 1'b0);
        expect_legal("sw");

        instr = enc_s(12'h7ff, 7, 6, 3'b000); #1;   // sb
        chk32("sb mem_size", {30'b0, mem_size}, 32'h0);
        chk32("sb imm=+0x7FF", imm, 32'h0000_07FF);
        expect_legal("sb");

        instr = enc_s(12'h800, 7, 6, 3'b001); #1;   // sh, imm=-2048
        chk32("sh mem_size", {30'b0, mem_size}, 32'h1);
        chk32("sh imm=-2048", imm, 32'hFFFF_F800);
        expect_legal("sh");

        instr = enc_s(12'd0, 7, 6, 3'b011); #1;     // 非法 funct3
        chk1("非法 store funct3 -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n-- 6) 分支指令 --");
        // beq x6, x7, +8
        instr = enc_b(13'd8, 7, 6, 3'b000); #1;
        chk1 ("beq branch", branch, 1'b1);
        chk32("beq br_sel", {29'b0, br_sel}, 32'h0);
        chk32("beq imm=+8", imm, 32'd8);
        chk1 ("beq rd_we=0", rd_we, 1'b0);
        expect_legal("beq");

        instr = enc_b(13'd8, 7, 6, 3'b001); #1; chk32("bne br_sel", {29'b0,br_sel}, 32'h1);
        instr = enc_b(13'd8, 7, 6, 3'b100); #1; chk32("blt br_sel", {29'b0,br_sel}, 32'h4);
        instr = enc_b(13'd8, 7, 6, 3'b101); #1; chk32("bge br_sel", {29'b0,br_sel}, 32'h5);
        instr = enc_b(13'd8, 7, 6, 3'b110); #1; chk32("bltu br_sel",{29'b0,br_sel}, 32'h6);
        instr = enc_b(13'd8, 7, 6, 3'b111); #1; chk32("bgeu br_sel",{29'b0,br_sel}, 32'h7);

        // 负偏移：beq -8，检查 B 型立即数拼接（bit11 来自 instr[7]）
        instr = enc_b(-13'sd8, 7, 6, 3'b000); #1;
        chk32("beq imm=-8", imm, 32'hFFFF_FFF8);

        // 非法分支 funct3 = 010 / 011
        instr = enc_b(13'd8, 7, 6, 3'b010); #1;
        chk1("非法 branch funct3 -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n-- 7) JAL / JALR --");
        instr = enc_j(21'd16, 5); #1;          // jal x5, +16
        chk1 ("jal jump", jump, 1'b1);
        chk1 ("jal jump_reg=0", jump_reg, 1'b0);
        chk32("jal imm=+16", imm, 32'd16);
        chk32("jal wb_sel", {30'b0, wb_sel}, 32'h2);   // WB_PC4
        chk1 ("jal rd_we", rd_we, 1'b1);
        chk1 ("jal branch=0", branch, 1'b0);
        expect_legal("jal");

        instr = enc_j(-21'sd4, 5); #1;         // 负偏移
        chk32("jal imm=-4", imm, 32'hFFFF_FFFC);

        instr = enc_i(12'd8, 6, 3'b000, 5, 7'b1100111); #1;  // jalr x5, 8(x6)
        chk1 ("jalr jump", jump, 1'b1);
        chk1 ("jalr jump_reg", jump_reg, 1'b1);
        chk32("jalr imm=8", imm, 32'd8);
        chk32("jalr op2_sel", {31'b0, op2_sel}, 32'h1);
        expect_legal("jalr");

        // jalr 非法 funct3
        instr = enc_i(12'd8, 6, 3'b001, 5, 7'b1100111); #1;
        chk1("非法 jalr funct3 -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n-- 8) 系统 / FENCE / 非法 --");
        instr = 32'h0000_0073; #1;             // ecall
        chk1("ecall", ecall, 1'b1);
        chk1("ecall illegal=0", illegal, 1'b0);

        instr = 32'h0010_0073; #1;             // ebreak
        chk1("ebreak", ebreak, 1'b1);
        chk1("ebreak illegal=0", illegal, 1'b0);

        instr = 32'h0000_000f; #1;             // fence
        chk1("fence", fence, 1'b1);
        chk1("fence illegal=0", illegal, 1'b0);

        instr = 32'h0000_100f; #1;             // fence.i (funct3=001)
        chk1("fence.i", fence, 1'b1);

        // 非法 SYSTEM funct3
        instr = 32'h0000_1073; #1;             // funct3=001
        chk1("非法 SYSTEM funct3 -> illegal", illegal, 1'b1);

        // 未知 opcode
        instr = 32'hFFFF_FFFF; #1;
        chk1("未知 opcode -> illegal", illegal, 1'b1);

        //==============================================================
        $display("\n==========================================================");
        $display(" 共 %0d 项检查，失败 %0d 项", checks, errors);
        if (errors == 0) $display("==> tb_decoder 全部通过");
        else             $display("==> tb_decoder 存在失败");
        $display("==========================================================");
        $finish;
    end

endmodule
