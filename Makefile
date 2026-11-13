
# DRAM Bender RTL sim harness (no FPGA needed)
# Usage: make run               (Icarus, 4-state, slow)
#        make run-verilator     (Verilator, 2-state, faster)

DRAM_BENDER ?= ./DRAM-Bender
HDL  = $(DRAM_BENDER)/sources/hdl
API  = $(DRAM_BENDER)/sources/api
CS1  = $(DRAM_BENDER)/sources/apps/case_studies/cs1_interleaving_pattern

CORE = softmc_pipeline fetch_stage pre_decode decode_stage execute_stage \
       ddr_pipeline exe_pipeline register_file reg_mem pop_count4

RTL_CORE = $(addprefix $(HDL)/verilog/,$(addsuffix .v,$(CORE)))

RTL = tb_sim.sv stubs.v $(RTL_CORE)
MARCH_RTL = tb_sim_march.sv stubs.v $(RTL_CORE)

INC  = -I$(HDL)/header_verilog -I$(DRAM_BENDER)/projects/U200/verilog

ROWS ?= 3
HC_FIRST ?= 1500

# Compile original simulation and March C- components
all: tb_sim.vvp run_cs1 marchc_gen tb_sim_march.vvp

# ============================================================
# Original DRAM Bender compilation
# ============================================================

tb_sim.vvp: tb_sim.sv stubs.v
	iverilog -g2012 -o $@ $(subst -I,-I ,$(INC)) -s tb_sim $(RTL)

vobj/Vtb_sim: tb_sim.sv stubs.v
	verilator --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH \
	  -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN --top-module tb_sim $(INC) -Mdir vobj -o Vtb_sim $(RTL) -j 0 > vbuild.log

run_cs1: run_cs1.cpp sim_shim/platform.h
	g++ -std=c++17 -O1 -w -o $@ -I sim_shim -I $(API) -I $(CS1) run_cs1.cpp $(API)/prog.cpp $(API)/instruction.cpp

# ============================================================
# March C- compilation ONLY
# ============================================================

# Compile March C- C++ instruction generator
marchc_gen: marchc_gen.cpp $(API)/instruction.cpp $(API)/instruction.h
	g++ -std=c++11 -O2 -I$(API) marchc_gen.cpp $(API)/instruction.cpp -o marchc_gen

# Compile March C- SystemVerilog testbench
tb_sim_march.vvp: tb_sim_march.sv stubs.v
	iverilog -g2012 -o $@ $(subst -I,-I ,$(INC)) -s tb_sim $(MARCH_RTL)

# ============================================================
# Original DRAM Bender simulation execution
# ============================================================

run: all
	SMC_HC_FIRST=$(HC_FIRST) ./run_cs1 $(ROWS) && cat cs1_results.txt

run-verilator: vobj/Vtb_sim run_cs1
	SMC_SIM_CMD=./vobj/Vtb_sim SMC_HC_FIRST=$(HC_FIRST) ./run_cs1 $(ROWS) && cat cs1_results.txt

# ============================================================
# Cleanup
# ============================================================

clean:
	rm -rf tb_sim.vvp run_cs1 vobj vbuild.log program.hex readout.hex sim_run.log cs1_results.txt marchc_gen tb_sim_march.vvp
