# DikuMud Circle Mud Framework

This repository contains a minimal, modern Python framework for
building a DikuMud‑style MUD (Multi‑User Dungeon).  The goal is to
provide a clean, asynchronous codebase that can be extended with
features such as persistence, authentication, websockets, and a
rich scripting engine.

## Features

- **Asynchronous TCP server** – Uses `asyncio` to handle many
  concurrent connections.
- **Command dispatcher** – A simple registry that maps command
  names to async handlers.
- **Built‑in commands** – `help`, `quit`, and `echo`.
- **Extensible** – Add new commands, persistence layers, or
  networking protocols with minimal changes.

## Getting Started

### DOS Menu System

The repository contains a simple DOS/Win95/98 batch-file menu for swapping
`CONFIG.SYS` / `AUTOEXEC.BAT`, listing games, and loading SoundBlaster
settings.  To run the menu in DOSBox, you can use the provided wrapper
script `run_menu.sh`.

```bash
# Make the script executable
chmod +x run_menu.sh

# Launch the menu
./run_menu.sh
```

The script mounts the repository root as drive `C:` in DOSBox, sets the
output renderer to DirectX (which avoids the flickering issue), and runs
`menu/menu.bat`.

### Python Server

```bash
# Install dependencies (none required for the skeleton)
python -m pip install -r requirements.txt  # optional

# Run the server
python -m mud
```

Connect with telnet or any TCP client:

```bash
telnet localhost 4000
```

## Extending the Framework

- **Persistence** – Implement a `Player` model and store it in a
  database or file.
- **Authentication** – Add a login command and session handling.
- **Websockets** – Replace the TCP server with an `aiohttp`
  WebSocket handler.
- **Scripting** – Embed a scripting language (e.g., Lua or
  Python) for in‑game events.

## License

MIT License – see the LICENSE file.

---

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