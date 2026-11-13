`timescale 1ns/1ps
`include "parameters.vh"
// Simulation harness for DRAM Bender's softmc_pipeline.
// - Emulates the frontend's instruction memory (program loaded from +PROG=<hex>)
// - Feeds the 4-slot DDR command bus into a behavioral DDR4 bank model
// - Model has a read-disturbance fault model (+HC_FIRST) and a JEDEC timing checker
// - READ data is dumped to +OUT=<hex> as 16 x 32-bit words per burst (word 0 first)
module tb_sim;
  localparam NROW_MODEL = 64;          // rows modeled per bank (rows >= this are ignored)
  localparam NBURST     = 128;         // 8KB row / 64B burst
  // JEDEC DDR4-1333 style timing in DRAM clocks (tCK = 1.5 ns)
  localparam T_RCD = 9, T_RAS = 24, T_RP = 9;

  reg clk = 0, rst = 1;
  always #3 clk = ~clk;                // 6 ns fabric clock (4:1 to DRAM clock)

  // ---------------- instruction memory (frontend stand-in) ----------------
  reg [63:0] imem [0:2047];
  wire [`IMEM_ADDR_WIDTH-1:0] addr_out;
  wire valid_out;
  reg  [63:0] data_in = 0;
  reg  valid_in = 0;
  reg  [`IMEM_ADDR_WIDTH-1:0] addr_in = 0;
  always @(posedge clk) begin
    valid_in <= valid_out & ~rst;
    data_in  <= imem[addr_out];
    addr_in  <= addr_out;
  end

  wire softmc_end;
  wire [11:0] read_size; wire read_seq_incoming;
  wire [3:0] ddr_write, ddr_read, ddr_pre, ddr_act, ddr_ref, ddr_sre, ddr_srx,
             ddr_zq, ddr_nop, ddr_ap, ddr_pall, ddr_half_bl, ddr_rank;
  wire [4*`HBM_CH_WIDTH-1:0] hbm_ch;
  wire [4*`BG_WIDTH-1:0]   ddr_bg;
  wire [4*`BANK_WIDTH-1:0] ddr_bank;
  wire [4*`COL_WIDTH-1:0]  ddr_col;
  wire [4*`ROW_WIDTH-1:0]  ddr_row;
  wire [511:0] ddr_wdata;

  softmc_pipeline dut(
    .clk(clk), .rst(rst), .softmc_end(softmc_end),
    .read_size(read_size), .read_seq_incoming(read_seq_incoming),
    .buffer_space(12'hFFF),
    .addr_out(addr_out), .valid_out(valid_out),
    .data_in(data_in), .valid_in(valid_in), .addr_in(addr_in), .ready_out(~rst),
    .ddr_write(ddr_write), .ddr_read(ddr_read), .ddr_pre(ddr_pre), .ddr_act(ddr_act),
    .ddr_ref(ddr_ref), .ddr_sre(ddr_sre), .ddr_srx(ddr_srx), .ddr_zq(ddr_zq),
    .ddr_nop(ddr_nop), .ddr_ap(ddr_ap), .ddr_pall(ddr_pall), .ddr_half_bl(ddr_half_bl),
    .ddr_rank(ddr_rank), .hbm_ch(hbm_ch), .ddr_bg(ddr_bg), .ddr_bank(ddr_bank),
    .ddr_col(ddr_col), .ddr_row(ddr_row), .ddr_wdata(ddr_wdata));

  // ---------------- behavioral DDR4 model ----------------
  reg [511:0] mem     [0:16*NROW_MODEL*NBURST-1];
  integer     disturb [0:16*NROW_MODEL-1];   // aggressor ACTs seen by each row since its last ACT/REF
  integer     open_row[0:15];
  longint     t_act [0:15], t_pre [0:15];
  integer     hc_first, fd_out, n_act, n_rd, n_wr, n_viol, n_flips;
  longint     cyc;
  string      prog_file, out_file;

  function automatic integer idx_row(input integer b, input integer r); idx_row = b*NROW_MODEL + r; endfunction
  function automatic integer idx_mem(input integer b, input integer r, input integer c); idx_mem = (b*NROW_MODEL + r)*NBURST + c; endfunction

  // Read-disturb fault model: each time a victim's count crosses a multiple of
  // hc_first, flip 8 hash-selected charged cells (1 -> 0, true-cell convention).
  task automatic disturb_row(input integer b, input integer r);
    integer k, c, bit_i, h;
    if (r >= 0 && r < NROW_MODEL) begin
    disturb[idx_row(b,r)] += 1;
    if (disturb[idx_row(b,r)] % hc_first == 0) begin
      for (k = 0; k < 8; k++) begin
        h = (r*7919 + b*104729 + (disturb[idx_row(b,r)]/hc_first)*31 + k*2654435) & 32'h7fffffff;
        c = h % NBURST; bit_i = (h / NBURST) % 512;
        if (mem[idx_mem(b,r,c)][bit_i] === 1'b1) begin
          mem[idx_mem(b,r,c)][bit_i] = 1'b0; n_flips++;
        end
      end
    end
    end
  endtask

  // ---------------- planted classic memory faults (+FAULTS=<file>) ----------------
  // One fault per line ('#' = comment). col is a DRAM Bender column address (0..1016, step 8),
  // bit is 0..511 within that 64-byte burst.
  //   SA0  bank row col bit           stuck-at-0
  //   SA1  bank row col bit           stuck-at-1
  //   TFD  bank row col bit           down-transition fault: cell cannot go 1 -> 0
  //   TFU  bank row col bit           up-transition fault:   cell cannot go 0 -> 1
  //   CFID up|down val  ab ar ac abit  vb vr vc vbit   idempotent coupling: aggressor transition forces victim to val
  //   CFIN up|down      ab ar ac abit  vb vr vc vbit   inversion coupling: aggressor transition inverts victim
  //   AF   bank from_row to_row       address-decoder fault: RD/WR to from_row land in to_row
  localparam MAXF = 64;
  localparam F_SA0=1, F_SA1=2, F_TFD=3, F_TFU=4, F_CFID=5, F_CFIN=6, F_AF=7;
  integer f_type[0:MAXF-1], f_up[0:MAXF-1], f_val[0:MAXF-1];
  integer f_b[0:MAXF-1], f_r[0:MAXF-1], f_c[0:MAXF-1], f_bit[0:MAXF-1];      // victim / target cell
  integer a_b[0:MAXF-1], a_r[0:MAXF-1], a_c[0:MAXF-1], a_bit[0:MAXF-1];      // aggressor cell
  integer n_faults, n_cf_fired;
  string  fault_file;
  // optional op trace (+TRACE=<file>): one line per RD/WR as seen by the program
  //   W bank row col <512-bit intended data, hex>     R bank row col <512-bit returned data, hex>
  // (row/col are the addresses the program used, before any address-decoder fault)
  integer fd_trace;
  string  trace_file;

  task automatic load_faults();
    integer fd, n; string kind, dir;
`ifdef VERILATOR
    string line;                 // (Verilator build) sscanf on a reg stops at leading NULs
`else
    reg [8*256-1:0] line;        // (Icarus build) fgets needs a reg
`endif
    integer x0, x1, x2, x3, x4, x5, x6, x7, x8;
    n_faults = 0; fd = 0;
    if ($value$plusargs("FAULTS=%s", fault_file)) begin
    fd = $fopen(fault_file, "r");
    if (fd == 0) $display("FAULTS: cannot open %s", fault_file);
    end
    if (fd != 0) begin
    while (!$feof(fd) && n_faults < MAXF) begin
`ifdef VERILATOR
      line = "";
`else
      line = 0;
`endif
      n = $fgets(line, fd);
      kind = "";
      if (n > 0) n = $sscanf(line, "%s", kind);
      if (n > 0 && kind.len() > 0 && kind.substr(0,0) != "#") begin   // skip blank lines and '#' comments
      f_type[n_faults] = 0;
      if (kind == "SA0" || kind == "SA1" || kind == "TFD" || kind == "TFU") begin
        if ($sscanf(line, "%s %d %d %d %d", kind, x0, x1, x2, x3) == 5) begin
          f_type[n_faults] = (kind == "SA0") ? F_SA0 : (kind == "SA1") ? F_SA1 : (kind == "TFD") ? F_TFD : F_TFU;
          f_b[n_faults] = x0; f_r[n_faults] = x1; f_c[n_faults] = x2 >> 3; f_bit[n_faults] = x3;
        end
      end else if (kind == "CFID") begin
        if ($sscanf(line, "%s %s %d %d %d %d %d %d %d %d %d", kind, dir, x8, x0, x1, x2, x3, x4, x5, x6, x7) == 11) begin
          f_type[n_faults] = F_CFID; f_up[n_faults] = (dir == "up"); f_val[n_faults] = x8;
          a_b[n_faults] = x0; a_r[n_faults] = x1; a_c[n_faults] = x2 >> 3; a_bit[n_faults] = x3;
          f_b[n_faults] = x4; f_r[n_faults] = x5; f_c[n_faults] = x6 >> 3; f_bit[n_faults] = x7;
        end
      end else if (kind == "CFIN") begin
        if ($sscanf(line, "%s %s %d %d %d %d %d %d %d %d", kind, dir, x0, x1, x2, x3, x4, x5, x6, x7) == 10) begin
          f_type[n_faults] = F_CFIN; f_up[n_faults] = (dir == "up");
          a_b[n_faults] = x0; a_r[n_faults] = x1; a_c[n_faults] = x2 >> 3; a_bit[n_faults] = x3;
          f_b[n_faults] = x4; f_r[n_faults] = x5; f_c[n_faults] = x6 >> 3; f_bit[n_faults] = x7;
        end
      end else if (kind == "AF") begin
        if ($sscanf(line, "%s %d %d %d", kind, x0, x1, x2) == 4) begin
          f_type[n_faults] = F_AF; f_b[n_faults] = x0; f_r[n_faults] = x1; f_val[n_faults] = x2;
        end
      end
      if (f_type[n_faults] != 0) n_faults++;
      else $display("FAULTS: skipped malformed line: %s", line);
      end
    end
    $fclose(fd);
    $display("FAULTS: loaded %0d from %s", n_faults, fault_file);
    end
  endtask

  // address-decoder fault: which physical row an access to (b, r) really reaches
  function automatic integer phys_row(input integer b, input integer r);
    integer k; phys_row = r;
    for (k = 0; k < n_faults; k++)
      if (f_type[k] == F_AF && f_b[k] == b && f_r[k] == r) phys_row = f_val[k];
  endfunction

  // enforce stuck-at cells of one burst
  function automatic [511:0] apply_sa(input integer b, input integer r, input integer c, input [511:0] d);
    integer k; apply_sa = d;
    for (k = 0; k < n_faults; k++)
      if (f_b[k] == b && f_r[k] == r && f_c[k] == c) begin
        if (f_type[k] == F_SA0) apply_sa[f_bit[k]] = 1'b0;
        if (f_type[k] == F_SA1) apply_sa[f_bit[k]] = 1'b1;
      end
  endfunction

  task automatic fault_write(input integer b, input integer r, input integer c, input [511:0] wdata);
    reg [511:0] oldv, newv; integer k, vi;
    oldv = mem[idx_mem(b,r,c)];
    newv = wdata;
    for (k = 0; k < n_faults; k++)
      if (f_b[k] == b && f_r[k] == r && f_c[k] == c) begin
        if (f_type[k] == F_TFD && oldv[f_bit[k]] === 1'b1 && newv[f_bit[k]] === 1'b0) newv[f_bit[k]] = 1'b1;
        if (f_type[k] == F_TFU && oldv[f_bit[k]] === 1'b0 && newv[f_bit[k]] === 1'b1) newv[f_bit[k]] = 1'b0;
      end
    newv = apply_sa(b, r, c, newv);
    mem[idx_mem(b,r,c)] = newv;
    // coupling faults triggered by a transition in this burst
    for (k = 0; k < n_faults; k++)
      if ((f_type[k] == F_CFID || f_type[k] == F_CFIN) && a_b[k] == b && a_r[k] == r && a_c[k] == c &&
          ((f_up[k]  && oldv[a_bit[k]] === 1'b0 && newv[a_bit[k]] === 1'b1) ||
           (!f_up[k] && oldv[a_bit[k]] === 1'b1 && newv[a_bit[k]] === 1'b0))) begin
        vi = idx_mem(f_b[k], f_r[k], f_c[k]);
        if (f_type[k] == F_CFID) mem[vi][f_bit[k]] = f_val[k][0];
        else                     mem[vi][f_bit[k]] = ~mem[vi][f_bit[k]];
        mem[vi] = apply_sa(f_b[k], f_r[k], f_c[k], mem[vi]);
        n_cf_fired++;
      end
  endtask

  task automatic do_cmd(input integer s);
    integer b, r, c, i, pr; longint t; reg [511:0] rd;
    t = cyc*4 + s;
    b = {ddr_bg[s*`BG_WIDTH +: `BG_WIDTH], ddr_bank[s*`BANK_WIDTH +: `BANK_WIDTH]};
    r = ddr_row[s*`ROW_WIDTH +: `ROW_WIDTH];
    c = ddr_col[s*`COL_WIDTH +: `COL_WIDTH] >> 3;
    if (ddr_act[s]) begin
      if (open_row[b] != -1) begin $display("[%0t] PROTOCOL: ACT to open bank %0d", $time, b); n_viol++; end
      if (t - t_pre[b] < T_RP) begin $display("[%0t] TIMING: tRP violated bank %0d (%0d < %0d)", $time, b, t-t_pre[b], T_RP); n_viol++; end
      open_row[b] = r; t_act[b] = t; n_act++;
      if (r < NROW_MODEL) disturb[idx_row(b,r)] = 0;   // activation restores the row's charge
      disturb_row(b, r-1); disturb_row(b, r+1);
    end
    if (ddr_pre[s] || ddr_pall[s]) begin
      for (i = 0; i < 16; i++) if ((ddr_pall[s] || i == b) && open_row[i] != -1) begin
        if (t - t_act[i] < T_RAS) begin $display("[%0t] TIMING: tRAS violated bank %0d (%0d < %0d)", $time, i, t-t_act[i], T_RAS); n_viol++; end
        open_row[i] = -1; t_pre[i] = t;
      end
    end
    if (ddr_write[s] || ddr_read[s]) begin
      if (open_row[b] == -1) begin $display("[%0t] PROTOCOL: RD/WR to closed bank %0d", $time, b); n_viol++; end
      else if (t - t_act[b] < T_RCD) begin $display("[%0t] TIMING: tRCD violated bank %0d (%0d < %0d)", $time, b, t-t_act[b], T_RCD); n_viol++; end
      if (open_row[b] >= 0 && open_row[b] < NROW_MODEL) begin
        pr = phys_row(b, open_row[b]);
        if (ddr_write[s]) begin
          fault_write(b, pr, c, ddr_wdata); n_wr++;
          if (fd_trace != 0) $fwrite(fd_trace, "W %0d %0d %0d %0128h\n", b, open_row[b], c*8, ddr_wdata);
        end else begin
          rd = apply_sa(b, pr, c, mem[idx_mem(b,pr,c)]);
          for (i = 0; i < 16; i++) $fwrite(fd_out, "%08h\n", rd[32*i +: 32]);
          if (fd_trace != 0) $fwrite(fd_trace, "R %0d %0d %0d %0128h\n", b, open_row[b], c*8, rd);
          n_rd++;
        end
      end
    end
    if (ddr_ref[s]) for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
  endtask

  integer s, i;
  initial begin
    if (!$value$plusargs("PROG=%s", prog_file)) prog_file = "program.hex";
    if (!$value$plusargs("OUT=%s",  out_file))  out_file  = "readout.hex";
    if (!$value$plusargs("HC_FIRST=%d", hc_first)) hc_first = 1500;
    for (i = 0; i < 2048; i++) imem[i] = 0;
    $readmemh(prog_file, imem);
    for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
    for (i = 0; i < 16; i++) begin open_row[i] = -1; t_act[i] = -1000; t_pre[i] = -1000; end
    n_act = 0; n_rd = 0; n_wr = 0; n_viol = 0; n_flips = 0; cyc = 0; n_cf_fired = 0;
    load_faults();
    fd_out = $fopen(out_file, "w");
    fd_trace = 0;
    if ($value$plusargs("TRACE=%s", trace_file)) fd_trace = $fopen(trace_file, "w");
    #60 rst = 0;
  end

  always @(posedge clk) if (!rst) begin
    for (s = 0; s < 4; s++) do_cmd(s);
    cyc++;
    if (softmc_end || cyc > 5_000_000) begin
      $display("SIM_DONE cycles=%0d ACT=%0d WR=%0d RD=%0d violations=%0d injected_flips=%0d faults=%0d cf_fired=%0d%s",
               cyc, n_act, n_wr, n_rd, n_viol, n_flips, n_faults, n_cf_fired, softmc_end ? "" : " (TIMEOUT)");
      $fclose(fd_out); if (fd_trace != 0) $fclose(fd_trace); $finish;
    end
  end
endmodule
