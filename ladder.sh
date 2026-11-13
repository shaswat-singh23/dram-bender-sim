#!/usr/bin/env bash
# Demo: plant each fault alone, run MATS+, MATS++ and March C-, print who catches what.
# Usage: ./ladder.sh [faults_file]     (needs: make vobj/Vtb_sim march)
F=${1:-faults_example.txt}
export SMC_SIM_CMD=${SMC_SIM_CMD:-./vobj/Vtb_sim} SMC_QUIET=1
tmp=$(mktemp -d); grep -v '^#' "$F" | grep -v '^\s*$' > "$tmp/all"
printf "%-44s %-9s %-9s %-9s\n" "planted fault (one at a time)" "MATS+" "MATS++" "MarchC-"
while IFS= read -r line; do
  echo "$line" > "$tmp/one"
  r=""; for t in mats+ mats++ marchc-; do
    o=$(SMC_FAULTS="$tmp/one" ./march $t | grep -E "^\s+(DETECTED|MISSED|OUT-RANGE)" | awk '{print $1}')
    r="$r $(printf '%-9s' "$o")"
  done
  printf "%-44s%s\n" "$(echo "$line" | sed 's/ *#.*//' | tr -s ' ' | cut -c1-43)" "$r"
done < "$tmp/all"
for t in mats+ mats++ marchc-; do printf "%-44s %s\n" "all together, $t" "$(SMC_FAULTS="$F" ./march $t | grep '^detected')"; done
for t in mats+ mats++ marchc-; do printf "%-44s %s\n" "no faults, $t" "$(./march $t | grep '^reads' | sed 's/reads: *//')"; done
rm -rf "$tmp"
