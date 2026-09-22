# ============================================================
#  check_rtl.tcl — 非工程模式的 RTL 语法 / 详细阐述检查
#  用法: vivado -mode batch -source scripts/check_rtl.tcl -nolog -nojournal
#  说明: 直接把 rtl/ 下所有源文件读入内存工程并 elaborate：
#          1) 先查 CPU_top（纯 RTL，不依赖 IP）—— 必须通过
#          2) 再尝试 CPU_SOC_top（例化 ROM/RAM 的 BMG IP）
#             内存工程里没有 IP 模型，会报 "module 'ROM' not found"，
#             此时只提示跳过，不算失败；带 IP 的完整检查走
#                make synth            （综合）
#                make tb TB=tb_top     （仿真，脚本会带上 IP 行为模型）
#  可用环境变量 VIVADOPRJ_TOP 覆盖第 1 步的顶层（默认 CPU_top）。
# ============================================================

set root_dir [file normalize [file join [file dirname [info script]] ..]]
set part     "xc7z010clg400-1"
set core_top "CPU_top"          ;# 纯 RTL 顶层，永远可检查
set soc_top  "CPU_SOC_top"      ;# 含 IP 的顶层
if {[info exists ::env(VIVADOPRJ_TOP)] && $::env(VIVADOPRJ_TOP) ne ""} {
    set soc_top $::env(VIVADOPRJ_TOP)
}

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

# ---- 1) 纯 RTL 顶层（不依赖 IP）：必须通过 ----
set_property top $core_top [current_fileset]
if {[catch {synth_design -rtl -top $core_top -part $part -mode out_of_context} err]} {
    puts "=========================================="
    puts "RTL 检查失败（顶层 $core_top）："
    puts $err
    puts "=========================================="
    exit 1
}
puts "=========================================="
puts "==> RTL 详细阐述通过，顶层：$core_top"
puts "=========================================="

# ---- 2) SoC 顶层（例化 ROM/RAM 的 BMG IP）：失败只提示 ----
if {$soc_top ne $core_top} {
    set_property top $soc_top [current_fileset]
    if {[catch {synth_design -rtl -top $soc_top -part $part -mode out_of_context} err]} {
        puts "==> $soc_top 详细阐述需要 ROM/RAM 的 BMG IP 模型，本次跳过"
        puts "    （带 IP 的检查：make synth 或 make tb TB=tb_top）"
    } else {
        puts "==> $soc_top 详细阐述通过（含 IP）"
    }
}
exit 0
