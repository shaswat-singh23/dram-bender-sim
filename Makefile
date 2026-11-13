
# DRAM Bender RTL sim harness (no FPGA needed)
# Usage: make run                 rowhammer case study (Icarus, 4-state, slow)
#        make run-verilator       rowhammer case study (Verilator, ~90x faster)
#        make march TEST=marchc-  reference march runner on a clean fake RAM
#        make march-faults        reference runner with faults_example.txt planted
#        make ladder              MATS+ vs MATS++ vs March C- per planted fault
#        make marchc-faults       marchc_gen's March C- graded against faults_row0.txt
#        make marchc-each         same, one planted fault at a time

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
TEST ?= marchc-
FAULTS ?= faults_example.txt

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
# Planted faults + march tests
# ============================================================

march_bin: march.cpp sim_shim/platform.h
	g++ -std=c++17 -O1 -w -o march -I sim_shim -I $(API) -I $(CS1) march.cpp $(API)/prog.cpp $(API)/instruction.cpp

march: vobj/Vtb_sim march_bin
	SMC_SIM_CMD=./vobj/Vtb_sim SMC_QUIET=1 ./march $(TEST)

march-faults: vobj/Vtb_sim march_bin
	SMC_SIM_CMD=./vobj/Vtb_sim SMC_QUIET=1 SMC_FAULTS=$(FAULTS) ./march $(TEST)

ladder: vobj/Vtb_sim march_bin
	./ladder.sh $(FAULTS)

marchc-faults: vobj/Vtb_sim marchc_gen
	./run_march_faults.sh faults_row0.txt 8 verilator

marchc-each: vobj/Vtb_sim marchc_gen
	./run_march_faults.sh faults_row0.txt 8 verilator --each

# ============================================================
# Cleanup
# ============================================================

clean:
	rm -rf tb_sim.vvp run_cs1 vobj vbuild.log program.hex readout.hex sim_run.log cs1_results.txt marchc_gen tb_sim_march.vvp \
	  march march_mismatches.csv readout_march.hex sim_march.log sim_march_faults.log trace_march.txt march_trace_mismatches.csv trace_mismatches.csv

.PHONY: all run run-verilator march march-faults ladder marchc-faults marchc-each clean
