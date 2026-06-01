#!/bin/bash
# Post-reboot turbo boost diagnostic — results written to /tmp/turbo-check.log
LOG=/tmp/turbo-check.log
exec > "$LOG" 2>&1

echo "=== TURBO CHECK $(date) ==="
echo ""

echo "--- BIOS Settings ---"
LD_LIBRARY_PATH=/opt/dell/dcc /opt/dell/dcc/cctk \
  --TurboMode --Speedstep --CStatesCtrl --IntelSpdSelTech 2>&1

echo ""
echo "--- intel_pstate state ---"
echo "status    = $(cat /sys/devices/system/cpu/intel_pstate/status)"
echo "no_turbo  = $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
echo "max_perf  = $(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)%"
echo "scaling_max_freq = $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)"

echo ""
echo "--- Power Limits ---"
echo "PL1 socket0 = $(cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw) uW"
echo "PL1 socket1 = $(cat /sys/class/powercap/intel-rapl/intel-rapl:1/constraint_0_power_limit_uw) uW"

echo ""
echo "--- Key MSRs (idle, no load) ---"
for cpu in 0 16; do
  echo "CPU $cpu:"
  for msr in 0x199 0x198 0x648 0x1A0 0x610 0x601 0x64C 0x64F; do
    val=$(rdmsr -p $cpu $msr 2>/dev/null || echo "unreadable")
    echo "  MSR $msr = 0x$val"
  done
done

echo ""
echo "--- Starting load (dnetc) ---"
cd /root/dnetc521-linux-amd64 2>/dev/null || cd /home/bdeeley/dnetc521-linux-amd64 2>/dev/null
./dnetc > /dev/null 2>&1 &
DNETC_PID=$!
sleep 12

echo ""
echo "--- Key MSRs (under load, 12s after start) ---"
for cpu in 0 16; do
  echo "CPU $cpu:"
  for msr in 0x199 0x198 0x648 0x64F; do
    val=$(rdmsr -p $cpu $msr 2>/dev/null || echo "unreadable")
    echo "  MSR $msr = 0x$val"
  done
done

echo ""
echo "--- PERF_CTL ceiling test: write ratio 40 ---"
wrmsr -p 0 0x199 0x2800 2>/dev/null
sleep 0.1
val=$(rdmsr -p 0 0x199)
echo "CPU0 PERF_CTL after writing 0x2800 = 0x$val"
if [ "0x$val" = "0x2100" ]; then
  echo "RESULT: STILL CLAMPED AT RATIO 33 — Cfg2 did NOT lift the ceiling"
else
  ratio=$(python3 -c "print((int('$val',16) >> 8) & 0xFF)")
  echo "RESULT: CEILING LIFTED — new ratio = $ratio = $((ratio * 100)) MHz"
fi

echo ""
echo "--- turbostat (5s sample) ---"
turbostat --interval 5 --quiet 2>/dev/null | head -4

echo ""
echo "--- Throttle reasons decoded ---"
for cpu in 0 16; do
  val=$(rdmsr -p $cpu 0x64F 2>/dev/null)
  python3 -c "
v = int('$val', 16)
reasons = {0:'PROCHOT',1:'Thermal',2:'RAPL',3:'PlatCfg',4:'MultiSkt',
           5:'TurboAtten',6:'RATL',7:'EDP',8:'TurboUnavail',9:'PL2',10:'PL1'}
active  = [n for b,n in reasons.items() if (v >> b) & 1]
logged  = [n for b,n in reasons.items() if (v >> (b+16)) & 1]
print(f'CPU $cpu: active={active or [\"none\"]}  logged={logged or [\"none\"]}')
  "
done

echo ""
echo "--- Core temps ---"
cat /sys/class/hwmon/hwmon*/temp*_input 2>/dev/null | \
  python3 -c "import sys; temps=[int(x)/1000 for x in sys.stdin]; print('Temps (C):', sorted(temps, reverse=True)[:8])"

echo ""
echo "=== DONE ==="

kill $DNETC_PID 2>/dev/null
pkill dnetc 2>/dev/null
