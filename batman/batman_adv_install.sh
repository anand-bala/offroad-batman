#!/usr/bin/env bash
#
# Build and install the batman-adv kernel module via DKMS.
#
# Needed because CONFIG_BATMAN_ADV is unset in the L4T kernel and noble has no
# batman-adv-dkms package. Upstream supports Linux 5.10 - 7.2, so 6.8-tegra is
# in range.
#
#   ./install.sh              # build + install via DKMS
#   ./install.sh --uninstall  # remove
#
# Expects the batman-adv submodule to be checked out:
#   git submodule update --init batman/batman-adv

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SRC=batman-adv

log() { echo "==> $*"; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Read the version from dkms.conf rather than repeating it here, so the two
# cannot drift.
PACKAGE_NAME=$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p' dkms.conf)
PACKAGE_VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' dkms.conf)
DKMS_SRC=/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}

if [[ ${1:-} == --uninstall ]]; then
  log "Removing $PACKAGE_NAME/$PACKAGE_VERSION from DKMS..."
  as_root dkms remove -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" --all || true
  as_root rm -rf "$DKMS_SRC"
  log "Done. The module is gone; batctl (if installed) is left alone."
  exit 0
fi

if [[ ! -f $SRC/Makefile ]]; then
  >&2 echo "No $SRC/Makefile -- the submodule is not checked out."
  >&2 echo "Run: git submodule update --init batman/batman-adv"
  exit 1
fi

if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
  >&2 echo "No kernel build tree at /lib/modules/$(uname -r)/build."
  >&2 echo "Install the headers for the running kernel before continuing"
  >&2 echo "(Jetson: 'apt install nvidia-l4t-kernel-headers')."
  exit 1
fi

command -v dkms >/dev/null || { >&2 echo "dkms not installed."; exit 1; }

# Stage a copy rather than pointing DKMS at the working tree: kernel-upgrade
# rebuilds run long after this script, from /usr/src alone, and must not depend
# on the checkout still being present or still being on the same commit.
log "Staging sources into $DKMS_SRC..."
as_root rm -rf "$DKMS_SRC"
as_root mkdir -p "$DKMS_SRC"
as_root cp -a "$SRC/." "$DKMS_SRC/"
as_root rm -rf "$DKMS_SRC/.git"
as_root cp -a dkms.conf "$DKMS_SRC/"

log "Building and installing via DKMS..."
as_root dkms add -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" || true
as_root dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"

as_root depmod -a

log "Done. Verify with: modinfo batman-adv"
log "batctl comes from the distro: apt install batctl"
