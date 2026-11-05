# amdgpu-min-fan-patch

> [!WARNING]
> ⚠️ **Use at your own risk — you are solely responsible for any hardware
> damage.** This patch lowers the GPU fan's minimum PWM below the value your
> board's VBIOS was shipped with. Running the fan slower than it can safely
> sustain can cause the GPU to overheat and can permanently damage the card
> (and, in a worst case, surrounding hardware). The authors accept **no
> liability** for any damage resulting from applying or using this patch.
>
> Before applying it you **must** have proper temperature monitoring in place
> and a working emergency shutdown / thermal-failsafe (e.g. a watchdog that
> cuts load or powers the system off on an over-temperature event). If you
> cannot guarantee that, do not use this patch. Validate thoroughly on your
> own hardware first and watch temperatures closely after any fan change.

A single, self-contained Linux kernel patch that adds native AMDGPU support
for a sub-20% **minimum fan PWM** on the PowerColor **Radeon AI PRO R9700**
(Navi 48, SMU 14.0.2) through the standard OverDrive interface — while keeping
the fan in automatic (temperature-controlled) mode.

It makes tools such as **LACT** work out of the box and removes the need for
the external `r9700_fan_min` out-of-tree module.

> ### 🙏 Acknowledgements
> This project builds directly on the pioneering work of
> [@arczewski](https://github.com/arczewski) and his
> [r9700-tune](https://github.com/arczewski/r9700-tune) project. Without his
> reverse-engineering of the R9700's SMU 14.0.2 OverDrive table and his working
> `r9700_fan_min` reference implementation, this native driver integration
> would not have been possible. Thank you!

> Sibling of [r9700-tune](https://github.com/arczewski/r9700-tune): same card,
> same MIT license, complementary goal. That project caps the GPU clock /
> power limit and uploads a fan curve from userspace; this one fixes the
> minimum-PWM floor and the automatic-fan regression **inside the driver**.

## Contents

    LICENSE                                                          MIT (inherited from r9700-tune)
    README.md
    7.3.0/0001-amdgpu-r9700-fan-overdrive-support.patch                the patch (Linux / CachyOS 7.3.0)
    7.4.0/0001-amdgpu-r9700-fan-overdrive-support.patch                the patch rebased onto v7.4-rc1+
    7.4.0/dkms/                                                      DKMS packaging for distro kernels
                                                                       (install.sh / rollback.sh / dkms.conf)

## Background: why the R9700 minimum fan PWM is wrong

Two independent problems live in the SMU 14.0.2 OverDrive path
(`drivers/gpu/drm/amd/pm/swsmu/smu14/smu_v14_0_2_ppt.c`):

| Problem | Root cause |
|---|---|
| **Minimum PWM is pinned to ≥ 20%** | The R9700 VBIOS advertises `OverDriveLimitsBasicMin.FanMinimumPwm = 20`. The driver rejects anything below it. This is VBIOS conservatism, **not** a hardware limit — the SMU happily accepts a much lower floor. |
| **Setting the minimum PWM kills auto fan control** | `PP_OD_EDIT_FAN_MINIMUM_PWM` forces the fan into fixed-PWM "legacy" mode (`FAN_LEGACY_BIT`, clearing `FAN_CURVE_BIT`), so the fan stops ramping with temperature. Every *other* auto-mode fan setting in that function keeps `FAN_CURVE_BIT`, and the SMU13 reference driver uses `FAN_CURVE_BIT` too — minimum PWM was the sole inconsistent case. |

On top of that, the external `r9700_fan_min` module uploads the table directly,
bypassing AMDGPU's cached OverDrive bookkeeping, so the driver's reported
`FanMinimumPwm` goes stale and later re-uploads can fight it. Routing the
change through the driver's normal OverDrive path fixes all three.

## What the patch does

Opt-in, gated behind the new **`amdgpu.min_fan_override`** module parameter
(default `0`) **and** Navi 48 (PCI device `0x7551`, i.e. SMU 14.0.2 — guaranteed
by the file the code lives in). When enabled it:

- relaxes the advertised minimum fan PWM floor to **5%**, so the standard
  `gpu_od/fan_ctrl/fan_minimum_pwm` sysfs interface accepts lower values;
- keeps the fan in automatic (fan-curve) mode when the minimum PWM is changed,
  instead of switching to legacy mode.

Everything is done through the driver's existing OverDrive state machine,
locking (`adev->pm.mutex`) and firmware error propagation, so AMDGPU's cached
OverDrive table stays consistent with the active SMU configuration and no
stale value is reported to userspace. No parallel SMU-upload path is added.

### Scope & safety

- **No-op unless opted in.** On every other ASIC — and on R9700 boards whose
  owner does not set the parameter — behavior is byte-for-byte unchanged.
- **Fan minimum PWM only.** Clocks, memory clocks, voltage, power limits,
  acoustic target/limit, temperature target, zero-RPM and the fan curve are
  left untouched.
- **No safety bypass.** The firmware still validates every value and rejects
  out-of-range ones with `OD_FAN_MIN_PWM_ERROR`.

## Applying inside the CachyOS `linux-cachyos-bore` PKGBUILD

The PKGBUILD `prepare()` applies every `*.patch` listed in `source=( ... )`
with `patch -Np1`, so no other edit is needed:

1. Copy the patch next to the PKGBUILD:

   ```bash
   cp 7.3.0/0001-amdgpu-r9700-fan-overdrive-support.patch \
      /path/to/linux-cachyos-bore/
   ```

2. Add it to the `source=( ... )` array:

   ```text
   source=(
       ...
       "0001-amdgpu-r9700-fan-overdrive-support.patch"
   )
   ```

3. Build as usual — LLVM/Clang Full-LTO is fine (plain compiled driver C, no
   hidden-symbol tricks):

   ```bash
   makepkg -s
   ```

The patch is self-contained and independent of this repository's layout, so it
drops into any packaging flow that applies patches at `-p1`.

## Applying to a kernel 7.4-rc1 or newer

Use `7.4.0/0001-amdgpu-r9700-fan-overdrive-support.patch`. It is the same
change rebased onto `v7.4-rc1`; the 7.3.0 file does **not** apply there (two
hunks fail, and with `patch -Np1 -F3` one silently lands in the
`FAN_TARGET_TEMPERATURE` case — do not use fuzz on this patch).

The only semantic difference: the `smu_v14_0_2_od_restore_table_single()` hunk
is dropped, because upstream no longer forces `FAN_LEGACY_BIT` there, so there
is nothing left to gate.

## Applying to a distro kernel without rebuilding it (`amdgpu=m`)

Most distro kernels build amdgpu as a **module**, so a full kernel rebuild is
not required — the patched module can be built out-of-tree against the
installed headers, which makes `vermagic` and the `MODVERSIONS` CRCs match the
running kernel (the export CRCs are unchanged by this patch, so `amdxcp` and
the rest of the stack load unaffected). `7.4.0/dkms/install.sh` wraps that as
a DKMS package:

```bash
cd 7.4.0/dkms && sudo SRC_TREE=/path/to/patched/7.4.0-rc1 ./install.sh
sudo reboot
```

`AUTOINSTALL="yes"`, so it rebuilds on later kernel installs; if a future
kernel's source no longer compiles, DKMS install fails and that kernel keeps
its stock amdgpu. Roll back with `sudo ./rollback.sh` (it restores the stock
module DKMS archived).

Two shims are needed for an out-of-tree amdgpu build, both applied by
`install.sh`:

- `amdgpu_trace.h`: `TRACE_INCLUDE_PATH ../../drivers/gpu/drm/amd/amdgpu` →
  `.`, since that in-tree path does not exist outside a full kernel source
  tree (`amdgpu_dm_trace.h` already uses `.` upstream).
- `M=` in `dkms.conf` must be **absolute** — kbuild resolves a relative `M=`
  against the `-C` directory (the headers), not the build directory.

## Runtime verification

Enable the override, then reboot. If `amdgpu` is **built-in** (the CachyOS
case above) use the kernel command line (`GRUB_CMDLINE_LINUX_DEFAULT`, then
`grub-mkconfig`):

```text
amdgpu.min_fan_override=1
```

If `amdgpu` is a **module**, a modprobe option is enough (no initramfs or
bootloader change needed):

```bash
echo 'options amdgpu min_fan_override=1' | sudo tee /etc/modprobe.d/amdgpu-minfan.conf
```

For the GPU at `0000:03:00.0`:

```bash
# the parameter took effect:
cat /sys/module/amdgpu/parameters/min_fan_override          # -> 1

# the floor is now 5% (was 20% on the board this was written against, 25% on
# the PowerColor card it was verified on — the VBIOS decides):
cat /sys/bus/pci/devices/0000:03:00.0/gpu_od/fan_ctrl/fan_minimum_pwm
#   FAN_MINIMUM_PWM:
#   25
#   OD_RANGE:
#   MINIMUM_PWM: 5 100

# set 8% and commit through the standard interface (auto control preserved):
cd /sys/bus/pci/devices/0000:03:00.0/gpu_od/fan_ctrl/
echo 8 > fan_minimum_pwm
echo c > fan_minimum_pwm

# clocks / voltage / power are unchanged:
cat /sys/bus/pci/devices/0000:03:00.0/pp_od_clk_voltage

# the fan is still in automatic mode: the reported PWM must sit ABOVE the
# floor and move with load. Fixed-PWM legacy mode pins it to exactly the
# value you set:
rocm-smi -f -t   # e.g. floor 10%, Fan Level 27% on the loaded card
```

Expected: the idle fan spins slower, and it still ramps up under load
(automatic control preserved). LACT can now set a sub-20% minimum PWM directly.

## Rollback

- **Keep the override off:** omit `amdgpu.min_fan_override=1` — behavior is then
  100% stock (20% floor, legacy-on-set).
- **Remove entirely:** drop the patch from `source=( ... )` and rebuild.
- **Fallback:** the external `r9700_fan_min` module remains untouched and works.

## Applying to a vanilla kernel source

```bash
tar xf linux-7.3.0.tar.xz && cd linux-7.3.0
git init -q            # optional, for a clean diff/track
git apply  /path/to/7.3.0/0001-amdgpu-r9700-fan-overdrive-support.patch
# or:  patch -Np1 < /path/to/7.3.0/0001-amdgpu-r9700-fan-overdrive-support.patch
```

## Limitations

- Actual fan-RPM behavior under load should be confirmed on real hardware.
- The 5% floor is validated for subsystem `148c:2443`; other boards may differ,
  but the firmware still enforces its own lower bound via `OD_FAN_MIN_PWM_ERROR`.
- The advertised stock floor is board-specific (20% and 25% both observed), so
  read `OD_RANGE` before assuming a number.
- Verified on 7.4.0-rc1 with `amdgpu=m`: patched module loaded,
  `min_fan_override=1`, floor reported as 5 on two R9700s, 10% accepted and
  committed via LACT, fan still ramping with load, no OD/SMU errors in dmesg.
- Full-kernel LTO *link* was not run here; per-file compilation was validated
  with the exact kernel flags including `-flto`, and the code contains no
  LTO-hostile constructs.

## License

MIT — inherited from [r9700-tune](https://github.com/arczewski/r9700-tune)
(see `LICENSE`). The kernel patch itself is **GPL-2.0**, as required for any
code that links into the Linux kernel.
