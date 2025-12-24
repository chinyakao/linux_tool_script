#!/bin/bash
# rtcwake 30s x30; log total_hw_sleep + vendor-specific PM stats (Intel/AMD s2idle)

set -euo pipefail

LOG="${1:-hw_sleep.log}"
ITER=30
SLEEP_SEC=30

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0 [log_file]" >&2
  exit 1
fi
command -v rtcwake >/dev/null || { echo "rtcwake not found"; exit 1; }
command -v lspci  >/dev/null || { echo "lspci not found";  exit 1; }

# Detect CPU vendor via lspci
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

echo "Start: $(date)" > "$LOG"
echo "CPU vendor: $CPU_VENDOR" | tee -a "$LOG"

for i in $(seq 1 "$ITER"); do
  echo "Iter $i: suspend for ${SLEEP_SEC}s..." | tee -a "$LOG"
  rtcwake -v -m no -s "$SLEEP_SEC" && systemctl suspend

  sleep 2  # let counters settle

  # Common metrics
  THS="$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null || echo N/A)"
  LHS="$(cat /sys/power/suspend_stats/last_hw_sleep  2>/dev/null || echo N/A)"
  echo "Iter $i: total_hw_sleep = $THS" | tee -a "$LOG"
  echo "Iter $i: last_hw_sleep  = $LHS" | tee -a "$LOG"

  if [[ "$CPU_VENDOR" == "intel" ]]; then
    # Intel pmc_core debugfs (present on S0ix-capable Intel systems)
    [[ -r /sys/kernel/debug/pmc_core/slp_s0_residency_usec ]] && \
      echo "Iter $i: pmc_core/slp_s0_residency_usec = $(cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec)" | tee -a "$LOG"

    if [[ -r /sys/kernel/debug/pmc_core/package_cstate_show ]]; then
      echo "Iter $i: pmc_core/package_cstate_show:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/package_cstate_show | tee -a "$LOG"
    fi

    if [[ -r /sys/kernel/debug/pmc_core/substate_residencies ]]; then
      echo "Iter $i: pmc_core/substate_residencies:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/pmc_core/substate_residencies | tee -a "$LOG"
    fi

  elif [[ "$CPU_VENDOR" == "amd" ]]; then
    # AMD s2idle / S0ix metrics
    # Mode used: mem_sleep
    [[ -r /sys/power/mem_sleep ]] && \
      echo "Iter $i: mem_sleep = $(cat /sys/power/mem_sleep)" | tee -a "$LOG"

    # Who woke the system (IRQ number)
    [[ -r /sys/power/pm_wakeup_irq ]] && \
      echo "Iter $i: pm_wakeup_irq = $(cat /sys/power/pm_wakeup_irq)" | tee -a "$LOG"

    # amd_pmc debugfs: s0ix_stats (entry/exit/residency counters)
    if [[ -r /sys/kernel/debug/amd_pmc/s0ix_stats ]]; then
      echo "Iter $i: amd_pmc/s0ix_stats:" | tee -a "$LOG"
      sed 's/^/  /' /sys/kernel/debug/amd_pmc/s0ix_stats | tee -a "$LOG"
    fi

    # cpuidle low_power_idle residencies (system/cpu)
    [[ -r /sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us ]] && \
      echo "Iter $i: low_power_idle_system_residency_us = $(cat /sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us)" | tee -a "$LOG"

    [[ -r /sys/devices/system/cpu/cpuidle/low_power_idle_cpu_residency_us ]] && \
      echo "Iter $i: low_power_idle_cpu_residency_us = $(cat /sys/devices/system/cpu/cpuidle/low_power_idle_cpu_residency_us)" | tee -a "$LOG"

    # Optional: SMU firmware version (sysfs)
    for n in /sys/bus/platform/drivers/amd_pmc/*; do
      [[ -r "$n/smu_fw_version" ]] && echo "Iter $i: smu_fw_version = $(cat "$n/smu_fw_version")" | tee -a "$LOG"
    done
  fi

  sleep 2
done

echo "End: $(date)" >> "$LOG"
