# ============================================================
#  run_tb.tcl — 非工程模式的 RTL 仿真（独立 xsim 流程）
#  用法: make tb
#        make tb TB=<测试平台顶层名>
#  说明: 不依赖 Vivado 工程，直接用 xvlog / xelab / xsim 三步编译并运行
#        tb/ 下的测试平台。$display 直接打印，便于脚本化回归。
#        （内存工程不支持 launch_simulation，故这里用独立流程。）
# ============================================================

set root_dir [file normalize [file join [file dirname [info script]] ..]]
set tb_top   "tb_rib_periph"
if {[info exists ::env(TB)] && $::env(TB) ne ""} {
    set tb_top $::env(TB)
}
set part "xc7z010clg400-1"

# ---- 递归收集文件 ----
proc collect_files {dir patterns} {
    set out [list]
    if {![file isdirectory $dir]} { return $out }
    foreach pat $patterns {
        foreach f [glob -nocomplain -directory $dir -types f $pat] {
            lappend out $f
        }
    }
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [collect_files $sub $patterns]]
    }
    return $out
}

# ---- 递归收集目录 ----
proc collect_dirs {dir} {
    set out [list $dir]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [collect_dirs $sub]]
    }
    return $out
}

set rtl_files [collect_files $root_dir/rtl {*.sv *.v}]
set tb_files  [collect_files $root_dir/tb  {*.sv *.v}]

if {[llength $tb_files] == 0} {
    puts "错误：tb/ 下没有找到测试平台源文件"
    exit 1
}

# ---- 收集 IP 仿真模型（ROM / RAM 为 Block Memory Generator）----
set ip_files [list]
foreach ip {ROM RAM} {
    foreach cand [list \
            "$root_dir/prj/zynq_rv32i.gen/sources_1/ip/$ip/sim/$ip.v" \
            "$root_dir/prj/zynq_rv32i.srcs/sources_1/ip/$ip/sim/$ip.v"] {
        if {[file exists $cand]} { lappend ip_files $cand ; break }
    }
}

# ---- Block Memory Generator 行为模型 ----
#   ROM.v / RAM.v 只是 IP 的例化壳，内部例化 blk_mem_gen_v8_4_5，
#   该模块来自 Vivado 安装目录下的 IP 行为模型，必须一并编译，
#   否则 xelab 会报 "Module <blk_mem_gen_v8_4_5> not found"。
if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    set bmg "$::env(XILINX_VIVADO)/data/ip/xilinx/blk_mem_gen_v8_4/simulation/blk_mem_gen_v8_4.v"
    if {[file exists $bmg]} {
        lappend ip_files $bmg
        puts "==> Block Memory Generator 行为模型：$bmg"
    } else {
        puts "==> 警告：未找到 BMG 行为模型 $bmg"
    }
}

puts "==> RTL [llength $rtl_files] 个，TB [llength $tb_files] 个，IP [llength $ip_files] 个"

# ---- 在 sim/xsim_run 下编译运行，产物集中在 sim/（已被 gitignore） ----
set run_dir $root_dir/sim/xsim_run
file mkdir $run_dir
cd $run_dir

# ---- IP 初始化文件必须放在运行目录（BLK_MEM_GEN 会按 C_INIT_FILE 查找）----
#   ROM 的内容以 tb/prog/ROM.mif（由 tb/prog/gen_cpu_test.py 生成）为准：
#   先复制 IP 目录下的 mif，再用 tb/prog/ROM.mif 覆盖，这样改了测试程序
#   不需要重新生成 IP 就能仿真。
foreach f [glob -nocomplain "$root_dir/prj/zynq_rv32i.gen/sources_1/ip/*/*.mif"] {
    file copy -force $f $run_dir
}
if {[file exists "$root_dir/tb/prog/ROM.mif"]} {
    file copy -force "$root_dir/tb/prog/ROM.mif" $run_dir
    puts "==> ROM 镜像：tb/prog/ROM.mif（覆盖 IP 生成的 ROM.mif）"
}
foreach f [glob -nocomplain "$root_dir/prj/zynq_rv32i.ip_user_files/mem_init_files/*.coe"] {
    file copy -force $f $run_dir
}

# ---- include 路径：rtl 与 tb 的所有子目录 ----
set inc_args [list]
foreach d [concat [collect_dirs $root_dir/rtl] [collect_dirs $root_dir/tb]] {
    lappend inc_args -i $d
}

# ---- 1) 编译 ----
set rc [catch {exec xvlog --sv {*}$inc_args {*}$rtl_files {*}$ip_files {*}$tb_files >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xvlog 编译失败："
    puts $err
    puts "=========================================="
    exit 1
}

# ---- 2) 详细阐述 ----
# ROM/RAM 的 IP 仿真模型依赖 BLK_MEM_GEN 原语，需要链接 unisims_ver
set lib_args [list]
if {[info exists ::env(XILINX_VIVADO)] && $::env(XILINX_VIVADO) ne ""} {
    lappend lib_args -L unisims_ver
    lappend lib_args -i "$::env(XILINX_VIVADO)/data/xsim/verilog"
    puts "==> 链接 unisims_ver：$::env(XILINX_VIVADO)/data/xsim/verilog"
} else {
    puts "==> 警告：未设置 XILINX_VIVADO，含 IP 的仿真可能因缺少 unisims_ver 而失败"
}

set rc [catch {exec xelab -debug typical $tb_top -s tb_sim --nolog {*}$lib_args \
                    >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xelab 详细阐述失败："
    puts $err
    puts "=========================================="
    exit 1
}

# ---- 3) 运行到 TB 内的 $finish ----
set rc [catch {exec xsim tb_sim -R --nolog >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xsim 运行失败："
    puts $err
    puts "=========================================="
    exit 1
}

puts "=========================================="
puts "==> 仿真结束，顶层：$tb_top"
puts "=========================================="
exit 0
