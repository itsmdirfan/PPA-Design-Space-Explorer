#!/usr/bin/env bash

# =====================================================================
# PPA Design Space Explorer
# Author : Md. Irfan
#
# Requirements:
#   - Synopsys Design Compiler installed
#   - SAED14nm library .db files in ./lib/
#   - Single Verilog file placed next to this script
#   - Single-clock designs supported
#
# Usage:
#   bash run.sh
#   (edit USER CONFIGURATION section below before running)
# =====================================================================

set -euo pipefail
IFS=$'\n\t'


# =====================================================================
#               USER CONFIGURATION — EDIT ONLY THIS SECTION
# =====================================================================

DESIGN_FILE="your_design.v"      # RTL file name (place it next to run.sh)
TOP_MODULE="your_top_module"      # top module name inside the .v file

DEFAULT_VLSI_PC=3                 # fallback PC number if auto-detect fails
DC_CSH_TEMPLATE="/home/vlsiXX/c2s/synopsys/cshrc.csh"  # XX auto-replaced

# ----------------------------------------------------------
#  CLOCK CONSTRAINTS — edit this block to add more constraints
#  CLK_UNCERTAINTY : setup/hold margin for jitter (ns)
#  CLK_TRANSITION  : max clock rise/fall slew (ns)
#  CLK_LATENCY     : source latency — leave "" to skip
#  INPUT/OUTPUT_DELAY_RATIO : I/O delay as fraction of clock period
# ----------------------------------------------------------
CLK_UNCERTAINTY="0.05"
CLK_TRANSITION="0.05"
CLK_LATENCY=""
INPUT_DELAY_RATIO="0.1"
OUTPUT_DELAY_RATIO="0.1"

# Target slack: sweep stops when WNS reaches this value (ns).
# FF trackback also stops when WNS just reaches this target.
# 0.1ns gives good headroom for later PnR stages.
TARGET_SLACK="0.1"

# =====================================================================


# =====================================================================
#                     VLSI PC AUTO-DETECTION
# =====================================================================

if [ $# -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  VLSI_PC="$1"
elif [[ "$PWD" =~ /home/vlsi([0-9]+)(/|$) ]]; then
  VLSI_PC="${BASH_REMATCH[1]}"
else
  VLSI_PC="$DEFAULT_VLSI_PC"
fi

DC_CSH="${DC_CSH_TEMPLATE/XX/${VLSI_PC}}"
DC_CMD="dc_shell"
PROJECT_ROOT="$PWD"
LIB_DIR="$PROJECT_ROOT/lib"
OUT_DIR="$PROJECT_ROOT/output"


# =====================================================================
#                     LIBRARY FILE NAMES
# =====================================================================

LIB_FF="saed14rvt_base_ff0p88v25c.db"
LIB_TT="saed14rvt_base_tt0p8v25c.db"
LIB_SS="saed14rvt_base_ss0p72v125c.db"
LIB_CG="saed14rvt_cg_ss0p72v125c.db"   # clock gating cells, SS CG run only


# =====================================================================
#                     STARTUP CHECKS
# =====================================================================

echo "============================================================"
echo "  PPA DESIGN SPACE EXPLORER"
echo "  Design : $DESIGN_FILE  |  Top: $TOP_MODULE"
echo "  VLSI PC: $VLSI_PC"
echo "  Date   : $(date)"
echo "============================================================"
echo ""

if [ ! -f "$PROJECT_ROOT/$DESIGN_FILE" ]; then
  echo "ERROR: Design file '$DESIGN_FILE' not found next to run.sh"
  exit 1
fi
if [ ! -d "$LIB_DIR" ]; then
  echo "ERROR: lib/ folder not found. Place all .db files inside lib/"
  exit 1
fi
for db in "$LIB_FF" "$LIB_TT" "$LIB_SS" "$LIB_CG"; do
  if [ ! -f "$LIB_DIR/$db" ]; then
    echo "ERROR: Missing library file: lib/$db"
    exit 1
  fi
done

mkdir -p "$OUT_DIR"


# =====================================================================
#                     RESULTS TABLE
#  One row per run: CORNER|PERIOD|WNS|AREA|POWER|CG_FLAG
# =====================================================================

RESULTS=()


# =====================================================================
#                     REPORT PARSERS
# =====================================================================

# WNS from timing report
get_wns() {
  local rpt="$1"
  grep -E "slack \((MET|VIOLATED)\)" "$rpt" | tail -1 \
    | awk '{print $NF}' || echo "0"
}

# Total area (cell + net interconnect) — real silicon footprint
get_area() {
  local rpt="$1"
  grep "Total area:" "$rpt" | awk '{print $NF}' | tail -1 || echo "0"
}

# Total power — top design row always shows 100.0% in SAED14nm report
get_power() {
  local rpt="$1"
  awk '/[0-9][ \t]+100\.0[ \t]*$/{print $(NF-1); exit}' "$rpt" || echo "0"
}


# =====================================================================
#                     WRITE TCL AND RUN DC
#  Args: $1=run_dir  $2=period_ns  $3=db_file  $4=use_cg (0|1)
# =====================================================================

run_dc() {
  local run_dir="$1"
  local period="$2"
  local db_file="$3"
  local use_cg="$4"

  mkdir -p "$run_dir/reports" "$run_dir/outputs"

  local target_lib="${LIB_DIR}/${db_file}"
  local link_lib="* ${LIB_DIR}/${db_file}"
  if [ "$use_cg" -eq 1 ]; then
    target_lib="${LIB_DIR}/${db_file} ${LIB_DIR}/${LIB_CG}"
    link_lib="* ${LIB_DIR}/${db_file} ${LIB_DIR}/${LIB_CG}"
  fi

  # Build optional clock constraint TCL lines from user config
  local extra_clk=""
  [ -n "$CLK_UNCERTAINTY" ] && extra_clk="${extra_clk}
set_clock_uncertainty ${CLK_UNCERTAINTY} [get_clocks clk]"
  [ -n "$CLK_TRANSITION" ]  && extra_clk="${extra_clk}
set_clock_transition  ${CLK_TRANSITION}  [get_clocks clk]"
  [ -n "$CLK_LATENCY" ]     && extra_clk="${extra_clk}
set_clock_latency     ${CLK_LATENCY}     [get_clocks clk]"

  # TCL written inline, deleted after run
  cat > "$run_dir/synth.tcl" <<TCL_SCRIPT
# Auto-generated by PPA Explorer

set search_path    [concat \$search_path "${LIB_DIR}"]
set target_library "${target_lib}"
set link_library   "${link_lib}"

set DESIGN_NAME  "${TOP_MODULE}"
set CLOCK_PERIOD ${period}

file mkdir reports
file mkdir outputs

analyze -format verilog ${PROJECT_ROOT}/${DESIGN_FILE}
elaborate \$DESIGN_NAME
current_design \$DESIGN_NAME
link

# --- Clock constraints (edit CLK_* variables in USER CONFIGURATION) ---
create_clock -name clk -period \$CLOCK_PERIOD [get_ports clk]
set_input_delay  [expr \$CLOCK_PERIOD * ${INPUT_DELAY_RATIO}] -clock clk \
  [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay [expr \$CLOCK_PERIOD * ${OUTPUT_DELAY_RATIO}] -clock clk [all_outputs]
${extra_clk}
# --- End clock constraints ---

$(if [ "$use_cg" -eq 1 ]; then
echo "set_clock_gating_style -sequential_cell latch -control_point before -control_signal scan_enable"
echo "compile_ultra -gate_clock"
else
echo "compile_ultra -retime"
fi)

change_names -rules verilog -hierarchy

report_timing -delay max -max_paths 5 > reports/timing_setup.rpt
report_timing -delay min -max_paths 5 > reports/timing_hold.rpt
report_area   -hierarchy              > reports/area.rpt
report_power  -hierarchy              > reports/power.rpt

write -format verilog -hierarchy -output outputs/${TOP_MODULE}_netlist.v
write_sdc outputs/${TOP_MODULE}.sdc

echo "DC_DONE"
quit
TCL_SCRIPT

  echo "  [DC] period=${period}ns  lib=$(basename $db_file)  cg=${use_cg}"
  csh -c "cd \"$run_dir\"; source \"$DC_CSH\"; ${DC_CMD} -f synth.tcl" \
    > "$run_dir/dc_run.log" 2>&1

  rm -f "$run_dir/synth.tcl"
}


# =====================================================================
#  FF TRACKBACK: after FF timing first met at MET_PERIOD with high WNS,
#  step backward 0.1ns at a time to find the tightest period that still
#  meets TARGET_SLACK. Keeps last passing period if target is overshot.
#
#  Args: $1=met_period  $2=db_file
#  Returns: sets global FF_BEST_PERIOD to tightest passing period
# =====================================================================

FF_BEST_PERIOD=""

ff_trackback() {
  local met_period="$1"
  local db_file="$2"
  local corner_dir="$OUT_DIR/fast_fast"

  echo ""
  echo "  [FF TRACKBACK] Timing met at ${met_period}ns — stepping back 0.1ns for tightest result"

  # Best so far is the met period itself — safe fallback if all tighter steps fail
  FF_BEST_PERIOD="$met_period"

  local tb_period
  tb_period=$(awk "BEGIN{printf \"%.1f\", $met_period - 0.1}")

  while true; do

    # Stop if we go below 0.1ns — not physically meaningful
    if awk "BEGIN{exit !($tb_period < 0.1)}"; then
      echo "  [FF TRACKBACK] Reached 0.1ns floor — stopping"
      break
    fi

    local tb_dir="$corner_dir/period_${tb_period}ns"
    run_dc "$tb_dir" "$tb_period" "$db_file" 0

    local tb_wns tb_area tb_power
    tb_wns=$(get_wns     "$tb_dir/reports/timing_setup.rpt")
    tb_area=$(get_area   "$tb_dir/reports/area.rpt")
    tb_power=$(get_power "$tb_dir/reports/power.rpt")
    RESULTS+=("fast_fast|${tb_period}|${tb_wns}|${tb_area}|${tb_power}|0")
    echo "  [FF TRACKBACK] period=${tb_period}ns  WNS=${tb_wns}"

    if awk "BEGIN{exit !($tb_wns >= $TARGET_SLACK)}"; then
      # Still passing — record as new best, keep going tighter
      FF_BEST_PERIOD="$tb_period"
      tb_period=$(awk "BEGIN{printf \"%.1f\", $tb_period - 0.1}")
    else
      # Timing violated — stop, FF_BEST_PERIOD already holds last passing period
      echo "  [FF TRACKBACK] Violated at ${tb_period}ns — tightest passing: ${FF_BEST_PERIOD}ns"
      break
    fi

  done

  echo "  [FF TRACKBACK] Final best FF period: ${FF_BEST_PERIOD}ns"
}


# =====================================================================
#                     CORE SWEEP FUNCTION
#
#  Args: $1=corner  $2=db_file  $3=goal (speed|area|power)
#        $4=hint_period  (previous corner's met period, or "" for 1ns)
#
#  Sets global CORNER_MET_PERIOD after timing is first met.
# =====================================================================

CORNER_MET_PERIOD=""

sweep_corner() {
  local corner="$1"
  local db_file="$2"
  local goal="$3"
  local hint_period="${4:-}"

  local corner_dir="$OUT_DIR/$corner"
  mkdir -p "$corner_dir"

  echo ""
  echo "------------------------------------------------------------"
  echo "  CORNER: $corner  |  Goal: $goal  |  Target slack: ${TARGET_SLACK}ns"
  echo "------------------------------------------------------------"

  # Start from previous corner's tightest met period, or 1ns for FF
  local period
  if [ -n "$hint_period" ]; then
    period="$hint_period"
    echo "  Starting from previous corner met point: ${period}ns"
  else
    period="1.0"
  fi

  # ---- PROBE RUN at starting period ----
  local run_dir="$corner_dir/period_${period}ns"
  run_dc "$run_dir" "$period" "$db_file" 0

  local wns area power
  wns=$(get_wns   "$run_dir/reports/timing_setup.rpt")
  area=$(get_area "$run_dir/reports/area.rpt")
  power=$(get_power "$run_dir/reports/power.rpt")
  RESULTS+=("${corner}|${period}|${wns}|${area}|${power}|0")
  echo "  period=${period}ns  WNS=${wns}  Area=${area}  Power=${power}"

  # If probe already meets timing
  if awk "BEGIN{exit !($wns >= $TARGET_SLACK)}"; then
    echo "  *** TIMING MET at probe ${period}ns ***"
    CORNER_MET_PERIOD="$period"
    if [ "$goal" = "speed" ]; then
      ff_trackback "$period" "$db_file"
      CORNER_MET_PERIOD="$FF_BEST_PERIOD"
      echo "  Corner $corner complete."
      return
    fi
    # TT/SS: continue sweep for area/power from next period
    period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")
  elif awk "BEGIN{exit !($wns < -1.0)}"; then
    # Smart jump: large violation, skip ahead by ceil(|WNS|)
    local abs_wns
    abs_wns=$(awk "BEGIN{v=$wns; if(v<0)v=-v; printf \"%.1f\",v}")
    period=$(awk "BEGIN{printf \"%.1f\", $period + $abs_wns + 0.5}")
    echo "  Smart jump to ${period}ns"
  else
    # Small violation — normal +1ns step
    period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")
  fi

  # ---- ADAPTIVE SWEEP LOOP ----
  local timing_met=0
  if [ -n "$CORNER_MET_PERIOD" ]; then timing_met=1; fi

  local best_power_period="$period"
  local best_power_val="999999"
  local prev_area="$area"
  local prev_power="$power"    # tracks previous power for 2% convergence check
  local converge_count=0

  while true; do

    # Safety cap
    if awk "BEGIN{exit !($period > 200.0)}"; then
      echo "  WARNING: 200ns safety limit reached — stopping"
      break
    fi

    run_dir="$corner_dir/period_${period}ns"
    run_dc "$run_dir" "$period" "$db_file" 0

    wns=$(get_wns   "$run_dir/reports/timing_setup.rpt")
    area=$(get_area "$run_dir/reports/area.rpt")
    power=$(get_power "$run_dir/reports/power.rpt")
    RESULTS+=("${corner}|${period}|${wns}|${area}|${power}|0")
    echo "  period=${period}ns  WNS=${wns}  Area=${area}  Power=${power}"

    # Timing met for the first time
    if awk "BEGIN{exit !($wns >= $TARGET_SLACK)}" && [ "$timing_met" -eq 0 ]; then
      timing_met=1
      CORNER_MET_PERIOD="$period"
      echo "  *** TIMING MET at ${period}ns ***"
      if [ "$goal" = "speed" ]; then
        ff_trackback "$period" "$db_file"
        CORNER_MET_PERIOD="$FF_BEST_PERIOD"
        break
      fi
      # Initialise prev_power at timing-met point for convergence tracking
      prev_power="$power"
    fi

    # Zero-slack trap: DC stuck, jump +1ns
    if awk "BEGIN{exit !($wns >= 0.0 && $wns < $TARGET_SLACK)}" && [ "$timing_met" -eq 0 ]; then
      period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")
      continue
    fi

    # Post timing-met for TT: +1ns until area converges (<2% change for 2 runs)
    if [ "$goal" = "area" ] && [ "$timing_met" -eq 1 ]; then
      local area_change
      area_change=$(awk "BEGIN{
        diff = $prev_area - $area
        if ($prev_area == 0) { print 100; exit }
        v = diff / $prev_area; if (v<0) v=-v
        printf \"%.4f\", v
      }")
      if awk "BEGIN{exit !($area_change < 0.02)}"; then
        converge_count=$((converge_count + 1))
        if [ "$converge_count" -ge 2 ]; then
          echo "  *** AREA CONVERGED at ${period}ns — stopping TT sweep ***"
          break
        fi
      else
        converge_count=0
      fi
      prev_area="$area"
      period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")
      continue
    fi

    # Post timing-met for SS: +1ns until power converges (<2% change for 2 runs)
    # Also tracks best power period for the CG bonus run.
    if [ "$goal" = "power" ] && [ "$timing_met" -eq 1 ]; then

      # Track period with lowest power seen so far
      if awk "BEGIN{exit !($power > 0 && $power < $best_power_val)}"; then
        best_power_val="$power"
        best_power_period="$period"
      fi

      # 2% convergence check on power — same logic as area
      local power_change
      power_change=$(awk "BEGIN{
        diff = $prev_power - $power
        if ($prev_power == 0) { print 100; exit }
        v = diff / $prev_power; if (v<0) v=-v
        printf \"%.4f\", v
      }")
      echo "  [SS] Power change vs previous: $(awk "BEGIN{printf \"%.1f\", $power_change * 100}")%"

      if awk "BEGIN{exit !($power_change < 0.02)}"; then
        converge_count=$((converge_count + 1))
        if [ "$converge_count" -ge 2 ]; then
          echo "  *** POWER CONVERGED at ${period}ns — best power at ${best_power_period}ns ***"
          break
        fi
      else
        converge_count=0
      fi
      prev_power="$power"
      period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")
      continue
    fi

    # Still violating — coarse +1ns step
    period=$(awk "BEGIN{printf \"%.1f\", $period + 1.0}")

  done

  # ---- CG bonus run at best power period (SS only) ----
  if [ "$goal" = "power" ] && [ "$timing_met" -eq 1 ]; then
    echo ""
    echo "  [CG RUN] Clock gating at best power period: ${best_power_period}ns"
    run_dir="$corner_dir/period_${best_power_period}ns_with_CG"
    run_dc "$run_dir" "$best_power_period" "$db_file" 1

    local cg_power cg_area
    cg_power=$(get_power "$run_dir/reports/power.rpt")
    cg_area=$(get_area   "$run_dir/reports/area.rpt")
    RESULTS+=("${corner}|${best_power_period}_CG|${wns}|${cg_area}|${cg_power}|1")
    echo "  [CG] Power=${cg_power}mW  Area=${cg_area}um2"
  fi

  echo "  Corner $corner complete."
}


# =====================================================================
#       RUN ALL THREE CORNERS — each starts from previous met point
# =====================================================================

# FF: fresh start from 1ns, trackback finds tightest period
sweep_corner "fast_fast"       "$LIB_FF" "speed" ""
FF_MET="$CORNER_MET_PERIOD"

# TT starts from FF tightest met period
sweep_corner "typical_typical" "$LIB_TT" "area"  "$FF_MET"
TT_MET="$CORNER_MET_PERIOD"

# SS starts from TT met period
sweep_corner "slow_slow"       "$LIB_SS" "power" "$TT_MET"


# =====================================================================
#                     FINAL SUMMARY REPORT
# =====================================================================

SUMMARY="$OUT_DIR/FINAL_SUMMARY.rpt"

{
echo "============================================================"
echo "  PPA DESIGN SPACE EXPLORER — FINAL SUMMARY"
echo "  Design : $TOP_MODULE   File: $DESIGN_FILE"
echo "  Date   : $(date)"
echo "  VLSI PC: $VLSI_PC"
echo "============================================================"
echo ""
echo "DETAILED RESULTS:"
echo "------------------------------------------------------------"
printf "%-20s %-10s %-10s %-14s %-12s %s\n" \
  "CORNER" "PERIOD" "WNS(ns)" "AREA(um2)" "POWER(mW)" "CG"
echo "------------------------------------------------------------"

best_speed_period="N/A"; best_speed_area="N/A"; best_speed_power="N/A"
best_area_val=999999999; best_area_period="N/A"; best_area_power="N/A"
best_power_val=999999;   best_power_period="N/A"; best_power_area="N/A"
best_cg_power="N/A";     best_cg_period="N/A"
tradeoff_period="N/A";   tradeoff_area="N/A"; tradeoff_power="N/A"
ff_timing_met=0; tt_timing_met=0

for row in "${RESULTS[@]}"; do
  IFS='|' read -r corner period wns area power cg <<< "$row"
  printf "%-20s %-10s %-10s %-14s %-12s %s\n" \
    "$corner" "${period}ns" "$wns" "$area" "$power" "$cg"

  if [[ "$corner" == "fast_fast" ]] && [[ "$cg" == "0" ]]; then
    if awk "BEGIN{exit !($wns >= $TARGET_SLACK)}"; then
      ff_timing_met=1
      best_speed_period="${period}ns"
      best_speed_area="$area"; best_speed_power="$power"
    fi
  fi

  if [[ "$corner" == "typical_typical" ]] && [ "$tt_timing_met" -eq 0 ]; then
    if awk "BEGIN{exit !($wns >= $TARGET_SLACK)}"; then
      tt_timing_met=1
      tradeoff_period="${period}ns"
      tradeoff_area="$area"; tradeoff_power="$power"
    fi
  fi

  if [[ "$corner" == "typical_typical" ]] && [[ "$cg" == "0" ]]; then
    if awk "BEGIN{exit !($area < $best_area_val && $area > 0)}"; then
      best_area_val="$area"; best_area_period="${period}ns"; best_area_power="$power"
    fi
  fi

  if [[ "$corner" == "slow_slow" ]] && [[ "$cg" == "0" ]]; then
    if awk "BEGIN{exit !($power < $best_power_val && $power > 0)}"; then
      best_power_val="$power"; best_power_period="${period}ns"; best_power_area="$area"
    fi
  fi

  if [[ "$cg" == "1" ]]; then
    best_cg_power="$power"; best_cg_period="${period%_CG}ns"
  fi

done

# Auto-calculate CG power saving percentage
cg_saving="N/A"
if [ "$best_cg_power" != "N/A" ] && [ "$best_power_val" != "999999" ]; then
  cg_saving=$(awk "BEGIN{
    s = ($best_power_val - $best_cg_power) / $best_power_val * 100
    if (s < 0) s = 0
    printf \"%.1f\", s
  }")
fi

echo "------------------------------------------------------------"
echo ""
echo "============================================================"
echo "  RECOMMENDATIONS"
echo "============================================================"
echo ""
echo "  MAX SPEED  (Fast-Fast corner — tightest passing period)"
echo "    Period : $best_speed_period"
echo "    Area   : $best_speed_area um2"
echo "    Power  : $best_speed_power mW"
echo ""
echo "  BEST AREA  (Typical-Typical corner)"
echo "    Period : $best_area_period"
echo "    Area   : $best_area_val um2"
echo "    Power  : $best_area_power mW"
echo ""
echo "  BEST POWER  (Slow-Slow, no clock gating)"
echo "    Period : $best_power_period"
echo "    Area   : $best_power_area um2"
echo "    Power  : $best_power_val mW"
echo ""
echo "  BEST POWER WITH CLOCK GATING  (Slow-Slow + CG cells)"
echo "    Period : $best_cg_period"
echo "    Power  : $best_cg_power mW"
echo "    Clock gating power saving: ${cg_saving}%"
echo ""
echo "  BEST TRADEOFF  (Typical-Typical, timing just met)"
echo "    Period : $tradeoff_period"
echo "    Area   : $tradeoff_area um2"
echo "    Power  : $tradeoff_power mW"
echo "    Note   : Balanced PPA — good default choice"
echo ""
echo "============================================================"
echo "  Output folders:"
echo "    output/fast_fast/        — speed runs + trackback runs"
echo "    output/typical_typical/  — area/tradeoff runs"
echo "    output/slow_slow/        — power runs + CG run"
echo "    output/FINAL_SUMMARY.rpt"
echo "============================================================"
} | tee "$SUMMARY"

echo ""
echo "=== PPA EXPLORATION COMPLETE ==="
echo "Summary saved to: $SUMMARY"
