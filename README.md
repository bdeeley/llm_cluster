## System Notes

### CPU Turbo Boost Fix (Dell Workstation – Xeon Gold 6234, May 2026)

**Symptom:** CPU stuck at base clock (3.3 GHz) under full load. Turbo never engaged despite BIOS showing `TurboMode=Enabled` and `Speedstep=Enabled`.

**Root cause:** `intel_pstate` was running in **active** mode but HWP (Hardware P-States / Speed Shift) was disabled (`IA32_PM_ENABLE = 0`). In this state the driver only ever writes base clock ratio (0x21 = 33 × 100 MHz = 3.3 GHz) to `PERF_CTL` and never requests turbo — regardless of governor setting.

**Confirmed by:**
- `PERF_CTL` (MSR 0x199) = `0x2100` → requesting only base clock
- `IA32_PM_ENABLE` (MSR 0x770) = `0` → HWP not enabled
- Forcing PERF_CTL to ratio 40 (4 GHz) was immediately reset back to ratio 33 by the driver

**Fix:** Switch `intel_pstate` to **passive** mode (uses `intel_cpufreq` driver), which manages P-states via the standard cpufreq framework without requiring HWP.

**Immediate (runtime):**
```bash
echo passive | sudo tee /sys/devices/system/cpu/intel_pstate/status
sudo cpupower frequency-set -g performance
```

**Permanent (survives reboot):**

1. Add `intel_pstate=passive` to kernel parameters in `/etc/default/grub`:
   ```
   GRUB_CMDLINE_LINUX_DEFAULT="... intel_pstate=passive"
   ```
   Then run `sudo update-grub`.

2. Enable the performance governor systemd service (already created):
   ```bash
   sudo systemctl enable cpu-performance.service
   # service file: /etc/systemd/system/cpu-performance.service
   ```

**Result:** All cores immediately reached 4.0 GHz turbo after applying the fix.

> **Important:** After editing `/etc/default/grub`, always verify the parameter landed in `grub.cfg` before rebooting:
> ```bash
> sudo update-grub
> sudo grep intel_pstate /boot/grub/grub.cfg
> ```
> The first reboot failed to turbo because `update-grub` had not yet regenerated `grub.cfg` (the old cmdline was still active). Always confirm the grep shows the parameter before rebooting.