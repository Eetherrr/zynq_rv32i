set root_dir $::env(VIVADOPRJ_ROOT)
set prj_name $::env(VIVADOPRJ_NAME)
set device   $::env(VIVADOPRJ_DEVICE)
set top      $::env(VIVADOPRJ_TOP)
set tb_top   $::env(VIVADOPRJ_TB)

set prj_dir  $root_dir/prj
set xpr_path $prj_dir/$prj_name.xpr

# ---- 从 pins.csv 生成 pins.xdc ----
proc gen_pins_xdc {root_dir} {
    set csv_path $root_dir/constrs/pins.csv
    set xdc_path $root_dir/constrs/pins.xdc

    if {![file exists $csv_path]} {
        # 无 CSV 则删除可能残留的 XDC，避免旧约束生效
        if {[file exists $xdc_path]} { file delete $xdc_path }
        return 0
    }

    set fp [open $csv_path r]
    set raw [read $fp]
    close $fp
    set raw [string map {"\r\n" "\n" "\r" "\n"} $raw]
    set lines [split $raw "\n"]

    set out [open $xdc_path w]
    puts $out "# ============================================================"
    puts $out "#  pins.xdc — 由 vivadoprj 从 pins.csv 自动生成"
    puts $out "#  请勿手动编辑；修改引脚请编辑 constrs/pins.csv"
    puts $out "# ============================================================"
    puts $out ""

    set lineno 0
    set added 0
    set skipped 0

    foreach line $lines {
        incr lineno
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[string index $line 0] eq "#"} { continue }

        set fields [split $line ","]
        set port [string trim [lindex $fields 0]]

        # 跳过表头
        if {[string match -nocase "port*" $port]} { continue }

        if {$port eq "" || [llength $fields] < 2} {
            puts "警告：pins.csv 第 $lineno 行格式错误，已跳过"
            incr skipped
            continue
        }

        set pin [string trim [lindex $fields 1]]
        if {[llength $fields] >= 3} {
            set iostd [string trim [lindex $fields 2]]
        } else {
            set iostd ""
        }

        if {$pin eq "" || [string match -nocase "TODO*" $pin]} {
            puts $out "# 未分配引脚：$port"
            incr skipped
            continue
        }

        if {$iostd eq ""} { set iostd "LVCMOS33" }

        puts $out "set_property PACKAGE_PIN $pin \[get_ports {$port}\]"
        puts $out "set_property IOSTANDARD $iostd \[get_ports {$port}\]"
        incr added
    }
    close $out
    puts "==> 已生成 $xdc_path（$added 条约束，$skipped 个跳过）"
    return $added
}

proc add_tree {fileset dir patterns} {
    if {![file isdirectory $dir]} { return }
    foreach pat $patterns {
        foreach f [glob -nocomplain -directory $dir -types f $pat] {
            add_files -fileset $fileset -norecurse $f
        }
    }
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        add_tree $fileset $sub $patterns
    }
}

# ---- 打开或新建工程 ----
if {[file exists $xpr_path]} {
    puts "==> 工程已存在，刷新源文件列表：$xpr_path"
    open_project $xpr_path
} else {
    puts "==> 新建工程：$xpr_path"
    create_project -force $prj_name $prj_dir -part $device
}

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# ---- 先生成 XDC，再添加约束文件（顺序很重要） ----
gen_pins_xdc $root_dir

# ---- RTL ----
add_tree sources_1 $root_dir/rtl {*.sv *.v *.svh *.vh}
foreach f [get_files -quiet -of_objects [get_filesets sources_1] *.sv] {
    set_property file_type SystemVerilog $f
}
foreach f [get_files -quiet -of_objects [get_filesets sources_1] *.svh] {
    set_property file_type SystemVerilog $f
}
foreach f [get_files -quiet -of_objects [get_filesets sources_1] *.vh] {
    set_property file_type {Verilog Header} $f
}

# ---- 约束 ----
if {[file isdirectory $root_dir/constrs]} {
    foreach xdc [glob -nocomplain -directory $root_dir/constrs *.xdc] {
        add_files -fileset constrs_1 -norecurse $xdc
    }
}

# ---- TB ----
add_tree sim_1 $root_dir/tb {*.sv *.v}
foreach f [get_files -quiet -of_objects [get_filesets sim_1] *.sv] {
    set_property file_type SystemVerilog $f
}

# ---- 顶层设置 ----
set found 0
foreach ext {sv v} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] ${top}.${ext}]] > 0} {
        set_property top $top [get_filesets sources_1]
        set found 1
        break
    }
}
if {!$found} {
    puts "提示：源码中暂未找到顶层模块 $top（可能还没有放入源文件）"
}

set found 0
foreach ext {sv v} {
    if {[llength [get_files -quiet -of_objects [get_filesets sim_1] ${tb_top}.${ext}]] > 0} {
        set_property top $tb_top [get_filesets sim_1]
        set found 1
        break
    }
}
if {!$found} {
    puts "提示：TB 中暂未找到顶层模块 $tb_top（可能还没有放入 TB 文件）"
}

# 仅在文件集非空时更新编译顺序，避免空工程下的 CRITICAL WARNING
if {[llength [get_files -quiet -of_objects [get_filesets sources_1]]] > 0} {
    update_compile_order -fileset sources_1
}
if {[llength [get_files -quiet -of_objects [get_filesets sim_1]]] > 0} {
    update_compile_order -fileset sim_1
}

close_project
puts "==> 工程准备完成：$xpr_path"

