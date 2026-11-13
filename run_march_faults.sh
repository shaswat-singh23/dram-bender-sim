#!/usr/bin/env bash
# Grade marchc_gen's March C- program against planted faults.
#
#   ./run_march_faults.sh [faults_file=faults_row0.txt] [bursts=8] [sim=verilator|icarus] [--each]
#
# Runs the program on tb_sim.sv with +FAULTS and +TRACE, then check_trace.py
# grades every read against a shadow memory and reports DETECTED/MISSED per fault.
# --each plants one fault at a time (shows exactly which faults the test catches).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FAULTS="${1:-faults_row0.txt}"
BURSTS="${2:-8}"
SIM="${3:-verilator}"
EACH="${4:-}"

make -s marchc_gen
./marchc_gen "$BURSTS" > /dev/null
if [[ "$SIM" == "icarus" ]]; then make -s tb_sim.vvp; RUN="vvp -n tb_sim.vvp"
else make -s vobj/Vtb_sim; RUN="./vobj/Vtb_sim"; fi

run_one() {   # $1 = faults file
  $RUN +PROG=program.hex +OUT=readout_march.hex +FAULTS="$1" +TRACE=trace_march.txt > sim_march_faults.log 2>&1
  grep -q '^SIM_DONE' sim_march_faults.log || { echo "simulation did not finish, see sim_march_faults.log"; exit 1; }
}

if [[ "$EACH" == "--each" ]]; then
  tmp=$(mktemp -d); grep -v '^#' "$FAULTS" | grep -v '^\s*$' > "$tmp/all"
  while IFS= read -r line; do
    echo "$line" > "$tmp/one"; run_one "$tmp/one"
    tag=$(python3 check_trace.py trace_march.txt --faults "$tmp/one" --csv /dev/null | grep -E '^\s+(DETECTED|MISSED|NOT-TOUCHED)' | awk '{print $1}')
    printf "%-12s %s\n" "$tag" "$(echo "$line" | sed 's/ *#.*//' | tr -s ' ')"
  done < "$tmp/all"
  rm -rf "$tmp"
else
  run_one "$FAULTS"
  grep '^SIM_DONE' sim_march_faults.log
  python3 check_trace.py trace_march.txt --faults "$FAULTS" --csv march_trace_mismatches.csv
fi
