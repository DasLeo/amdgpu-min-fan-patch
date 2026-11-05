#!/bin/sh
# Install the patched R9700 minimum-fan-PWM amdgpu as a DKMS module.
# Run as root. Takes effect on the next reboot (amdgpu is in use, so it cannot
# be reloaded live). Rollback: ./rollback.sh
set -eu

SRC_DIR=/usr/src/amdgpu-minfan-1.0
PKG=amdgpu-minfan
VER=1.0
PARAM_FILE=/etc/modprobe.d/amdgpu-minfan.conf

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
SRC_TREE=${SRC_TREE:-/tmp/linux-7.4-rc1}
[ -d "$SRC_TREE/drivers/gpu/drm/amd" ] || { echo "no kernel tree at $SRC_TREE"; exit 1; }

echo "==> snapshot patched drivers/gpu/drm/amd from $SRC_TREE"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
git -C "$SRC_TREE" archive HEAD drivers/gpu/drm/amd | tar -x -C "$SRC_DIR"

echo "==> out-of-tree build shim (tracepoint include path)"
# In-tree the tracepoints resolve ../../drivers/gpu/drm/amd/amdgpu; outside the
# kernel source tree that path does not exist. "." + the -I$(src) ccflags the
# amdgpu Makefile already provides is the same file. (amdgpu_dm_trace.h does
# exactly this upstream.)
sed -i 's|^#define TRACE_INCLUDE_PATH ../../drivers/gpu/drm/amd/amdgpu$|#define TRACE_INCLUDE_PATH .|' \
	"$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h"
grep -q '^#define TRACE_INCLUDE_PATH \.$' \
	"$SRC_DIR/drivers/gpu/drm/amd/amdgpu/amdgpu_trace.h"

install -m 0644 "$(dirname "$0")/dkms.conf" "$SRC_DIR/dkms.conf"

echo "==> dkms install $PKG/$VER"
dkms remove -m $PKG -v $VER --all >/dev/null 2>&1 || true
dkms add -m $PKG -v $VER
dkms build -m $PKG -v $VER -k "$(uname -r)"
dkms install --force -m $PKG -v $VER -k "$(uname -r)"

echo "==> module parameter"
# amdgpu is a module here (not built-in), so a modprobe.d option is enough -
# no kernel command line / initramfs change needed.
printf 'options amdgpu min_fan_override=1\n' > "$PARAM_FILE"

echo "==> verification"
modinfo -F filename amdgpu
modinfo -F vermagic amdgpu
modinfo -F srcversion amdgpu
modinfo -p amdgpu | grep -q '^min_fan_override:' \
	|| { echo "FATAL: min_fan_override missing from the built module"; exit 1; }

cat <<EOF

Installed. Reboot to load it, then check:
  cat /sys/module/amdgpu/parameters/min_fan_override          # -> 1
  cat /sys/bus/pci/devices/0000:03:00.0/gpu_od/fan_ctrl/fan_minimum_pwm
                                                              # MINIMUM_PWM: 5 100
  cd /sys/bus/pci/devices/0000:03:00.0/gpu_od/fan_ctrl/ && echo 8 > fan_minimum_pwm && echo c > fan_minimum_pwm
Watch temperatures (radeontool/amdsmi/lact) before trusting a low floor.
Rollback: sudo $(dirname "$0")/rollback.sh
EOF
