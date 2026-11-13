// March C- program generator for the DRAM Bender instruction.cpp API.
// Build from the repository root:
//   g++ -std=c++11 -Isources/api marchc_gen.cpp sources/api/instruction.cpp -o marchc_gen
// Generates 64-bit hexadecimal words compatible with tb_sim's $readmemh.
// This unrolled example tests 8 bursts in bank 0, row 0; modify N to sweep.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "instruction.h"

static std::vector<Inst> p;
static const int REG_BANK=1, REG_ROW=2, REG_COL=3, REG_DATA=4;

static Inst nops() {
  return __pack_mininsts(SMC_NOP(), SMC_NOP(), SMC_NOP(), SMC_NOP());
}
static void idle(int cycles=8) {
  for(int i=0;i<cycles;i++) p.push_back(nops());
}
static void cmd(Mininst mi) {
  p.push_back(__pack_mininsts(mi, SMC_NOP(), SMC_NOP(), SMC_NOP()));
}
static void set_wdata(uint32_t pattern) {
  p.push_back(SMC_LI(pattern, REG_DATA));
  idle(4);
  for(int i=0;i<16;i++) p.push_back(SMC_LDWD(REG_DATA,i));
  idle(4);
}
static void access_burst(int col_burst, bool write) {
  // DDR column is a multiple of eight; model divides by 8.
  p.push_back(SMC_LI(static_cast<uint32_t>(col_burst*8),REG_COL));
  idle(4); // allow register update to reach DDR command stage
  if(write) cmd(SMC_WRITE(REG_BANK,0,REG_COL,0,0,0));
  else      cmd(SMC_READ (REG_BANK,0,REG_COL,0,0,0));
  idle(8);  // conservative separation, not a replacement for full JEDEC checks
}

int main(int argc,char**argv) {
  int N = (argc > 1) ? std::atoi(argv[1]) : 8;
  if(N < 1 || N > 128) { std::fprintf(stderr,"N must be 1..128\n"); return 1; }
  p.push_back(SMC_LI(0,REG_BANK));
  p.push_back(SMC_LI(0,REG_ROW));
  idle(8);
  cmd(SMC_ACT(REG_BANK,0,REG_ROW,0,0));
  idle(8); // > tRCD=9 DRAM clocks (2.25 fabric cycles)

  // M0: ascending (w0)
  set_wdata(0x00000000u);
  for(int a=0;a<N;a++) access_burst(a,true);

  // M1: ascending (r0,w1)
  set_wdata(0xffffffffu);
  for(int a=0;a<N;a++) { access_burst(a,false); access_burst(a,true); }

  // M2: ascending (r1,w0)
  set_wdata(0x00000000u);
  for(int a=0;a<N;a++) { access_burst(a,false); access_burst(a,true); }

  // M3: descending (r0,w1)
  set_wdata(0xffffffffu);
  for(int a=N-1;a>=0;a--) { access_burst(a,false); access_burst(a,true); }

  // M4: descending (r1,w0)
  set_wdata(0x00000000u);
  for(int a=N-1;a>=0;a--) { access_burst(a,false); access_burst(a,true); }

  // M5: ascending (r0)
  for(int a=0;a<N;a++) access_burst(a,false);
  cmd(SMC_PRE(REG_BANK,0,0,0));
  idle(8);
  p.push_back(SMC_END());

  if(p.size() > 2048) {
    std::fprintf(stderr,"Program needs %zu instructions, exceeds 2048-word imem. Reduce N or add loops.\n",p.size());
    return 1;
  }
  FILE* f=std::fopen("program.hex","w");
  if(!f) { std::perror("program.hex"); return 1; }
  for(Inst x:p) std::fprintf(f,"%016llx\n", static_cast<unsigned long long>(x));
  std::fclose(f);
  std::printf("Wrote program.hex (%zu instructions, %d bursts, %d March operations)\n",
              p.size(),N,10*N);
  return 0;
}
