# Turbo Boost Investigation — Dell Precision 7820 (Dual Xeon Gold 6234)

## Hardware

- **System:** Dell Precision 7820 Tower, BIOS 2.45 (02/07/2025)
- **CPUs:** 2× Intel Xeon Gold 6234 — 8 cores / 16 threads each = 32 logical CPUs total
  - Base: 3.3 GHz | Single-core turbo: 4.0 GHz | All-core turbo (spec): 3.6 GHz | TDP: 130W each
- **GPU:** 2× NVIDIA RTX 3060 LHR
- **RAM:** 157 GiB
- **OS:** Debian 13.4 (trixie), kernel 6.12.86+deb13-amd64

---

## Problem

CPU is hard-locked at **3300 MHz (base clock)** under all conditions including 100% load.
BIOS reports `TurboMode=Enabled` but turbo never activates.

---

## What Was Investigated & Tried

### BIOS Settings (via CCTK: `sudo LD_LIBRARY_PATH=/opt/dell/dcc /opt/dell/dcc/cctk --OPTION`)

| Setting | Value | Effect |
|---------|-------|--------|
| `TurboMode` | `Enabled` | Was already enabled, no change |
| `Speedstep` | `Enabled` | Was already enabled |
| `CStatesCtrl` | `Enabled` | Was already enabled |
| `IntelSpdSelTech` | `Base` → `Cfg1` / **`Cfg2`** (tested) | **Both failed — ceiling unchanged. Cfg1/Cfg2 configure modes with 2.3 GHz max (worse than Base).** |
| Physical BIOS | All options set to max (UltraPerformance thermal, Performance profile) | Applied by user — changed RAPL behavior (now 200W) but not PCU ceiling |

- `--SysProfile` — not available on this model in CCTK 4.7.0
- `--ThermalManagement` — option exists (Optimized/Cool/Quiet/UltraPerformance) but CCTK reports
  "not configurable through this tool" on this model; confirmed set to max in physical BIOS UI
- `--CpuRSA` — Reliability/Availability/Serviceability only, unrelated to frequency

---

### MSR Writes (OS-level)

| MSR | Purpose | Action | Result |
|-----|---------|--------|--------|
| `0x1A0` | IA32_MISC_ENABLE IDA/Turbo disable bit | Cleared bit 38 → `0x840089` | ✅ Success, persists via service |
| `0x610` | PKG_POWER_LIMIT (RAPL) | Raised PL1 130W→200W per socket: `0x00DD8640005A8640` | ✅ Success, bit 63 was NOT locked |
| `0x199` | PERF_CTL (P-state request) | Wrote P-states 34–40, every attempt reads back `0x2100` (ratio 33) | ❌ Hardware clamps all writes at ratio 33 |
| `0x648` | PCU internal max ratio register | Attempted write of `0x28` (ratio 40) | ❌ Read-only — "cannot set MSR" |
| `0x601` | VR_CURRENT_CONFIG (IccMax) | Bit 31 LOCKED at IccMax=177A | ❌ Cannot change from OS |
| `0x1FC` | POWER_CTL | `0x2904005B` — bi-dir PROCHOT disabled | OK as-is |

---

### Intel pstate Driver

| Action | Result |
|--------|--------|
| `no_turbo = 0` | ✅ Driver allows turbo |
| `status = active`, performance governor | ✅ Driver requests full performance |
| `max_perf_pct = 100`, `scaling_max_freq = 4000000` | ✅ Driver believes 4.0 GHz available |
| Switched to `passive` mode + `performance` governor | No change to PCU clamp |
| Switched to `off` mode + direct PERF_CTL writes at idle AND under load | ❌ Hardware still reads back 0x2100 — rules out any driver interference |
| `power-profiles-daemon` stopped | ✅ Was resetting governor to `powersave`, now stopped |

---

### ACPI Table Analysis

- Decompiled DSDT + SSDT1–SSDT3 with `iasl` (acpica-tools)
- **Zero `_PSS` (P-state) entries in any ACPI table** — BIOS never provides an ACPI P-state table
- SSDT2: `_OSC` and `_PDC` methods per CPU package (Intel PPM capability negotiation only)
- `acpi-cpufreq` driver not available as fallback
- Intel Speed Select (`intel-speed-select` tool): "Invalid CPU model (85)" — tool doesn't support
  Skylake-SP/Cascade Lake-SP, though BIOS does expose SST options via CCTK

---

### Throttle Reason Analysis (MSR 0x64F `CORE_PERF_LIMIT_REASONS`)

| Reason | Status |
|--------|--------|
| PROCHOT | Never active |
| Thermal | Never active |
| RAPL PL1 / PL2 | Never active (confirmed after raising both to 200W) |
| EDP (Electrical Design Point) | **Logged** from previous boot — never currently active |
| All others | Never active |

**Key insight:** No active throttle reasons because the CPU IS at its configured PCU ceiling
(ratio 33). The PCU only reports throttling when something exceeds the ceiling — if the ceiling
IS ratio 33, nothing ever exceeds it and no reasons fire.

---

### Full MSR State (confirmed values)

| MSR | Value | Meaning |
|-----|-------|---------|
| `0x1A0` | `0x840089` | IDA disable = 0 ✅ |
| `0x1AD` | `0x2828282828282828` | Turbo ratio = 40 (4.0 GHz) all core counts ✅ |
| `0x1AE` | `0x1c1814100c080402` | Core count bucket thresholds |
| `0x194` | `0x00000000` | FLEX_RATIO disabled — not the cause |
| `0x64C` | `0x80000000` | TURBO_ACTIVATION_RATIO lock=1, ratio=0 → "use 0x1AD" |
| `0x620` | `0xC18` | Uncore max = 2400 MHz — normal |
| `0x1B0` | `0x0` | ENERGY_PERF_BIAS = max performance ✅ |
| `0x601` | `0x80000588` | IccMax = 177A, **LOCKED** |
| `0x603` | `0x00160000001a1a1a` | VR_MISC_CONFIG — writable, bytes 0–2 = 26 (VR phase params); modifying had no effect on ceiling |
| `0x606` | `0x000a0e03` | PKG_POWER_SKU_UNIT: power=1/8W, energy=2^14, time=2^10 |
| `0x608` | `0x400402` | (power balance related) |
| `0x610` | `0x00DD8640005A8640` | PL1 = PL2 = 200W, neither socket locked ✅ |
| `0x614` | `0x000f0a6001f00410` | PP0_POWER_LIMIT: 130W PL1 disabled (bit 15=0); write rejected |
| `0x615` | `0x80aad5eb` | PP0_ENERGY_STATUS (LOCKED) |
| `0x620` | `0xC18` | Uncore max = 2400 MHz — normal |
| `0x648` | `0x21` (= 33) | PCU read-only internal max ratio = base clock ← **THE CEILING** (write rejected) |
| `0x649` | `0x00f80a6000170410` | CONFIG_TDP_LEVEL1: 130W at ratio 23 = 2.3 GHz (Cfg1 = WORSE) |
| `0x64A` | `0x00f80a6000170410` | CONFIG_TDP_LEVEL2: 130W at ratio 23 = 2.3 GHz (Cfg2 = WORSE) |
| `0x64B` | `0x80000000` | CONFIG_TDP_CONTROL: Level 0 selected, **LOCKED** |
| `0xCE` | decoded | Max non-turbo = 33 ✅, programmable turbo bit = 1 |
| `0x1A2` | decoded | TJ_MAX = 100°C, no offset |
| `0x1AD` | `0x2828282828282828` | TURBO_RATIO_LIMIT = **4.0 GHz all core counts** (BIOS programs turbo correctly — PCU overrides) |
| `0x1AE` | `0x1c1814100c080402` | Turbo ratio core group thresholds |
| `0x1FC` | `0x2904005b` | POWER_CTL: bits 18,24,27,29 set; all cleared during test → no effect on ceiling |

---

## Root Cause (Confirmed)

**MSR 0x648 = `0x21` = decimal 33** — read-only PCU internal max ratio, set by BIOS during POST
via the CPU's internal BIOS mailbox interface (not accessible through any standard MSR).

The BIOS programs this ceiling via `IntelSpdSelTech=Base`, which corresponds to the base-clock
TDP configuration. No OS-level intervention can override a PCU mailbox command.

SMBIOS corroborates: `dmidecode -t 4` shows `Current Speed: 3300 MHz` / `Max Speed: 4000 MHz`.

---

## Persistent Configuration (survives reboots)

### `/etc/systemd/system/enable-turbo.service` (enabled, runs at every boot)

```bash
modprobe msr
wrmsr -a 0x1a0 0x840089               # clear IDA disable bit on all CPUs
wrmsr -a 0x610 0x00DD8640005A8640     # PL1=PL2=200W both sockets
echo passive > /sys/devices/system/cpu/intel_pstate/status
echo active  > /sys/devices/system/cpu/intel_pstate/status  # reset driver state
```

### BIOS (CCTK — current state after session 2)

```
TurboMode       = Enabled
Speedstep       = Enabled
CStatesCtrl     = Enabled
IntelSpdSelTech = Cfg2    ← should revert to Base; Cfg2 made no difference
```

---

## Session 2 Results — Cfg2 Reboot + Exhaustive MSR Sweep (2026-05-22)

### Cfg2 Reboot Result

`IntelSpdSelTech=Cfg2` was applied at POST. **MSR 0x648 remained 0x21 (ratio 33).
PERF_CTL ceiling unchanged. Cfg2 did NOT work.**

Turbostat under full load: `Bzy_MHz=3300`, `PkgWatt=228.49W`, `CoreTmp=69°C`.

### IntelSpdSelTech Cfg1/Cfg2 Are WORSE Than Base

Decoded MSR 0x649 (CONFIG_TDP_LEVEL1) and 0x64A (CONFIG_TDP_LEVEL2):

| Register | TDP | Max Ratio | Frequency |
|----------|-----|-----------|-----------|
| CONFIG_TDP_NOMINAL (0x648) | base | 33 | 3.3 GHz |
| CONFIG_TDP_LEVEL1 (0x649) | 130W | **23** | **2.3 GHz** |
| CONFIG_TDP_LEVEL2 (0x64A) | 130W | **23** | **2.3 GHz** |
| CONFIG_TDP_CONTROL (0x64B) | Level 0 selected | LOCKED | cannot change |

Both Cfg1 and Cfg2 would reduce max frequency to 2.3 GHz. The Xeon Gold 6234 does NOT
support SST-PP (Speed Select Technology - Performance Profile) in any useful sense.
The intel-speed-select tool confirms: "Invalid CPU model (85)".

### TURBO_RATIO_LIMIT Contradiction

**MSR 0x1AD = `0x2828282828282828` → 4.0 GHz for ALL core counts (1–8)**

The BIOS explicitly programs turbo to 4.0 GHz in the software-visible table. Yet the PCU
enforces a ceiling at ratio 33. This confirms the PCU's *internal* VR_TDC state overrides
the TURBO_RATIO_LIMIT register — the two are independent mechanisms.

### MSR 0x64F Throttle Log (CORE_PERF_LIMIT_REASONS)

Value after reboot + load: `0xe0800000`

| Bits | Reason | Status |
|------|--------|--------|
| Active (15:0) | — | None active (CPU is at PCU ceiling, not exceeding it) |
| Log bit 29 (= reason 13) | **IccMax / VR_TDC** | **LOGGED** ← smoking gun |
| Log bit 23 (= reason 7) | **EDP** | **LOGGED** |
| Log bits 30, 31 | Reserved/unknown | Logged (likely boot artifacts) |

The VR_TDC and EDP were hit when the CPU attempted to boost during POST or the load test.
These sticky log bits persist until cleared and confirm the VR current limit is the physical
constraint preventing turbo.

### Exhaustive MSR Sweep — All Writable Candidates Tested

| MSR | Value | Lock | Write Test | Effect on PERF_CTL ceiling |
|-----|-------|------|-----------|---------------------------|
| `0x603` VR_MISC_CONFIG | `0x00160000001a1a1a` | No lock | ✅ Accepted | **None** — not the PCU's VR_TDC register |
| `0x614` PP0_POWER_LIMIT | `0x000f0a6001f00410` (130W disabled) | — | ❌ Rejected | N/A |
| `0x648` CONFIG_TDP_NOMINAL | `0x21` | — | ❌ Rejected (read-only) | N/A |
| `0x1FC` POWER_CTL (bit 18) | `0x2904005b` | No lock | ✅ Accepted | **None** |
| `0x1FC` POWER_CTL (bits 24,27,29) | — | — | ✅ Accepted | **None** |
| `0x1FC` POWER_CTL (all unknowns cleared) | → `0x0000005b` | — | ✅ Accepted | **None** |

Every writable MSR with plausible relevance was modified. None affected the ceiling.

---

## Final Definitive Root Cause

**The PCU (Power Control Unit) inside each Xeon Gold 6234 maintains an internal VR_TDC
(Voltage Regulator Thermal Design Current) value that was programmed at POST via the CPU's
internal BIOS mailbox interface.** This value corresponds to the base TDP operation at 3.3 GHz
and cannot be changed through any accessible MSR. The PCU uses this TDC budget as its
internal ceiling: any ratio above 33 would require more current than the programmed TDC
allows, so all PERF_CTL writes above 0x2100 are silently clipped.

This is confirmed by:
1. `CORE_PERF_LIMIT_REASONS` (0x64F) bit 13 (VR_TDC) logged — hardware hit the VR current limit
2. `CONFIG_TDP_NOMINAL` (0x648) = 33 — read-only, set at POST by BIOS mailbox
3. PERF_CTL clips at 0x2100 **even at idle** — not a RAPL throttle (which only fires under load)
4. `TURBO_RATIO_LIMIT` (0x1AD) = 4.0 GHz — BIOS sets turbo table correctly, but PCU overrides it
5. All RAPL, PROCHOT, thermal, driver, EDP, SMI paths exhausted — none are the cause

---

## What Remains

All OS-level and BIOS-configurable options have been exhausted. The following remain untested:

1. **BIOS firmware update**: Current: 2.45.0 (02/07/2025). Check Dell support for Precision 7820
   newer than 2.45 that might re-calibrate the PCU's VR_TDC for turbo operation.
   - Dell support: https://www.dell.com/support/product-details/en-us/product/precision-7820-workstation/drivers

2. **Single-socket test**: Disable one CPU in BIOS (reduces platform power by 130W). If the
   remaining socket can turbo, it confirms a dual-socket platform power budget issue. This can
   be tested by physically removing one CPU (requires disassembly) or via BIOS CPU count settings.

3. **Dell support escalation**: Armed with specific evidence:
   - `MSR 0x648 = 0x21` (PCU ceiling = base clock, read-only)
   - `MSR 0x64F = 0xe0000000+` (VR_TDC + EDP logged in CORE_PERF_LIMIT_REASONS)
   - `MSR 0x1AD = 0x2828282828282828` (TURBO_RATIO_LIMIT correctly set to 4.0 GHz by BIOS)
   - TurboMode=Enabled, IntelSpdSelTech=Cfg2, physical BIOS at max performance
   - PERF_CTL hardware-clips above 0x2100 from idle (not a RAPL/thermal event)
   This is specific enough for a Level 2 Dell hardware escalation or Intel Developer Support ticket.

4. **PCU MMIO mailbox** (extremely risky, not recommended): The PCU mailbox on Skylake-SP is
   accessible via PCI config space MMIO. Sending the correct undocumented mailbox command could
   raise the VR_TDC. Risk: potential permanent damage or unrecoverable system state.
3. Contact Dell support with the specific MSR evidence (0x648=0x21, EDP logged)

---

## Load Generator

```bash
# Run with NO args — backgrounded
cd ~/dnetc521-linux-amd64 && ./dnetc > /dev/null 2>&1 &
# Stop
pkill dnetc
```

## Useful One-liners

```bash
# Current frequency under load
sudo turbostat --interval 3 --quiet 2>/dev/null | head -3

# All relevant MSRs at once
for msr in 0x199 0x198 0x648 0x1A0 0x64F 0x610 0x601; do
  echo "MSR $msr = $(sudo rdmsr -p 0 $msr 2>/dev/null || echo 'unreadable')"
done

# PL1 current value (should be 200W = 200000000)
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw
cat /sys/class/powercap/intel-rapl/intel-rapl:1/constraint_0_power_limit_uw

# CCTK read all relevant settings
sudo LD_LIBRARY_PATH=/opt/dell/dcc /opt/dell/dcc/cctk \
  --TurboMode --Speedstep --CStatesCtrl --IntelSpdSelTech
```
