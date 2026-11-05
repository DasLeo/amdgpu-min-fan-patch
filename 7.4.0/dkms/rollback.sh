#!/bin/sh
# Undo install.sh: stock amdgpu module, no min_fan_override option.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

dkms uninstall -m amdgpu-minfan -v 1.0 -k "$(uname -r)" || true
dkms remove -m amdgpu-minfan -v 1.0 --all || true
rm -rf /usr/src/amdgpu-minfan-1.0
rm -f /etc/modprobe.d/amdgpu-minfan.conf
depmod -a
echo "Removed. Reboot to get the stock amdgpu module back."
