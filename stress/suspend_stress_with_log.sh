#!/bin/bash
# rtcwake 30s x30; log total_hw_sleep + vendor PM stats; make CSV/Markdown report
# Intel: if slp_s0_residency_usec doesn't increase vs previous iteration, run S0ixSelftestTool and archive logs.

set -euo pipefail

LOG="${1:-hw_sleep.log}"
ITER=30
SLEEP_SEC=30
SELFTEST_DIR="/var/log/s0ix_selftest"

BASE="$(basename "${LOG%.*}")"
CSV="${BASE}_summary.csv"
MD="${BASE}_report.md"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [log_file]" >&2
  exit 1
fi

command -v rtcwake >/dev/null || { echo "rtcwake not found"; exit 1; }
command -v lspci  >/dev/null || { echo "lspci not found";  exit 1; }

# Detect CPU vendor
CPU_VENDOR="unknown"
LSPCI_OUT="$(lspci -nnvvv || true)"
if echo "$LSPCI_OUT" | grep -i 'Host bridge' | grep -qi 'Intel'; then
  CPU_VENDOR="intel"
elif echo "$LSPCI_OUT" | grep -i 'Host bridge' | grep -qi 'Advanced Micro Devices'; then
  CPU_VENDOR="amd"
fi

# Ensure debugfs is mounted
if ! mount | grep -q '/sys/kernel/debug'; then
  mount -t debugfs debugfs /sys/kernel/debug || true
fi

# -------- Intel S0ixSelftestTool bootstrap & run --------
ensure_s0ix_tool() {
  local repo_dir="/opt/S0ixSelftestTool"

  # deps (same as before)
  command -v git      >/dev/null || (apt-get update -y && apt-get install -y git)
  command -v acpidump >/dev/null || apt-get install -y acpidump
  command -v powertop >/dev/null || apt-get install -y powertop
  command -v gawk     >/dev/null || apt-get install -y gawk || true
  dpkg -s vim-common >/dev/null 2>&1 || apt-get install -y vim-common || true

  # clone or update
  if [[ ! -d "$repo_dir" ]]; then
    git clone https://github.com/intel/S0ixSelftestTool.git "$repo_dir"
  else
    (cd "$repo_dir" && git pull --ff-only || true)
  fi

  # optional: add repo_dir to PATH so the bundled turbostat is found
  export PATH="$repo_dir:$PATH"
}

run_s0ix_selftest() {
  local iter="$1"
  local repo_dir="/opt/S0ixSelftestTool"

  mkdir -p "$SELFTEST_DIR/iter_${iter}_bundle"

  # Run tool with absolute path; set CWD to the bundle so all logs and *.dat land there
  # (no directory change for the main script; only this command's working dir)
  ( cd "$SELFTEST_DIR/iter_${iter}_bundle" && \
    "$repo_dir/s0ix-selftest-tool.sh" -s > "iter_${iter}_stdout.log" 2>&1 ) || true

  # Normalize tool-generated s0ix-output log name to iteration-labeled file
  local genlog="$(ls -1t "$SELFTEST_DIR/iter_${iter}_bundle"/*-s0ix-output.log 2>/dev/null | head -n1 || true)"
  if [[ -n "$genlog" ]]; then
    mv "$genlog" "$SELFTEST_DIR/iter_${iter}_bundle/iter_${iter}_s0ix-output.log"
  fi

  # Context snapshot (optional)
  uname -a > "$SELFTEST_DIR/iter_${iter}_bundle/uname.txt"
  (dmesg --time-format=iso 2>/dev/null || true) | tail -n 500 > "$SELFTEST_DIR/iter_${iter}_bundle/dmesg-tail.txt"
  [[ -r /sys/power/mem_sleep ]] && cat /sys/power/mem_sleep > "$SELFTEST_DIR/iter_${iter}_bundle/mem_sleep.txt"

  # Pack everything generated in this iteration
  ( cd "$SELFTEST_DIR/iter_${iter}_bundle" && \
    tar -czvf "s0ix-selftest-tool_${iter}.tar.gz" * )

  local tarpath="$SELFTEST_DIR/iter_${iter}_bundle/s0ix-selftest-tool_${iter}.tar.gz"
  echo "Iter $iter: Selftest tarball -> ${tarpath}" | tee -a "$LOG"

  # expose tar path to CSV/Markdown
  SELFTEST_LAST_TAR="$tarpath"
}

# -------- Initialize logs & CSV header --------
echo "Start: $(date -Iseconds)" > "$LOG"
echo "CPU vendor: $CPU_VENDOR" | tee -a "$LOG"

# CSV header (per-iteration)
echo "iteration,timestamp,vendor,total_hw_sleep,last_hw_sleep,slp_s0_residency_usec,mem_sleep,pm_wakeup_irq,low_power_idle_system_us,low_power_idle_cpu_us,intel_selftest_ran,selftest_log,selftest_tar" > "$CSV"

PREV_SLP=""
SELFTEST_RAN_COUNT=0
SELFTEST_ITERS=""

for i in $(seq 1 "$ITER"); do
  echo "Iter $i: suspend for ${SLEEP_SEC}s..." | tee -a "$LOG"
  rtcwake -m mem -s "$SLEEP_SEC" -v
  sleep 2

  ts="$(date -Iseconds)"
  ths="$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null || echo N/A)"
  lhs="$(cat /sys/power/suspend_stats/last_hw_sleep  2>/dev/null || echo N/A)"

  # Defaults (AMD-only fields empty for Intel; Intel-only fields empty for AMD)
  slp=""; mems=""; wakeirq=""; lpi_sys=""; lpi_cpu=""
  ran="false"; selflog=""

  if [[ "$CPU_VENDOR" == "intel" ]]; then
    slp="$(cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec 2>/dev/null || echo "")"
    echo "[$ts] Iter $i: total_hw_sleep=$ths last_hw_sleep=$lhs slp_s0_residency_usec=${slp:-N/A}" | tee -a "$LOG"

    # trigger selftest if slp didn't increase
    if [[ -n "$slp" ]] && [[ -n "$PREV_SLP" ]] && [[ "$slp" =~ ^[0-9]+$ ]] && [[ "$PREV_SLP" =~ ^[0-9]+$ ]]; then
      if [[ "$slp" -le "$PREV_SLP" ]]; then
        echo "Iter $i: slp_s0_residency_usec did NOT increase; running S0ixSelftestTool..." | tee -a "$LOG"
        ensure_s0ix_tool
        run_s0ix_selftest "$i"
        ran="true"
        selflog="${SELFTEST_DIR}/iter_${i}_s0ix-output.log"
        SELFTEST_RAN_COUNT=$((SELFTEST_RAN_COUNT+1))
        SELFTEST_ITERS="${SELFTEST_ITERS}${SELFTEST_ITERS:+, }${i}"
      fi
    fi
    PREV_SLP="${slp:-$PREV_SLP}"

    # Optional extra Intel PM stats to LOG
    [[ -r /sys/kernel/debug/pmc_core/package_cstate_show ]] && {
      echo "Iter $i: pmc_core/package_cstate_show:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/package_cstate_show | tee -a "$LOG"
    }
    [[ -r /sys/kernel/debug/pmc_core/substate_residencies ]] && {
      echo "Iter $i: pmc_core/substate_residencies:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/substate_residencies | tee -a "$LOG"
    }

  elif [[ "$CPU_VENDOR" == "amd" ]]; then
    mems="$(cat /sys/power/mem_sleep 2>/dev/null || echo "")"
    wakeirq="$(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo "")"
    lpi_sys="$(cat /sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us 2>/dev/null || echo "")"
    lpi_cpu="$(cat /sys/devices/system/cpu/cpuidle/low_power_idle_cpu_residency_us 2>/dev/null || echo "")"
    echo "[$ts] Iter $i: total_hw_sleep=$ths last_hw_sleep=$lhs mem_sleep=${mems:-N/A} pm_wakeup_irq=${wakeirq:-N/A}" | tee -a "$LOG"
    if [[ -r /sys/kernel/debug/amd_pmc/s0ix_stats ]]; then
      echo "Iter $i: amd_pmc/s0ix_stats:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/amd_pmc/s0ix_stats | tee -a "$LOG"
    fi
  fi

  # Write one CSV row
  echo "$i,$ts,$CPU_VENDOR,$ths,$lhs,${slp:-},${mems:-},${wakeirq:-},${lpi_sys:-},${lpi_cpu:-},$ran,${selflog},${SELFTEST_LAST_TAR:-}" >> "$CSV"

  sleep 2
done

echo "End: $(date -Iseconds)" >> "$LOG"

# -------- Build Markdown report (summary + sample table) --------
KVER="$(uname -a)"
{
  echo "# Suspend/Resume Report"
  echo
  echo "- **Kernel**: \`$KVER\`"
  echo "- **CPU vendor**: \`$CPU_VENDOR\`"
  echo "- **Iterations**: \`$ITER\` (sleep ${SLEEP_SEC}s each)"
  echo "- **Start time**: \`$(head -n1 "$LOG" | sed 's/Start: //')\`"
  echo "- **End time**:   \`$(tail -n1 "$LOG" | sed 's/End: //')\`"
  echo
  echo "## Key Findings"
  echo "- **CSV summary**: \`$CSV\`"
  echo "- **Main log**: \`$LOG\`"
  if [[ "$CPU_VENDOR" == "intel" ]]; then
    echo "- **S0ixSelftestTool runs**: \`$SELFTEST_RAN_COUNT\`"
    [[ -n "$SELFTEST_ITERS" ]] && echo "  - Triggered at iterations: $SELFTEST_ITERS"
    echo "  - Logs stored in: \`$SELFTEST_DIR\` (per-iteration files)"
  else
    echo "- **AMD s2idle info**: see \`$LOG\` (entries: \`mem_sleep\`, \`pm_wakeup_irq\`, \`s0ix_stats\`, cpuidle residencies)"
  fi
  echo
  echo "## Sample (first 10 rows)"
  echo
  echo "| iteration | timestamp | vendor | total_hw_sleep | last_hw_sleep | slp_s0_residency_usec | mem_sleep | pm_wakeup_irq | LPI_system_us | LPI_cpu_us | selftest_ran |"
  echo "|---:|---|---|---:|---:|---:|---|---:|---:|---:|---|"
  head -n 11 "$CSV" | tail -n +2 | awk -F',' '{printf("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)}'
  echo
  echo "## Notes"
  echo "- \`total_hw_sleep\` / \`last_hw_sleep\` come from \`/sys/power/suspend_stats/*\`."
  echo "- Intel \`slp_s0_residency_usec\` is from \`/sys/kernel/debug/pmc_core\` (S0ix/SLP_S0 residency)."
  echo "- AMD rows include \`mem_sleep\` mode、wakeup IRQ、以及 cpuidle 的 LPI stay duration."
  echo
} > "$MD"

echo "Done."
echo "CSV : $CSV"
echo "MD  : $MD"
