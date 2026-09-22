# ============================================================
#  run_unit.tcl — 单模块 / 纯 RTL 仿真（不涉及 IP）
#  用法:
#    vivado -mode batch -source scripts/run_unit.tcl \
#           -tclargs <tb_top> <rtl_file1> [rtl_file2 ...]
#
#  说明:
#    只编译显式给出的 RTL 文件 + 对应测试平台，不扫描 rtl/ 全部目录，
#    因此不会碰到 ROM/RAM 的 Block Memory Generator IP，可在本机直接跑。
#    程序镜像由测试平台内部生成，不依赖 tb/prog/*.coe。
# ============================================================

set tb_top [lindex $argv 0]
if {$tb_top eq ""} {
    puts "错误：未指定测试平台顶层模块"
    exit 1
}

set root_dir [file normalize [file join [file dirname [info script]] ..]]
set part     "xc7z010clg400-1"

# 其余参数是 RTL 文件（相对项目根目录）
set rtl_files [list]
foreach f [lrange $argv 1 end] {
    lappend rtl_files [file normalize [file join $root_dir $f]]
}

# 测试平台文件：tb/<tb_top>.sv
set tb_file "$root_dir/tb/$tb_top.sv"
if {![file exists $tb_file]} {
    puts "错误：找不到测试平台 $tb_file"
    exit 1
}

puts "==> 顶层 $tb_top"
puts "==> RTL [llength $rtl_files] 个 + TB 1 个"

# 运行目录（不放工程里，避免污染）
set run_dir "$root_dir/sim/unit"
file mkdir $run_dir
cd $run_dir

# include 路径：rtl 各子目录 + tb
set inc_args [list]
proc collect_dirs {dir} {
    set out [list $dir]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [collect_dirs $sub]]
    }
    return $out
}
foreach d [concat [collect_dirs $root_dir/rtl] [collect_dirs $root_dir/tb]] {
    lappend inc_args -i $d
}

set compile_files [concat $rtl_files [list $tb_file]]
set rc [catch {exec xvlog --sv {*}$inc_args {*}$compile_files >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xvlog 编译失败："
    puts $err
    puts "=========================================="
    exit 1
}

set rc [catch {exec xelab -debug typical $tb_top -s unit_sim --nolog >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xelab 详细阐述失败："
    puts $err
    puts "=========================================="
    exit 1
}

set rc [catch {exec xsim unit_sim -R --nolog >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xsim 运行失败："
    puts $err
    puts "=========================================="
    exit 1
}

puts "==> $tb_top 仿真结束"
exit 0
