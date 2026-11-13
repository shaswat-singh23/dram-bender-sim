
#!/usr/bin/env bash

# Exit if a command fails, a variable is undefined,
# or a command in a pipeline fails.
set -euo pipefail

# Move into the directory containing this script.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Read arguments or use default values.
BURSTS="${1:-8}"
SIMULATOR="${2:-icarus}"
STUCK_COL="${3:--1}"
HC_FIRST="${4:-1500}"

# Display the selected test configuration.
echo "Running March C-:"
echo "  Bursts: $BURSTS"
echo "  Simulator: $SIMULATOR"
echo "  Stuck-at-0 column: $STUCK_COL"
echo "  HC_FIRST: $HC_FIRST"

# Currently configured for Icarus Verilog.
if [[ "$SIMULATOR" != "icarus" ]]; then
    echo "ERROR: Only Icarus is supported by this script."
    exit 1
fi

# STEP 1: Compile March C- components if necessary.
# This does not run the simulation.
echo "Compiling March C-..."
make marchc_gen tb_sim_march.vvp

# STEP 2: Generate the DRAM Bender instruction program.
echo "Generating March C- instructions..."
./marchc_gen "$BURSTS"

# STEP 3: Execute the compiled RTL simulation.
# Save console output to sim_march.log.
echo "Executing March C- simulation..."

# Temporarily disable automatic error exit to capture
# the simulator's return status.
set +e

vvp ./tb_sim_march.vvp \
    +PROG=program.hex \
    +OUT=readout_march.hex \
    +MARCH_CMINUS \
    +MARCH_N="$BURSTS" \
    +HC_FIRST="$HC_FIRST" \
    +STUCK0_COL="$STUCK_COL" \
    2>&1 | tee sim_march.log

# Capture the simulator exit code.
SIM_STATUS=${PIPESTATUS[0]}

set -e

# STEP 4: Verify the simulation result.
echo
echo "========== VERIFICATION =========="

# Check that the simulation reached its completion summary.
if ! grep -q '^SIM_DONE' sim_march.log; then
    echo "ERROR: Simulation did not finish normally."
    exit 1
fi

# Verify that no protocol or timing violations occurred.
if ! grep -Eq 'violations=0([[:space:]]|$)' sim_march.log; then
    echo "ERROR: Protocol or timing violations detected."
    exit 1
fi

# Normal test: expect zero errors and a passing result.
if [[ "$STUCK_COL" == "-1" ]]; then

    if [[ "$SIM_STATUS" -eq 0 ]] &&
       grep -q '^MARCH_CMINUS PASS' sim_march.log; then
        echo "SUCCESS: March C- passed."
    else
        echo "ERROR: March C- failed."
        exit 1
    fi

# Fault-injection test: expect the March checker to fail.
else

    if grep -q '^MARCH_CMINUS FAIL' sim_march.log &&
       grep -q '^MARCH DATA ERROR' sim_march.log; then
        echo "SUCCESS: March C- detected the injected fault."
    else
        echo "ERROR: Expected fault was not detected."
        exit 1
    fi
fi

# STEP 5: Report generated files.
echo
echo "Simulation log: sim_march.log"
echo "Read data: readout_march.hex"
echo "=================================="
