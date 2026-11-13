# DRAM Bender sim harness

Runs DRAM Bender's own RTL (`softmc_pipeline`) and its unmodified C++ test programs with no FPGA. A behavioral DDR4 model with a read-disturbance fault model and a timing checker stands in for the PHY and DIMM.

```
program (DRAM Bender C++ API, unmodified)
  -> sim_shim/platform.h  (same SoftMCPlatform interface; execute() runs the sim)
  -> tb_sim.sv            (imem + DRAM Bender softmc_pipeline RTL)
  -> behavioral DDR4 model (data store, ACT-count fault model, tRCD/tRAS/tRP checker)
  -> READ data back to the program's own bitflip analysis
```

## Run
Needs g++ plus Icarus Verilog 12 and/or Verilator 5 (tested 5.020). The bundled `DRAM-Bender/` has the subset of sources needed.
```
make run ROWS=3 HC_FIRST=1500            # Icarus: 4-state (catches X), ~3.3 s/run
make run-verilator ROWS=3 HC_FIRST=1500  # Verilator: 2-state, ~0.04 s/run, same results
```

## Files
- `tb_sim.sv`: harness, instruction memory, and DDR4 model. Plusargs: `+PROG`, `+OUT`, `+HC_FIRST`.
- `stubs.v`: behavioral replacement for the `scratchpad` Block Memory IP (the only IP inside the pipeline).
- `sim_shim/platform.h`: drop-in for `api/platform.h`. Its `execute()` writes `program.hex`, runs `vvp`, and loads `readout.hex`.
- `run_cs1.cpp`: includes case study 1 (`test.cpp`) unchanged and only shrinks `NUM_ROWS`.

## Verified result (case study 1, VAVAV, 1000 hammers per aggressor, victim=0xFF.., aggressor=0x00..)
| HC_FIRST | flips per victim |
|---|---|
| 900  | 8 / 16 / 8 (edge victims single-sided, middle double-sided) |
| 1500 | 0 / 8 / 0 |
| 2500 | 0 / 0 / 0 |

Command counts match the program: 2008 ACT (2000 hammers + 5 init + 3 read), 640 WR, 384 RD, about 36k fabric cycles, about 4 s per run.

## Limits
- Not modeled: PHY, calibration, XDMA, frontend, readback engine, or maintenance controller (auto-refresh is off, same as `set_aref(false)`).
- The fault model is a placeholder: 8 hash-selected 1 to 0 flips per `HC_FIRST` crossing, with only ±1 neighbors. It has no RowPress (tAggON), no TRR, no retention model, no temperature dependence, and no data-pattern coupling beyond true cells.
- Only 64 rows per bank are modeled.
- The checker flags the first WRITE after each ACT at 8 vs 9 clocks for tRCD (init rows only). Either the case-study timing is one clock short, or the slot-to-DRAM-cycle mapping here is off. Confirm against the DDR4 PHY before trusting it.
- `wdata` word order assumes `ddr_wdata[32*i +: 32]` = wide-register word i. That isn't verified, and it only matters for non-uniform patterns.

## Next steps
1. Retention model: per-cell retention time and timestamps on write/ACT/REF. Run `apps/RetentionTest` through the shim.
2. RowPress: make the disturbance increment depend on how long the aggressor stays open (t_PRE - t_ACT).
3. A TRR stand-in, such as a sampler that refreshes neighbors of frequent aggressors on REF, to prototype U-TRR-style experiments.
4. For fuzzing: link the Verilator model into the C++ driver in-process (no per-run process or files), and add `--coverage` if the fuzzer is coverage-guided.
5. On real hardware, link against the real `api/platform.h`. The same programs run unchanged.

## Planted faults and march tests

`tb_sim.sv` can plant classic memory faults from a text file (`+FAULTS=<file>`, or `SMC_FAULTS=<file>` through the shim). Format and examples are in `faults_example.txt`:

| kind | meaning |
|---|---|
| `SA0` / `SA1` | cell stuck at 0 / 1 |
| `TFD` / `TFU` | cell cannot go 1->0 / 0->1 |
| `CFID up\|down val` | aggressor transition forces victim to `val` |
| `CFIN up\|down` | aggressor transition inverts victim |
| `AF bank from to` | address-decoder fault: accesses to row `from` land in row `to` |

`march.cpp` is a reference march runner. It takes a test name (`mats+`, `mats++`, `marchc-`, `marchc`) or march notation such as `"a(w0);u(r0,w1);d(r1,w0,r0)"` (a = any order, u = ascending, d = descending; solid data background). Its oracle is a shadow memory: each read is checked against the last value written to that address, so a mutated test never needs hand-fixed expected values. Mismatches go to `march_mismatches.csv` (element, op, row, col, bit, expected, got); with `SMC_FAULTS` set it also prints DETECTED / MISSED per planted fault.

```
make march TEST=marchc-          # clean RAM: expect 0 mismatching reads, 0 violations
make march-faults TEST=mats+     # 7/9 detected
make ladder                      # per-fault table below
```

Verified result (bank 1, rows 0-9, Verilator; Icarus output is bit-identical):

| planted fault | MATS+ | MATS++ | March C- |
|---|---|---|---|
| SA0, SA1, TFU, AF, 3 of 4 coupling faults | detected | detected | detected |
| TFD (cannot go 1->0) | **missed** | detected | detected |
| CFID up 0, aggressor below victim | **missed** | **missed** | detected |
| all 9 together | 7/9 | 8/9 | 9/9 |
| no faults | 0 mismatches | 0 mismatches | 0 mismatches |

This matches the textbook coverage: MATS+ never reads back its final write, MATS++ fixes that with one read, and only March C- has the extra elements that expose that coupling fault.

Limits: solid data backgrounds only; the model's timing checker covers tRCD/tRAS/tRP but not read/write turnaround (the runner leaves conservative gaps); the address-decoder fault floods the mismatch list with whole rows, by design.

To check your own march implementation: write it as notation and pass it to `./march`, or run your program through the shim with `SMC_FAULTS` set and compare its detections to the table above.

## Grading any program: op trace + `check_trace.py`

`tb_sim.sv` can log every read and write as the program saw it (`+TRACE=<file>`). `check_trace.py` replays that trace against a shadow memory, so it grades **any** program without knowing its structure: march tests, generated fuzzer programs, hand-written ones.

```
./vobj/Vtb_sim +PROG=program.hex +OUT=readout.hex +FAULTS=faults_row0.txt +TRACE=trace.txt
python3 check_trace.py trace.txt --faults faults_row0.txt
```

### `marchc_gen` (March C- generator) against planted faults

`marchc_gen` tests bank 0, row 0, bursts 0..N-1, so `faults_row0.txt` plants 8 faults in that region (no address-decoder fault, since it is a single row).

```
make marchc-faults     # all 8 planted together: expect "detected 8/8"
make marchc-each       # one fault at a time
```

Verified (Verilator, Icarus identical; clean RAM gives 0 mismatches and 0 timing violations):

| planted fault (bank 0, row 0) | marchc_gen March C- | reference MATS+ | reference MATS++ | reference March C- |
|---|---|---|---|---|
| SA0, SA1, TFU, 3 coupling faults | detected | detected | detected | detected |
| TFD (cannot go 1->0) | detected | **missed** | detected | detected |
| CFID up 0, aggressor below victim | detected | **missed** | **missed** | detected |

`run_march.sh` and `tb_sim_march.sv` (in-testbench March checker, `+STUCK0_COL`) still work unchanged; `tb_sim.sv` now covers the same fault injection through `+FAULTS`, so the two testbenches can be merged later.
