#!/usr/bin/env bash

set -euo pipefail

# DKMS POST_INSTALL hook: install the MM8108 firmware images and BCFs into
# /lib/firmware/morse.
#
# DKMS resolves POST_INSTALL relative to the source tree and runs it after
# `dkms install` -- which means both on first install and on every
# kernel-upgrade autoinstall. That re-run is redundant (firmware is
# kernel-independent) but harmless: morse-firmware's install target uses
# `install -D`, so it is idempotent, and it self-heals if the firmware
# directory is ever clobbered.
#
# Removal is deliberately NOT hooked to POST_REMOVE. DKMS's lifecycle is
# per-kernel, so `dkms remove -k <old-kernel>` fires during routine kernel
# cleanup; deleting the firmware there would break the module still installed
# for the running kernel. Use `morse_micro_install.sh --uninstall` instead.

# Resolve paths against this script's own location rather than the working
# directory, so it does not depend on where DKMS chooses to invoke it from.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

echo "==> Installing Morse Micro firmware into /lib/firmware/morse"
make -C morse-firmware install
