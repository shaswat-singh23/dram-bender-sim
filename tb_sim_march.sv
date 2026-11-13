`timescale 1ns/1ps
`include "parameters.vh"
// DRAM Bender pipeline + behavioral memory + optional March C- checker.
// Run with +MARCH_CMINUS +MARCH_N=8 and a matching program.hex.
// Optional fault injection: +STUCK0_COL=3 forces bit 17 to zero
// for bank 0, row 0, burst column 3 after every write.
module tb_sim;
  localparam NROW_MODEL = 64;
  localparam NBURST     = 128;
  localparam T_RCD = 9, T_RAS = 24, T_RP = 9;

  reg clk = 0, rst = 1;
  always #3 clk = ~clk;

  reg [63:0] imem [0:2047];
  wire [`IMEM_ADDR_WIDTH-1:0] addr_out;
  wire valid_out;
  reg [63:0] data_in = 0;
  reg valid_in = 0;
  reg [`IMEM_ADDR_WIDTH-1:0] addr_in = 0;
  always @(posedge clk) begin
    valid_in <= valid_out & ~rst;
    data_in  <= imem[addr_out];
    addr_in  <= addr_out;
  end

  wire softmc_end;
  wire [11:0] read_size;
  wire read_seq_incoming;
  wire [3:0] ddr_write, ddr_read, ddr_pre, ddr_act, ddr_ref, ddr_sre, ddr_srx,
             ddr_zq, ddr_nop, ddr_ap, ddr_pall, ddr_half_bl, ddr_rank;
  wire [4*`HBM_CH_WIDTH-1:0] hbm_ch;
  wire [4*`BG_WIDTH-1:0] ddr_bg;
  wire [4*`BANK_WIDTH-1:0] ddr_bank;
  wire [4*`COL_WIDTH-1:0] ddr_col;
  wire [4*`ROW_WIDTH-1:0] ddr_row;
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
    .ddr_col(ddr_col), .ddr_row(ddr_row), .ddr_wdata(ddr_wdata)
  );

  reg [511:0] mem [0:16*NROW_MODEL*NBURST-1];
  integer disturb [0:16*NROW_MODEL-1];
  integer open_row [0:15];
  longint t_act [0:15], t_pre [0:15];
  integer hc_first, fd_out, n_act, n_rd, n_wr, n_viol, n_flips;
  longint cyc;
  string prog_file, out_file;

  // March configuration: one bank and one row, consecutive 64-byte bursts.
  bit march_en;
  integer march_n, march_bank, march_row, march_col0;
  integer march_phase, march_pos, march_sub, march_ops, march_errors;
  integer stuck0_col;

  function automatic integer idx_row(input integer b, input integer r);
    idx_row = b*NROW_MODEL + r;
  endfunction

  function automatic integer idx_mem(input integer b, input integer r, input integer c);
    idx_mem = (b*NROW_MODEL + r)*NBURST + c;
  endfunction

  // Monitor commands emitted by DUT. This never directly drives memory.
  // Each March operation is a full 512-bit read or write.
  task automatic march_observe(
    input integer b,
    input integer r,
    input integer c,
    input bit is_write,
    input logic [511:0] value
  );
    integer expected_col, bad_bits, j;
    bit expected_write;
    logic [511:0] expected_data;
    begin
      if (march_en) begin
        if (march_phase >= 6) begin
          $display("MARCH ERROR: unexpected extra operation at b=%0d r=%0d c=%0d", b,r,c);
          march_errors++;
        end else begin
          expected_col = march_col0 +
            ((march_phase == 3 || march_phase == 4) ? (march_n-1-march_pos) : march_pos);
          expected_write = 1'b0;
          expected_data = '0;
          case (march_phase)
            0: begin expected_write = 1'b1; expected_data = '0; end       // w0
            1,3: begin expected_write = (march_sub == 1);
                        expected_data = march_sub ? '1 : '0; end       // r0,w1
            2,4: begin expected_write = (march_sub == 1);
                        expected_data = march_sub ? '0 : '1; end       // r1,w0
            5: begin expected_write = 1'b0; expected_data = '0; end   // r0
          endcase

          if (b != march_bank || r != march_row || c != expected_col ||
              is_write != expected_write) begin
            $display("MARCH ORDER ERROR phase=%0d addr_pos=%0d sub=%0d expected bank=%0d row=%0d col=%0d %s, got bank=%0d row=%0d col=%0d %s",
                     march_phase, march_pos, march_sub,
                     march_bank, march_row, expected_col,
                     expected_write ? "WRITE" : "READ", b,r,c,
                     is_write ? "WRITE" : "READ");
            march_errors++;
          end
          if (value !== expected_data) begin
            bad_bits = 0;
            for (j = 0; j < 512; j++)
              if (value[j] !== expected_data[j]) bad_bits++;
            $display("MARCH DATA ERROR phase=%0d bank=%0d row=%0d col=%0d op=%s mismatched_bits=%0d low_word_got=%08h expected=%08h",
                     march_phase,b,r,c,is_write ? "WRITE" : "READ",
                     bad_bits,value[31:0],expected_data[31:0]);
            march_errors++;
          end

          march_ops++;
          if (march_phase >= 1 && march_phase <= 4) begin
            if (march_sub == 0) march_sub = 1;
            else begin march_sub = 0; march_pos++; end
          end else march_pos++;
          if (march_pos == march_n) begin
            $display("MARCH phase M%0d complete", march_phase);
            march_phase++;
            march_pos = 0;
          end
        end
      end
    end
  endtask

  task automatic disturb_row(input integer b, input integer r);
    integer k, c, bit_i, h;
    begin
      if (r >= 0 && r < NROW_MODEL) begin
        disturb[idx_row(b,r)] += 1;
        if (disturb[idx_row(b,r)] % hc_first == 0) begin
          for (k = 0; k < 8; k++) begin
            h = (r*7919 + b*104729 + (disturb[idx_row(b,r)]/hc_first)*31 + k*2654435) & 32'h7fffffff;
            c = h % NBURST;
            bit_i = (h / NBURST) % 512;
            if (mem[idx_mem(b,r,c)][bit_i] === 1'b1) begin
              mem[idx_mem(b,r,c)][bit_i] = 1'b0;
              n_flips++;
            end
          end
        end
      end
    end
  endtask

  task automatic do_cmd(input integer s);
    integer b, r, c, i;
    longint t;
    begin
      t = cyc*4 + s;
      b = {ddr_bg[s*`BG_WIDTH +: `BG_WIDTH], ddr_bank[s*`BANK_WIDTH +: `BANK_WIDTH]};
      r = ddr_row[s*`ROW_WIDTH +: `ROW_WIDTH];
      c = ddr_col[s*`COL_WIDTH +: `COL_WIDTH] >> 3;
      if (b < 0 || b >= 16) begin
        $display("PROTOCOL: bank out of range %0d", b);
        n_viol++;
      end else begin
        if (ddr_act[s]) begin
          if (open_row[b] != -1) begin
            $display("[%0t] PROTOCOL: ACT to open bank %0d",$time,b); n_viol++;
          end
          if (t - t_pre[b] < T_RP) begin
            $display("[%0t] TIMING: tRP violated bank %0d",$time,b); n_viol++;
          end
          open_row[b] = r;
          t_act[b] = t;
          n_act++;
          if (r < NROW_MODEL) disturb[idx_row(b,r)] = 0;
          disturb_row(b,r-1);
          disturb_row(b,r+1);
        end
        if (ddr_pre[s] || ddr_pall[s]) begin
          for (i = 0; i < 16; i++) begin
            if ((ddr_pall[s] || i == b) && open_row[i] != -1) begin
              if (t - t_act[i] < T_RAS) begin
                $display("[%0t] TIMING: tRAS violated bank %0d",$time,i); n_viol++;
              end
              open_row[i] = -1;
              t_pre[i] = t;
            end
          end
        end
        if (ddr_write[s] || ddr_read[s]) begin
          if (open_row[b] == -1) begin
            $display("[%0t] PROTOCOL: RD/WR to closed bank %0d",$time,b); n_viol++;
          end else if (t-t_act[b] < T_RCD) begin
            $display("[%0t] TIMING: tRCD violated bank %0d",$time,b); n_viol++;
          end
          if (open_row[b] >= 0 && open_row[b] < NROW_MODEL) begin
            if (c < 0 || c >= NBURST) begin
              $display("PROTOCOL: burst column out of range %0d", c); n_viol++;
            end else if (ddr_write[s]) begin
              // Check the intended write data BEFORE injecting physical faults.
              march_observe(b,open_row[b],c,1'b1,ddr_wdata);
              mem[idx_mem(b,open_row[b],c)] = ddr_wdata;
              if (b == 0 && open_row[b] == 0 && c == stuck0_col)
                mem[idx_mem(b,open_row[b],c)][17] = 1'b0;
              n_wr++;
            end else begin
              // Check actual stored data BEFORE writing the usual readout file.
              march_observe(b,open_row[b],c,1'b0,mem[idx_mem(b,open_row[b],c)]);
              for (i = 0; i < 16; i++)
                $fwrite(fd_out,"%08h\n",mem[idx_mem(b,open_row[b],c)][32*i +: 32]);
              n_rd++;
            end
          end
        end
        if (ddr_ref[s])
          for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
      end
    end
  endtask

  integer s, i;
  initial begin
    if (!$value$plusargs("PROG=%s", prog_file)) prog_file = "program.hex";
    if (!$value$plusargs("OUT=%s",  out_file))  out_file  = "readout.hex";
    if (!$value$plusargs("HC_FIRST=%d", hc_first)) hc_first = 1500;
    if (hc_first <= 0) $fatal(1,"HC_FIRST must be positive");

    march_en = $test$plusargs("MARCH_CMINUS");
    if (!$value$plusargs("MARCH_N=%d",march_n)) march_n=8;
    if (!$value$plusargs("MARCH_BANK=%d",march_bank)) march_bank=0;
    if (!$value$plusargs("MARCH_ROW=%d",march_row)) march_row=0;
    if (!$value$plusargs("MARCH_COL0=%d",march_col0)) march_col0=0;
    if (!$value$plusargs("STUCK0_COL=%d",stuck0_col)) stuck0_col=-1;
    if (march_en && (march_n < 1 || march_col0 < 0 || march_col0+march_n > NBURST ||
                     march_row < 0 || march_row >= NROW_MODEL ||
                     march_bank < 0 || march_bank >= 16))
      $fatal(1,"Invalid March test region");
    march_phase=0; march_pos=0; march_sub=0; march_ops=0; march_errors=0;

    for (i = 0; i < 2048; i++) imem[i] = 0;
    $readmemh(prog_file, imem);
    for (i = 0; i < 16*NROW_MODEL; i++) disturb[i] = 0;
    for (i = 0; i < 16; i++) begin open_row[i] = -1; t_act[i]=-1000; t_pre[i]=-1000; end
    n_act=0; n_rd=0; n_wr=0; n_viol=0; n_flips=0; cyc=0;
    fd_out=$fopen(out_file,"w");
    if (!fd_out) $fatal(1,"Could not open output file");
    #60 rst=0;
  end

  always @(posedge clk) if (!rst) begin
    for (s=0;s<4;s++) do_cmd(s);
    cyc++;
    if (softmc_end || cyc > 5_000_000) begin
      $display("SIM_DONE cycles=%0d ACT=%0d WR=%0d RD=%0d violations=%0d injected_flips=%0d%s",
               cyc,n_act,n_wr,n_rd,n_viol,n_flips,softmc_end ? "" : " (TIMEOUT)");
      if (march_en) begin
        $display("MARCH_CMINUS summary phases=%0d/6 operations=%0d/%0d errors=%0d",
                 march_phase,march_ops,10*march_n,march_errors);
        if (march_phase == 6 && march_ops == 10*march_n &&
            march_errors == 0 && n_viol == 0 && softmc_end)
          $display("MARCH_CMINUS PASS");
        else begin
          $display("MARCH_CMINUS FAIL");
          $fclose(fd_out);
          $fatal(1,"March C- failure");
        end
      end
      $fclose(fd_out);
      $finish;
    end
  end
endmodule
