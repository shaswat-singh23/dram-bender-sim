#!/usr/bin/env python3
"""Program-agnostic memory oracle for the DRAM Bender sim harness.

Reads the op trace written by tb_sim.sv (+TRACE=<file>) and checks every read
against the last value the program wrote to that address (shadow memory).
Works for any program: March tests, generated tests, hand-written ones.

  python3 check_trace.py trace.txt [--faults faults.txt] [--csv mismatches.csv]

With --faults it prints DETECTED / MISSED for each planted fault, using the same
rules as march.cpp: a cell fault (or a coupling fault's victim) is detected if
that exact cell ever reads back wrong; an address-decoder fault is detected if
any cell in either aliased row reads back wrong.
"""
import argparse
import sys


def parse_faults(path):
    faults = []
    for line in open(path):
        tok = line.split('#', 1)[0].split()
        if not tok:
            continue
        kind = tok[0]
        f = {'kind': kind, 'line': line.rstrip('\n')}
        try:
            if kind in ('SA0', 'SA1', 'TFD', 'TFU'):
                f['b'], f['r'], f['c'], f['bit'] = map(int, tok[1:5])
            elif kind == 'CFID':      # CFID dir val  ab ar ac abit  vb vr vc vbit
                f['b'], f['r'], f['c'], f['bit'] = map(int, tok[7:11])
            elif kind == 'CFIN':      # CFIN dir      ab ar ac abit  vb vr vc vbit
                f['b'], f['r'], f['c'], f['bit'] = map(int, tok[6:10])
            elif kind == 'AF':        # AF bank from to
                f['b'], f['r'], f['r2'] = map(int, tok[1:4])
            else:
                continue
        except ValueError:
            print(f"skipping malformed fault line: {line.rstrip()}", file=sys.stderr)
            continue
        faults.append(f)
    return faults


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace')
    ap.add_argument('--faults')
    ap.add_argument('--csv', default='trace_mismatches.csv')
    a = ap.parse_args()

    shadow = {}                      # (bank, row, col) -> 512-bit int last written
    touched = set()                  # (bank, row) the program accessed
    reads = bad_reads = unchecked = 0
    bad_cells = {}                   # (bank, row, col, bit) -> (expected, got, op index)
    with open(a.trace) as f, open(a.csv, 'w') as out:
        out.write('op_index,bank,row,col,bit,expected,got\n')
        for i, line in enumerate(f):
            p = line.split()
            if len(p) != 5:
                continue
            op, b, r, c = p[0], int(p[1]), int(p[2]), int(p[3])
            touched.add((b, r))
            if 'x' in p[4].lower() or 'z' in p[4].lower():
                val = None           # Icarus X/Z: treat as unknown
            else:
                val = int(p[4], 16)
            if op == 'W':
                shadow[(b, r, c)] = val
                continue
            reads += 1
            exp = shadow.get((b, r, c))
            if exp is None or val is None:
                unchecked += 1
                continue
            diff = exp ^ val
            if diff:
                bad_reads += 1
                while diff:
                    low = diff & -diff
                    bit = low.bit_length() - 1
                    e, g = (exp >> bit) & 1, (val >> bit) & 1
                    out.write(f'{i},{b},{r},{c},{bit},{e},{g}\n')
                    bad_cells.setdefault((b, r, c, bit), (e, g, i))
                    diff ^= low

    print(f"reads:   {reads} ({unchecked} unchecked: read before any write)")
    print(f"result:  {bad_reads} mismatching reads, {len(bad_cells)} distinct failing cells")
    for (b, r, c, bit), (e, g, i) in sorted(bad_cells.items(), key=lambda kv: kv[1][2])[:10]:
        print(f"  FAIL bank {b} row {r} col {c} bit {bit}: expected {e} got {g} (first at op {i})")
    if len(bad_cells) > 10:
        print(f"  ... full list in {a.csv}")

    if a.faults:
        faults = parse_faults(a.faults)
        failing_rows = {(b, r) for (b, r, c, bit) in bad_cells}
        det = 0
        print("planted faults:")
        for f in faults:
            if f['kind'] == 'AF':
                hit = (f['b'], f['r']) in failing_rows or (f['b'], f['r2']) in failing_rows
                reach = (f['b'], f['r']) in touched
            else:
                hit = (f['b'], f['r'], f['c'], f['bit']) in bad_cells
                reach = (f['b'], f['r'], f['c']) in shadow
            det += hit
            tag = 'DETECTED ' if hit else ('MISSED   ' if reach else 'NOT-TOUCHED')
            print(f"  {tag}  {f['line']}")
        print(f"detected {det}/{len(faults)}")


if __name__ == '__main__':
    main()
