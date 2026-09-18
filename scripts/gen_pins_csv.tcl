# ============================================================
#  gen_pins_csv.tcl
#  从顶层模块端口生成 / 更新 constrs/pins.csv 模板
#
#  行为：
#    - 若 CSV 不存在           → 生成模板（Pin 列填 TODO）
#    - 若 CSV 存在但端口集合一致 → 不重写（保护用户手填的引脚）
#    - 若 CSV 存在但端口集合变化 → 保留已填值，新增端口填 TODO，
#                                 删除的端口移除，重写 CSV
# ============================================================

set root_dir $::env(VIVADOPRJ_ROOT)
set prj_name $::env(VIVADOPRJ_NAME)
set top      $::env(VIVADOPRJ_TOP)
set device   $::env(VIVADOPRJ_DEVICE)

set csv_path $root_dir/constrs/pins.csv
set xpr_path $root_dir/prj/$prj_name.xpr

if {![file exists $xpr_path]} {
    puts "错误：工程不存在：$xpr_path"
    puts "      请先运行 make refresh"
    exit 1
}

# ---------- 1. 读取现有 CSV，保留已填字段 ----------
set existing_pins  [dict create]
set existing_iostd [dict create]

if {[file exists $csv_path]} {
    set fp [open $csv_path r]
    set raw [read $fp]
    close $fp
    set raw [string map {"\r\n" "\n" "\r" "\n"} $raw]
    foreach line [split $raw "\n"] {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[string index $line 0] eq "#"} { continue }
        set fields [split $line ","]
        set port [string trim [lindex $fields 0]]
        if {[string match -nocase "port*" $port]} { continue }
        if {$port eq ""} { continue }
        set pin   [string trim [lindex $fields 1]]
        set iostd [string trim [lindex $fields 2]]
        if {$pin   ne ""} { dict set existing_pins  $port $pin }
        if {$iostd ne ""} { dict set existing_iostd $port $iostd }
    }
}

# ---------- 2. 打开工程，做 RTL elaboration ----------
open_project $xpr_path

if {[catch {
    synth_design -rtl -top $top -part $device -name rtl_elab
} err]} {
    puts "错误：RTL elaboration 失败"
    puts "      $err"
    catch {close_design -quiet}
    catch {close_project}
    exit 1
}

# ---- 提取端口名 ----
# 注意：不能直接对 get_ports 的结果做 lsort，因为端口对象的字符串
#       表示在 RTL elaboration 阶段是 "null"，lsort 会把它们全部
#       变成字面量 "null"。必须先 get_property NAME 取出名字。
set port_objs [get_ports]
set ports [list]
foreach p $port_objs {
    set pname [get_property -quiet NAME $p]
    if {$pname eq ""} {
        # 兜底：某些 Vivado 版本 NAME 为空时用 REF_NAME
        set pname [get_property -quiet REF_NAME $p]
    }
    if {$pname ne ""} {
        lappend ports $pname
    }
}
set ports [lsort -unique $ports]

catch {close_design -quiet}
catch {close_project}

# ---------- 3. 生成新内容 ----------
set lines {}
lappend lines "Port,Pin,IOSTANDARD"

set n 0
foreach p $ports {
    # 总线 data[7:0] → 展开为 data[7] ... data[0]
    set expanded {}
    if {[regexp {^([^\[]+)\[(\d+):(\d+)\]$} $p -> base hi lo]} {
        set a $hi
        set b $lo
        set step [expr {$a >= $b ? -1 : 1}]
        for {set i $a} {$step < 0 ? $i >= $b : $i <= $b} {incr i $step} {
            lappend expanded "${base}\[${i}\]"
        }
    } else {
        lappend expanded $p
    }

    foreach port $expanded {
        set pin   "TODO"
        set iostd "LVCMOS33"
        if {[dict exists $existing_pins  $port]} {
            set pin [dict get $existing_pins $port]
        }
        if {[dict exists $existing_iostd $port]} {
            set iostd [dict get $existing_iostd $port]
        }
        lappend lines "${port},${pin},${iostd}"
        incr n
    }
}

set new_content [join $lines "\n"]
append new_content "\n"

# ---------- 4. 与旧内容比对，仅在不一致时写入 ----------
set old_content ""
if {[file exists $csv_path]} {
    set fp [open $csv_path r]
    set old_content [read $fp]
    close $fp
    set old_content [string map {"\r\n" "\n" "\r" "\n"} $old_content]
}

if {$new_content eq $old_content} {
    puts "==> pins.csv 与顶层端口一致，无需更新（$n 个引脚）"
} else {
    set fp [open $csv_path w]
    puts -nonewline $fp $new_content
    close $fp
    puts "==> 已更新 $csv_path（$n 个引脚）"
    puts "      编辑该文件填入实际引脚后，运行：make synth"
}

