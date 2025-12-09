#!/bin/bash
# rtcwake 30s x30; log total_hw_sleep + vendor-specific PM stats

set -euo pipefail

# --- config ---
LOG="${1:-hw_sleep.log}"
ITER=30
SLEEP_SEC=30

# --- sanity checks ---
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [log_file]" >&2
  exit 1
fi
command -v rtcwake >/dev/null || { echo "rtcwake not found"; exit 1; }
command -v lspci  >/dev/null || { echo "lspci not found";  exit 1; }

# --- detect CPU vendor via lspci -nnvvv ---
CPU_VENDOR="unknown"
LSPCI_OUT="$(lspci -nnvvv || true)"
if echo "$LSPCI_OUT" | grep -i 'Host bridge' | grep -qi 'Intel'; then
  CPU_VENDOR="intel"
elif echo "$LSPCI_OUT" | grep -i 'Host bridge' | grep -qi 'Advanced Micro Devices'; then
  CPU_VENDOR="amd"
fi

# --- make sure debugfs is mounted ---
if ! mount | grep -q '/sys/kernel/debug'; then
  mount -t debugfs debugfs /sys/kernel/debug || true
fi

# --- start log ---
echo "Start: $(date)" > "$LOG"
echo "CPU vendor: $CPU_VENDOR" | tee -a "$LOG"

for i in $(seq 1 "$ITER"); do
  echo "Iter $i: suspend for ${SLEEP_SEC}s..." | tee -a "$LOG"
  rtcwake -m mem -s "$SLEEP_SEC" -v

  # wait a moment after resume so counters settle
  sleep 2

  # common metric
  THS="$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null || echo N/A)"
  echo "Iter $i: total_hw_sleep = $THS" | tee -a "$LOG"

  if [[ "$CPU_VENDOR" == "intel" ]]; then
    # Intel pmc_core debugfs
    if [[ -r /sys/kernel/debug/pmc_core/slp_s0_residency_usec ]]; then
      echo "Iter $i: pmc_core/slp_s0_residency_usec = $(cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec)" | tee -a "$LOG"
    fi
    if [[ -r /sys/kernel/debug/pmc_core/package_cstate_show ]]; then
      echo "Iter $i: pmc_core/package_cstate_show:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/package_cstate_show | tee -a "$LOG"
    fi
    if [[ -r /sys/kernel/debug/pmc_core/substate_residencies ]]; then
      echo "Iter $i: pmc_core/substate_residencies:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/substate_residencies | tee -a "$LOG"
    fi
  elif [[ "$CPU_VENDOR" == "amd" ]]; then
    # AMD amd_pmc debugfs
    if [[ -r /sys/kernel/debug/amd_pmc/s0ix_stats ]]; then
      echo "Iter $i: amd_pmc/s0ix_stats:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/amd_pmc/s0ix_stats | tee -a "$LOG"
    fi
  fi

  # small gap between iterations (optional)
  sleep 2
done

echo "End: $(date)" >> "$LOG"
echo "Done. Log: $LOG"
