// Reference march-test runner for the DRAM Bender sim harness.
//
//   ./march <test> [bank=1] [row0=0] [nrows=10]
//
// <test> is a name (marchc-, marchc, mats+, mats++) or march notation, e.g.
//   "a(w0);u(r0,w1);u(r1,w0);d(r0,w1);d(r1,w0);a(r0)"
//   a = either order (runs ascending), u = ascending, d = descending
// Address = (row, column burst); ascending means row-major, low to high.
// Data background is solid: w0 writes all-zero bursts, w1 all-one bursts.
//
// The oracle is a shadow memory: every read is checked against the last value
// written to that address, so mutated tests never need hand-fixed expected values.
// Env: SMC_FAULTS=<file> plants faults in the model and prints a per-fault report.
#include "instruction.h"
#include "prog.h"
#include "platform.h"
#include "tools.h"
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>
using namespace std;

#define CASR 0
#define BASR 1
#define RASR 2
static const float FPGA_PERIOD = 1.5015f;          // ns per DRAM clock
static const int NUM_COLS = 128;                    // 64-byte bursts per 8 KB row
static const int T_RCD = (int)ceil(13.5f / FPGA_PERIOD);
static const int T_RP  = (int)ceil(13.5f / FPGA_PERIOD);
static const int T_WR  = (int)ceil(15.0f / FPGA_PERIOD);
static const int RD_GAP = 8, WR_GAP = 16;           // conservative turnaround gaps (not checked by the model)

struct Op { bool rd; int val; };
struct Element { char order; vector<Op> ops; };    // order: 'a', 'u', 'd'

static map<string, string> KNOWN = {
  {"mats+",   "a(w0);u(r0,w1);d(r1,w0)"},
  {"mats++",  "a(w0);u(r0,w1);d(r1,w0,r0)"},
  {"marchc-", "a(w0);u(r0,w1);u(r1,w0);d(r0,w1);d(r1,w0);a(r0)"},
  {"marchc",  "a(w0);u(r0,w1);u(r1,w0);a(r0);d(r0,w1);d(r1,w0);a(r0)"},
};

vector<Element> parse_march(const string &spec) {
  vector<Element> t; stringstream ss(spec); string el;
  while (getline(ss, el, ';')) {
    size_t lp = el.find('('), rp = el.find(')');
    if (lp == string::npos || rp == string::npos || lp == 0) { cerr << "bad element: " << el << "\n"; exit(2); }
    Element e; e.order = el[lp - 1];
    if (e.order != 'a' && e.order != 'u' && e.order != 'd') { cerr << "bad order in: " << el << "\n"; exit(2); }
    stringstream os(el.substr(lp + 1, rp - lp - 1)); string op;
    while (getline(os, op, ',')) {
      if (op.size() != 2 || (op[0] != 'r' && op[0] != 'w') || (op[1] != '0' && op[1] != '1')) { cerr << "bad op: " << op << "\n"; exit(2); }
      e.ops.push_back({op[0] == 'r', op[1] - '0'});
    }
    t.push_back(e);
  }
  return t;
}

// rows/columns visited by one element, in order
vector<pair<int,int>> addr_order(const Element &e, int row0, int nrows) {
  vector<pair<int,int>> v;
  for (int j = 0; j < nrows; j++) for (int i = 0; i < NUM_COLS; i++) v.push_back({row0 + j, i});
  if (e.order == 'd') reverse(v.begin(), v.end());
  return v;
}

void load_wide(Program &p, int reg_tmp, int val) {
  for (int pos = 0; pos < 16; pos++) {
    p.add_inst(SMC_LI(val ? 0xFFFFFFFF : 0, reg_tmp));
    p.add_inst(SMC_LDWD(reg_tmp, pos));
  }
}

Program build(const vector<Element> &t, int bank, int row0, int nrows) {
  enum { R_BANK = 3, R_ROW, R_COL, R_I, R_NCOLS, R_J, R_NROWS, R_TMP };
  Program p;
  add_op_with_delay(p, SMC_PRE(0, 0, 1), 0, T_RP);          // precharge all
  for (size_t k = 0; k < t.size(); k++) {
    const Element &e = t[k];
    set<int> wvals; for (auto &o : e.ops) if (!o.rd) wvals.insert(o.val);
    bool reload_each = wvals.size() > 1;
    if (wvals.size() == 1) load_wide(p, R_TMP, *wvals.begin());
    bool down = e.order == 'd';
    p.add_inst(SMC_LI(bank, R_BANK));
    p.add_inst(SMC_LI(nrows, R_NROWS));
    p.add_inst(SMC_LI(NUM_COLS, R_NCOLS));
    p.add_inst(SMC_LI(0, R_J));
    p.add_inst(SMC_LI(down ? row0 + nrows - 1 : row0, R_ROW));
    string lrow = createSMCLabel("MROW"), lcol = createSMCLabel("MCOL");
    p.add_label(lrow);
    add_op_with_delay(p, SMC_ACT(R_BANK, 0, R_ROW, 0), 0, T_RCD);
    p.add_inst(SMC_LI(down ? (NUM_COLS - 1) * 8 : 0, R_COL));
    p.add_inst(SMC_LI(0, R_I));
    p.add_label(lcol);
    for (auto &o : e.ops) {
      if (o.rd) add_op_with_delay(p, SMC_READ(R_BANK, 0, R_COL, 0, 0, 0), 0, RD_GAP);
      else {
        if (reload_each) load_wide(p, R_TMP, o.val);
        add_op_with_delay(p, SMC_WRITE(R_BANK, 0, R_COL, 0, 0, 0), 0, WR_GAP);
      }
    }
    p.add_inst(down ? SMC_SUBI(R_COL, 8, R_COL) : SMC_ADDI(R_COL, 8, R_COL));
    p.add_inst(SMC_ADDI(R_I, 1, R_I));
    p.add_branch(Program::BR_TYPE::BL, R_I, R_NCOLS, lcol);
    add_op_with_delay(p, SMC_PRE(R_BANK, 0, 0), T_WR + WR_GAP, T_RP);
    p.add_inst(down ? SMC_SUBI(R_ROW, 1, R_ROW) : SMC_ADDI(R_ROW, 1, R_ROW));
    p.add_inst(SMC_ADDI(R_J, 1, R_J));
    p.add_branch(Program::BR_TYPE::BL, R_J, R_NROWS, lrow);
  }
  p.add_inst(all_nops());
  p.add_inst(SMC_END());
  return p;
}

struct Fault { string kind, line; int b = -1, r = -1, c = -1, bit = -1, r2 = -1; };

vector<Fault> read_faults(const char *path) {
  vector<Fault> v; if (!path) return v;
  ifstream in(path); string line;
  while (getline(in, line)) {
    stringstream ss(line); Fault f; f.line = line;
    if (!(ss >> f.kind) || f.kind[0] == '#') continue;
    if (f.kind == "SA0" || f.kind == "SA1" || f.kind == "TFD" || f.kind == "TFU") ss >> f.b >> f.r >> f.c >> f.bit;
    else if (f.kind == "CFID") { string d; int val, x; ss >> d >> val >> x >> x >> x >> x >> f.b >> f.r >> f.c >> f.bit; }
    else if (f.kind == "CFIN") { string d; int x; ss >> d >> x >> x >> x >> x >> f.b >> f.r >> f.c >> f.bit; }
    else if (f.kind == "AF") ss >> f.b >> f.r >> f.r2;
    else continue;
    v.push_back(f);
  }
  return v;
}

int main(int argc, char **argv) {
  if (argc < 2) { cerr << "usage: " << argv[0] << " <test|notation> [bank=1] [row0=0] [nrows=10]\n"; return 1; }
  string name = argv[1];
  string spec = KNOWN.count(name) ? KNOWN[name] : name;
  int bank  = argc > 2 ? atoi(argv[2]) : 1;
  int row0  = argc > 3 ? atoi(argv[3]) : 0;
  int nrows = argc > 4 ? atoi(argv[4]) : 10;
  vector<Element> t = parse_march(spec);

  Program prog = build(t, bank, row0, nrows);
  SoftMCPlatform platform;
  platform.init();
  platform.execute(prog);

  // expected read sequence + shadow-memory oracle, in program order
  map<pair<int,int>, int> shadow;                          // (row, col) -> last value written
  struct Fail { int elem, op, row, col, bit, exp, got; };
  vector<Fail> fails; set<tuple<int,int,int>> bad_cells;
  long reads = 0, bad_reads = 0, inconsistent = 0;
  vector<uint32_t> w(16);
  for (size_t k = 0; k < t.size(); k++)
    for (auto [row, col] : addr_order(t[k], row0, nrows))
      for (size_t o = 0; o < t[k].ops.size(); o++) {
        const Op &op = t[k].ops[o];
        if (!op.rd) { shadow[{row, col}] = op.val; continue; }
        platform.receiveData(w.data(), 64); reads++;
        auto it = shadow.find({row, col});
        if (it == shadow.end()) continue;                    // read before any write: nothing to check
        int exp = it->second;
        if (exp != op.val) inconsistent++;                   // test says rX but shadow says otherwise
        bool any = false;
        for (int bit = 0; bit < 512; bit++) {
          int got = (w[bit / 32] >> (bit % 32)) & 1;
          if (got != exp) {
            any = true;
            fails.push_back({(int)k, (int)o, row, col * 8, bit, exp, got});
            bad_cells.insert({row, col * 8, bit});
          }
        }
        if (any) bad_reads++;
      }

  FILE *csv = fopen("march_mismatches.csv", "w");
  fprintf(csv, "test,element,op,bank,row,col,bit,expected,got\n");
  for (auto &f : fails) fprintf(csv, "%s,%d,%d,%d,%d,%d,%d,%d,%d\n", name.c_str(), f.elem, f.op, bank, f.row, f.col, f.bit, f.exp, f.got);
  fclose(csv);

  cout << "test:        " << name << "  {" << spec << "}\n";
  cout << "range:       bank " << bank << ", rows " << row0 << ".." << row0 + nrows - 1 << ", all " << NUM_COLS << " bursts\n";
  cout << "reads:       " << reads << " checked, " << bad_reads << " mismatching, " << bad_cells.size() << " distinct failing cells\n";
  cout << "timing:      " << platform.violations << " violations\n";
  if (inconsistent) cout << "note:        " << inconsistent << " reads expected a value the test never wrote there (oracle used the shadow value)\n";
  set<tuple<int,int,int>> printed;
  for (auto &f : fails)
    if (printed.insert({f.row, f.col, f.bit}).second && printed.size() <= 10)
      cout << "  FAIL row " << f.row << " col " << f.col << " bit " << f.bit << ": expected " << f.exp << " got " << f.got
           << "  (first seen element " << f.elem << " op " << f.op << ")\n";

  if (bad_cells.size() > 10) cout << "  ... full list in march_mismatches.csv\n";
  vector<Fault> faults = read_faults(getenv("SMC_FAULTS"));
  if (!faults.empty()) {
    cout << "planted faults:\n";
    int det = 0;
    for (auto &f : faults) {
      bool hit = false, in_range;
      if (f.kind == "AF") {
        in_range = f.b == bank && f.r >= row0 && f.r < row0 + nrows;
        for (auto &c : bad_cells) if (get<0>(c) == f.r || get<0>(c) == f.r2) hit = true;
      } else {
        in_range = f.b == bank && f.r >= row0 && f.r < row0 + nrows;
        hit = bad_cells.count({f.r, f.c, f.bit}) > 0;
      }
      det += hit;
      cout << "  " << (hit ? "DETECTED " : (in_range ? "MISSED   " : "OUT-RANGE")) << "  " << f.line << "\n";
    }
    cout << "detected " << det << "/" << faults.size() << "\n";
  }
  return 0;
}
