// Drop-in replacement for DRAM Bender's api/platform.h.
// Same SoftMCPlatform interface the apps use, but execute() runs the RTL
// simulation (softmc_pipeline + behavioral DDR4 model) instead of XDMA.
#pragma once
#include "prog.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <iostream>

#define SOFTMC_SUCCESS 0
#define SOFTMC_ERR -1

class SoftMCPlatform {
  std::vector<uint32_t> rx;   // words captured from simulated READs
  size_t rx_pos = 0;
 public:
  // simulator command: Icarus by default, e.g. SMC_SIM_CMD=./vobj/Vtb_sim for Verilator
  std::string sim = getenv("SMC_SIM_CMD") ? getenv("SMC_SIM_CMD") : "vvp -n tb_sim.vvp";
  std::string hc_first = getenv("SMC_HC_FIRST") ? getenv("SMC_HC_FIRST") : "1500";
  int  runs = 0;
  int  violations = 0;        // timing/protocol violations reported by the last run
  std::string last_done;      // last SIM_DONE line
  int  init() { return SOFTMC_SUCCESS; }
  void reset_fpga() {}
  void set_aref(bool) {}      // sim model has no auto-refresh unless the program issues REF

  void execute(Program &prog) {
    uint64_t *iseq = (uint64_t *)prog.get_inst_array();
    int n = prog.size() / 8;
    FILE *f = fopen("program.hex", "w");
    for (int i = 0; i < n; i++) fprintf(f, "%016llx\n", (unsigned long long)iseq[i]);
    fclose(f);
    free(iseq);
    std::string cmd = sim + " +PROG=program.hex +OUT=readout.hex +HC_FIRST=" + hc_first;
    if (getenv("SMC_FAULTS")) cmd += std::string(" +FAULTS=") + getenv("SMC_FAULTS");  // planted faults file
    cmd += " > sim_run.log 2>&1";
    if (system(cmd.c_str()) != 0) { std::cerr << "simulation failed, see sim_run.log\n"; exit(1); }
    std::ifstream log("sim_run.log"); std::string line;
    while (std::getline(log, line))
      if (line.rfind("SIM_DONE", 0) == 0 || line.rfind("FAULTS", 0) == 0 || line.find("TIMING") != std::string::npos) {
        if (line.rfind("SIM_DONE", 0) == 0) { last_done = line; violations = 0;
          size_t p = line.find("violations="); if (p != std::string::npos) violations = atoi(line.c_str() + p + 11); }
        if (!getenv("SMC_QUIET")) std::cerr << "[sim run " << runs << ", " << n << " insts] " << line << "\n";
      }
    runs++;
    rx.clear(); rx_pos = 0;
    std::ifstream in("readout.hex");
    while (std::getline(in, line)) if (!line.empty()) rx.push_back(strtoul(line.c_str(), nullptr, 16));
  }

  // size in bytes, like the real platform
  int receiveData(void *dst, int size) {
    uint32_t *d = (uint32_t *)dst; int words = size / 4;
    for (int i = 0; i < words; i++) d[i] = (rx_pos < rx.size()) ? rx[rx_pos++] : 0xDEADBEEF;
    return size;
  }
};
