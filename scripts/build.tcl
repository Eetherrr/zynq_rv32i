# ============================================================
#  build.tcl — 综合 / 实现 / Bitstream
#  用法: vivado -mode batch -source build.tcl -tclargs <stage>
#        stage ∈ {synth, impl, bit}
# ============================================================

set root_dir $::env(VIVADOPRJ_ROOT)
set prj_name $::env(VIVADOPRJ_NAME)
set jobs     $::env(VIVADOPRJ_JOBS)

set stage [lindex $argv 0]
if {$stage eq ""} { set stage "bit" }

if {![string is integer -strict $jobs] || $jobs < 1} { set jobs 8 }

open_project $root_dir/prj/$prj_name.xpr

# ---- 综合 ----
if {$stage eq "synth" || $stage eq "impl" || $stage eq "bit"} {
    puts "==> 综合 (jobs=$jobs)"
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "综合失败"
    }
    puts "==> 综合完成"
}

# ---- 实现 ----
if {$stage eq "impl" || $stage eq "bit"} {
    puts "==> 实现 (jobs=$jobs)"
    reset_run impl_1
    if {$stage eq "bit"} {
        launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    } else {
        launch_runs impl_1 -jobs $jobs
    }
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "实现失败"
    }
    puts "==> 实现完成"
}

close_project
puts "==> build.tcl 结束（stage=$stage）"
