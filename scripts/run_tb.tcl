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

puts "==> RTL [llength $rtl_files] 个文件，TB [llength $tb_files] 个文件"

# ---- 在 sim/xsim_run 下编译运行，产物集中在 sim/（已被 gitignore） ----
set run_dir $root_dir/sim/xsim_run
file mkdir $run_dir
cd $run_dir

# ---- include 路径：rtl 与 tb 的所有子目录 ----
set inc_args [list]
foreach d [concat [collect_dirs $root_dir/rtl] [collect_dirs $root_dir/tb]] {
    lappend inc_args -i $d
}

# ---- 1) 编译 ----
set rc [catch {exec xvlog --sv {*}$inc_args {*}$rtl_files {*}$tb_files >@stdout 2>@stderr} err]
if {$rc} {
    puts "=========================================="
    puts "xvlog 编译失败："
    puts $err
    puts "=========================================="
    exit 1
}

# ---- 2) 详细阐述 ----
set rc [catch {exec xelab -debug typical $tb_top -s tb_sim --nolog \
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
