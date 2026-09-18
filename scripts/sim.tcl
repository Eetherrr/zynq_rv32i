# ============================================================
#  sim.tcl — 仿真
#  WAVE=1 → 打开波形查看器 (Vivado 以 -mode gui 启动)
#  WAVE=0 → 批处理运行并输出 VCD 到 sim/
# ============================================================

set root_dir $::env(VIVADOPRJ_ROOT)
set prj_name $::env(VIVADOPRJ_NAME)
set tb_top   $::env(VIVADOPRJ_TB)
set wave     $::env(VIVADOPRJ_WAVE)
set sim_run  $::env(VIVADOPRJ_SIMRUN)

set sim_dir  $root_dir/sim
set vcd_path $sim_dir/waveform.vcd

open_project $root_dir/prj/$prj_name.xpr

set_property top     $tb_top         [get_filesets sim_1]
set_property top_lib xil_defaultlib  [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {$sim_run} -objects [get_filesets sim_1]

if {$wave} {
    # ---------- GUI 模式 ----------
    puts "==> 打开波形查看器（Vivado GUI 模式）"
    launch_simulation
    # 不关闭工程，用户交互查看波形
} else {
    # ---------- 批处理模式：输出 VCD ----------
    puts "==> 运行仿真，VCD 输出到 $vcd_path"
    set_property -name {xsim.simulate.xsim.more_options} \
                 -value "-vcd $vcd_path" \
                 -objects [get_filesets sim_1]
    launch_simulation
    run $sim_run
    close_sim
    puts "==> VCD 文件：$vcd_path"
    close_project
}
