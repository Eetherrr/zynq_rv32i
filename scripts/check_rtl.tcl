# ============================================================
#  check_rtl.tcl — 非工程模式的 RTL 语法 / 详细阐述检查
#  用法: vivado -mode batch -source scripts/check_rtl.tcl -nolog -nojournal
#  说明: 直接把 rtl/ 下所有源文件读入内存工程并 elaborate 顶层，
#        用于在没有测试平台时快速发现语法与连线错误。
# ============================================================

set root_dir [file normalize [file join [file dirname [info script]] ..]]
set top      "CPU_SOC_top"
set part     "xc7z010clg400-1"

# ---- 递归收集某目录下匹配的文件 ----
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

# ---- 递归收集目录本身 ----
proc collect_dirs {dir} {
    set out [list $dir]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set out [concat $out [collect_dirs $sub]]
    }
    return $out
}

set files [collect_files $root_dir/rtl {*.sv *.v}]
puts "==> 共 [llength $files] 个源文件"

if {[llength $files] == 0} {
    puts "错误：rtl/ 下没有找到源文件"
    exit 1
}

# ---- 内存工程 ----
create_project -in_memory -part $part

# ---- include 路径：rtl 及其所有子目录 ----
set_property include_dirs [collect_dirs $root_dir/rtl] [current_fileset]

read_verilog -sv $files
set_property top $top [current_fileset]

if {[catch {synth_design -rtl -top $top -part $part -mode out_of_context} err]} {
    puts "=========================================="
    puts "RTL 检查失败："
    puts $err
    puts "=========================================="
    exit 1
}

puts "=========================================="
puts "==> RTL 详细阐述通过，顶层：$top"
puts "=========================================="
exit 0
