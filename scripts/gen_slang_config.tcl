# ============================================================
#  gen_slang_config.tcl
#  生成 .slang/server.json，供 slang-server LSP 分析整个项目
#
#  行为：
#    - 若 .slang/server.json 不存在 → 生成
#    - 若已存在 → 仅当顶层模块名变化时更新
#    - 自动收集 rtl/ 下所有目录作为 include 路径
# ============================================================

set root_dir $::env(VIVADOPRJ_ROOT)
set prj_name $::env(VIVADOPRJ_NAME)
set top      $::env(VIVADOPRJ_TOP)

set slang_dir  $root_dir/.slang
set slang_file $slang_dir/server.json

# ---------- 收集 RTL 目录作为 include 路径 ----------
proc collect_rtl_dirs {base} {
    set dirs [list]
    if {![file isdirectory $base]} { return $dirs }
    lappend dirs $base
    foreach sub [glob -nocomplain -directory $base -types d *] {
        set subdirs [collect_rtl_dirs $sub]
        foreach d $subdirs { lappend dirs $d }
    }
    return $dirs
}

set rtl_dir $root_dir/rtl
set rtl_dirs [collect_rtl_dirs $rtl_dir]

# 转为相对于项目根的路径
set rel_dirs [list]
foreach d $rtl_dirs {
    set rel [string trimleft [string map [list $root_dir/ ""] $d] /]
    if {$rel eq ""} { set rel "." }
    lappend rel_dirs $rel
}

# 去重并排序
set rel_dirs [lsort -unique $rel_dirs]

# ---------- 构建 JSON ----------
set json "{\n"
append json "  \"compilationOptions\": {\n"
append json "    \"topModules\": \[\"$top\"\],\n"
append json "    \"defines\": {},\n"
append json "    \"includePaths\": \["

set first 1
foreach d $rel_dirs {
    if {!$first} { append json ", " }
    append json "\"$d\""
    set first 0
}
append json "\]\n"
append json "  },\n"
append json "  \"index\": {\n"
append json "    \"dirs\": \[\"rtl\"\],\n"
append json "    \"excludeDirs\": \[\"build\", \"prj\", \".slang\", \".git\"\]\n"
append json "  },\n"
append json "  \"linting\": {\n"
append json "    \"enableAllWarnings\": false\n"
append json "  }\n"
append json "}\n"

# ---------- 检查是否需要写入 ----------
set need_write 1
if {[file exists $slang_file]} {
    set fp [open $slang_file r]
    set old [read $fp]
    close $fp
    if {$old eq $json} {
        set need_write 0
        puts "==> .slang/server.json 已是最新，无需更新"
    }
}

if {$need_write} {
    file mkdir $slang_dir
    set fp [open $slang_file w]
    puts -nonewline $fp $json
    close $fp
    puts "==> 已生成 $slang_file"
    puts "      slang-server 将自动识别项目结构"
}
