#  常用目标：
#    make              等价于 bitstream
#    make pins         从顶层模块生成 / 更新 constrs/pins.csv
#    make refresh      刷新源文件列表（含从 pins.csv 生成 pins.xdc）
#    make project      仅在 .xpr 不存在时创建 Vivado 工程
#    make check        非工程模式的 RTL 语法 / 详细阐述检查
#    make tb           非工程模式运行 tb/ 下的测试平台（xsim）
#    make synth        综合
#    make impl         实现
#    make bitstream    综合 + 实现 + Bitstream
#    make sim          仿真 (WAVE=0 输出 VCD, WAVE=1 波形查看器)
#    make gui          打开 Vivado GUI
#    make clean        清理仿真产物
#    make distclean    清理所有产物（含 Vivado 工程）
#
#  引脚约束工作流：
#    make pins   →  编辑 constrs/pins.csv 填引脚  →  make synth

# ---------------- 可覆盖变量 ----------------
VIVADO     ?= vivado
PRJ_NAME   := zynq_rv32i
DEVICE     ?= xc7z010clg400-1
TOP        ?= CPU_SOC_top
TB_TOP     ?= tb_top
TB         ?= tb_rib_periph
WAVE       ?= 0
JOBS       ?= 8
SIM_RUN    ?= all

# ---------------- 目录 ----------------
ROOT       := $(CURDIR)
PRJ_DIR    := $(ROOT)/prj
SCRIPT_DIR := $(ROOT)/scripts
SIM_DIR    := $(ROOT)/sim
CONSTR_DIR := $(ROOT)/constrs
XPR        := $(PRJ_DIR)/$(PRJ_NAME).xpr
BIT        := $(PRJ_DIR)/$(PRJ_NAME).runs/impl_1/$(TOP).bit
VCD        := $(SIM_DIR)/waveform.vcd
PINS_CSV   := $(CONSTR_DIR)/pins.csv
PINS_XDC   := $(CONSTR_DIR)/pins.xdc

# ---------------- 传给 TCL 的环境变量 ----------------
export VIVADOPRJ_ROOT   := $(ROOT)
export VIVADOPRJ_NAME   := $(PRJ_NAME)
export VIVADOPRJ_DEVICE := $(DEVICE)
export VIVADOPRJ_TOP    := $(TOP)
export VIVADOPRJ_TB     := $(TB_TOP)
export VIVADOPRJ_WAVE   := $(WAVE)
export VIVADOPRJ_JOBS   := $(JOBS)
export VIVADOPRJ_SIMRUN := $(SIM_RUN)
export TB               := $(TB)

.PHONY: all project refresh synth impl bitstream sim gui pins slang check tb clean distclean help

all: bitstream

# ---- 创建工程（仅当 .xpr 不存在时） ----
project:
	@if [ ! -f $(XPR) ]; then \
		echo "==> 创建 Vivado 工程：$(PRJ_NAME)"; \
		$(VIVADO) -mode batch -source $(SCRIPT_DIR)/create_project.tcl \
		          -nolog -nojournal; \
	else \
		echo "==> Vivado 工程已存在"; \
	fi

# ---- 刷新源文件列表 + 从 pins.csv 生成 pins.xdc ----
refresh:
	@echo "==> 刷新源文件列表"
	@$(VIVADO) -mode batch -source $(SCRIPT_DIR)/create_project.tcl \
	          -nolog -nojournal

# ---- 从顶层模块生成 / 更新 pins.csv ----
pins: refresh
	@echo "==> 从顶层模块生成 / 更新 pins.csv"
	@$(VIVADO) -mode batch -source $(SCRIPT_DIR)/gen_pins_csv.tcl \
	          -nolog -nojournal

# ---- 综合 / 实现 / Bitstream（先 refresh 再跑） ----
synth: refresh
	@echo "==> 运行综合 (jobs=$(JOBS))"
	$(VIVADO) -mode batch -source $(SCRIPT_DIR)/build.tcl \
	          -tclargs synth -nolog -nojournal

impl: refresh
	@echo "==> 运行实现 (jobs=$(JOBS))"
	$(VIVADO) -mode batch -source $(SCRIPT_DIR)/build.tcl \
	          -tclargs impl -nolog -nojournal

bitstream: refresh
	@echo "==> 综合 + 实现 + 生成 Bitstream"
	$(VIVADO) -mode batch -source $(SCRIPT_DIR)/build.tcl \
	          -tclargs bit -nolog -nojournal

# ---- 仿真：先 refresh 再根据 WAVE 选择 batch/gui ----
sim: refresh
	@if [ "$(WAVE)" = "1" ]; then \
		echo "==> 启动仿真并打开波形查看器..."; \
		$(VIVADO) -mode gui -source $(SCRIPT_DIR)/sim.tcl; \
	else \
		echo "==> 运行仿真并输出 VCD：$(VCD)"; \
		$(VIVADO) -mode batch -source $(SCRIPT_DIR)/sim.tcl \
		          -nolog -nojournal; \
	fi

# ---- 打开 GUI ----
gui:
	@echo "==> 打开 Vivado GUI"
	@cd $(PRJ_DIR) && $(VIVADO) $(PRJ_NAME).xpr &

# ---- 生成 .slang/server.json（供 slang-server LSP 使用） ----
slang:
	@echo "==> 生成 .slang/server.json"
	@$(VIVADO) -mode batch -source $(SCRIPT_DIR)/gen_slang_config.tcl \
	          -nolog -nojournal

# ---- RTL 语法 / 详细阐述检查（不依赖 Vivado 工程） ----
check:
	@echo "==> RTL 检查（顶层 $(TOP)）"
	$(VIVADO) -mode batch -source $(SCRIPT_DIR)/check_rtl.tcl \
	          -nolog -nojournal

# ---- 非工程模式运行测试平台（xsim） ----
tb:
	@echo "==> 运行测试平台：$(TB)"
	$(VIVADO) -mode batch -source $(SCRIPT_DIR)/run_tb.tcl \
	          -nolog -nojournal

# ---- 清理 ----
clean:
	@rm -rf $(SIM_DIR)/*.vcd $(SIM_DIR)/*.wdb $(SIM_DIR)/*.log
	@rm -rf $(ROOT)/*.jou $(ROOT)/*.log $(ROOT)/.Xil
	@rm -rf $(ROOT)/xsim.dir $(ROOT)/*.wdb $(ROOT)/*.pb
	@rm -rf $(SIM_DIR)/xsim_run
	@echo "==> 已清理仿真产物"

distclean: clean
	@rm -rf $(PRJ_DIR)
	@echo "==> 已清理 Vivado 工程"

help:
	@echo "可用的 make 目标："
	@echo "  all        默认，等价于 bitstream"
	@echo "  pins       从顶层模块生成 / 更新 constrs/pins.csv"
	@echo "  refresh    刷新源文件列表并从 pins.csv 生成 pins.xdc"
	@echo "  project    仅在 .xpr 不存在时创建工程"
	@echo "  check      非工程模式的 RTL 语法 / 详细阐述检查"
	@echo "  tb         非工程模式运行测试平台 (TB=tb_rib_periph)"
	@echo "  synth      综合"
	@echo "  impl       实现"
	@echo "  bitstream  综合 + 实现 + 生成 bitstream"
	@echo "  sim        仿真（WAVE=0 输出 VCD，WAVE=1 打开波形查看器）"
	@echo "  gui        打开 Vivado GUI"
	@echo "  slang      生成 .slang/server.json（供 LSP 使用）"
	@echo "  clean      清理仿真产物"
	@echo "  distclean  清理所有产物（含 Vivado 工程）"
	@echo ""
	@echo "引脚约束工作流："
	@echo "  make pins  生成模板 → 编辑 constrs/pins.csv 填引脚 → make synth"
