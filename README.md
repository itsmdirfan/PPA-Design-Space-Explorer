<h1 align="center">PPA Design Space Explorer</h1>
<p align="center">
  <b>Automated Multi-Corner Synthesis Exploration Using Bash and TCL</b><br>
  Synopsys Design Compiler &nbsp;·&nbsp; SAED 14nm FinFET &nbsp;·&nbsp; Fast-Fast · Typical · Slow-Slow
</p>

---

## Overview

PPA Design Space Explorer is an automation tool for VLSI logic synthesis
that systematically explores the Power, Performance, and Area tradeoff
of any single-clock RTL design across three standard cell library corners
without any manual intervention between runs.

The user provides one Verilog source file and a top module name.
The tool handles everything else — generating synthesis scripts,
running Design Compiler, parsing reports, adapting step sizes,
detecting convergence, performing clock gating analysis, and
producing a structured final recommendation report.

---

## Features

- **Three-corner automation** — Fast-Fast, Typical-Typical, and Slow-Slow
  PVT corners run sequentially with no manual steps between them
- **Smart adaptive jump** — uses `ceil(|WNS|)` to skip large timing
  violations in a single synthesis run instead of stepping one-by-one
- **FF Trackback** — after timing is first met in the Fast-Fast corner,
  steps back in 0.1 ns increments to find the tightest passing period
- **Area convergence** — Typical-Typical sweep continues past timing
  closure and stops automatically when area change drops below 2%
  for two consecutive runs
- **Power convergence** — Slow-Slow sweep applies the same 2% rule
  to power, ensuring the sweep continues as long as meaningful
  reduction is being achieved
- **Clock gating analysis** — an additional synthesis pass at the best
  Slow-Slow power period using CG cells quantifies power reduction
  from automatic clock gating insertion
- **Structured final report** — `FINAL_SUMMARY.rpt` gives explicit
  recommendations for Max Speed, Best Area, Best Power, Best Power
  with Clock Gating, and Best Tradeoff

---

---

## How It Works

### Clock Period Sweep

The tool always starts at 1 ns. If WNS at that period is heavily
negative, the smart jump computes:
next_period = current_period + ceil(|WNS|)

This skips redundant iterations in a single step. Once WNS is
within 1 ns of the target, regular +1 ns steps are used.

### FF Trackback

After Fast-Fast timing is first met (e.g. at 12 ns with WNS = 0.15 ns),
the tool steps backward at 0.1 ns resolution to find the tightest
clock period that still satisfies `WNS >= TARGET_SLACK`.
12.0 ns  WNS = 0.15  ✓
11.9 ns  WNS = 0.13  ✓  new best
11.8 ns  WNS = 0.12  ✓  new best
11.7 ns  WNS = 0.11  ✓  new best  ← final result
11.6 ns  WNS = 0.08  ✗  violated — stop

### Convergence Detection

For both area (TT) and power (SS), the tool computes:
change = |prev - current| / prev

If `change < 2%` for two consecutive runs, the sweep stops.
This ensures the tool continues only while meaningful improvement
is still being achieved.

### Clock Gating

At the best Slow-Slow power period, one additional synthesis run
is performed with the CG cell library added and
`compile_ultra -gate_clock` enabled. Design Compiler
automatically inserts ICG cells on idle registers.
No RTL modification is required.

---

## Future Scope

- Multi-clock domain support
- Hold timing integration
- HVT and LVT variant comparison
- Low-voltage corner support for IoT applications
- HTML report with embedded PPA charts
- Direct handoff to Innovus or ICC2 for Place and Route
