#!/bin/bash
# rtcwake_suspend_30_times.sh
# Suspend for 30s, resume, repeat 30 times, log total_hw_sleep

LOG="hw_sleep.log"
STAT="/sys/power/suspend_stats/total_hw_sleep"
STAT2="/sys/kernel/debug/pmc_core/package_cstate_show"

echo "Start: $(date)" > "$LOG"

for i in $(seq 1 30); do
    echo "Iteration $i: suspend for 30s..." | tee -a "$LOG"
    rtcwake -m mem -s 30
    sleep 2
    VALUE=$(cat "$STAT")
    echo "Iteration $i: total_hw_sleep = $VALUE" | tee -a "$LOG"
    VALUE2=$(cat "$STAT2")
    echo "Iteration $i: package_cstate_show: " | tee -a "$LOG"
    echo "$VALUE2" | tee -a "$LOG"
done

echo "End: $(date)" >> "$LOG"
