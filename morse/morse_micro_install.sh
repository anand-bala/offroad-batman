#!/usr/bin/env bash

set -euo pipefail

# Native build + install of the Morse Micro MM8108 stack on an Ubuntu device
# (e.g. NVIDIA Jetson) with the USB dongle attached. Unlike the Gateworks
# cross-build, openssl / libnl / libusb come from the distro, so nothing is
# built out of tree and everything links dynamically.
#
# Installs:
#   - morse.ko + dot11ah.ko via DKMS (rebuilt automatically on kernel upgrade)
#   - firmware and BCFs into /lib/firmware/morse, via the DKMS POST_INSTALL hook
#   - hostapd_s1g, wpa_supplicant_s1g and friends, morse_cli into $BINDIR
#
# Usage: morse_micro_install.sh [--uninstall]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PACKAGE_NAME=morse
PACKAGE_VERSION=2.0.0
BINDIR=${BINDIR:-/usr/local/sbin}
COUNTRY=${COUNTRY:-US}

as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# dkms pulls in the kernel headers meta-package on Ubuntu, but on Jetson the
# headers come from nvidia-l4t-kernel-headers and are already present.
APT_DEPS=(
  dkms
  build-essential
  bison
  flex
  pkg-config
  libnl-3-dev
  libnl-genl-3-dev
  libnl-route-3-dev
  libssl-dev
  libusb-1.0-0-dev
)

missing=()
for pkg in "${APT_DEPS[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" ||
    missing+=("$pkg")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  log "Installing build dependencies (root required): ${missing[*]}"
  as_root apt-get update
  as_root apt-get install -y "${missing[@]}"
fi

if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
  >&2 echo "No kernel build tree at /lib/modules/$(uname -r)/build."
  >&2 echo "Install the headers for the running kernel before continuing"
  >&2 echo "(Jetson: 'apt install nvidia-l4t-kernel-headers')."
  exit 1
fi

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

log "Checking out submodules..."
git submodule update --init --recursive

# ---------------------------------------------------------------------------
# Driver (DKMS)
# ---------------------------------------------------------------------------

# Local fixups to morse_driver are declared as PATCH[#] in dkms.conf rather
# than applied here: DKMS re-applies them to a fresh copy of the sources on
# every build, so they survive kernel-upgrade rebuilds and the vendor
# submodule in this checkout is never dirtied.

# DKMS wants the sources under /usr/src/<name>-<version>. Copy rather than
# symlink: dkms resolves the tree at build time on every kernel upgrade, and a
# symlink into a user's home directory is a footgun once that tree moves.
if dkms status -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" 2>/dev/null | grep -q .; then
  log "Removing previous DKMS registration of ${PACKAGE_NAME}/${PACKAGE_VERSION}"
  as_root dkms remove -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION" --all || true
fi

DKMS_SRC=/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}

log "Staging driver sources into $DKMS_SRC"
as_root rm -rf "$DKMS_SRC"
as_root mkdir -p "$DKMS_SRC"
as_root cp -a dkms.conf "$DKMS_SRC/"
as_root cp -a patches "$DKMS_SRC/"
as_root cp -a morse_driver "$DKMS_SRC/"
# The POST_INSTALL hook and the firmware it installs have to live in the source
# tree too: DKMS re-runs the hook from there on every kernel-upgrade
# autoinstall, long after this script and this checkout are out of the picture.
as_root install -m 0755 install-firmware.sh "$DKMS_SRC/"
as_root cp -a morse-firmware "$DKMS_SRC/"
as_root rm -rf "$DKMS_SRC/morse-firmware/.git"
# Kernel-upgrade rebuilds run from the staged dkms.conf alone, with none of
# this script's environment, so $COUNTRY has to be baked into that copy or the
# compiled-in regdomain silently drifts from /etc/modprobe.d/morse.conf below.
as_root sed -i -e "s/^\( *CONFIG_MORSE_COUNTRY=\).*\(\\\\\)$/\1$COUNTRY \2/" "$DKMS_SRC/dkms.conf"
# Drop the submodule's git metadata; only the sources need to survive here,
# and .git is a file pointing back at this checkout's .git/modules anyway.
as_root rm -rf "$DKMS_SRC/morse_driver/.git"

log "Building and installing the driver via DKMS"
as_root dkms add -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
as_root dkms build -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"
as_root dkms install -m "$PACKAGE_NAME" -v "$PACKAGE_VERSION"

log "Setting module parameters"
as_root mkdir -p /etc/modprobe.d
echo "options morse country=$COUNTRY" | as_root tee /etc/modprobe.d/morse.conf >/dev/null

# ---------------------------------------------------------------------------
# hostapd_s1g / wpa_supplicant_s1g
# ---------------------------------------------------------------------------

# CFLAGS and LIBS must reach hostap through the ENVIRONMENT, never as make
# command-line assignments. hostap accumulates both with `+=` -- the include
# paths at wpa_supplicant/Makefile:68-69 and src/lib.rules:13, and 30-odd
# `LIBS +=` lines driven by .config -- and a command-line assignment overrides
# every one of them. Doing that strips the -I paths (fatal: utils/includes.h:
# No such file) and, once that is past, every feature library at link time.
#
# Because we define CFLAGS at all, src/build.rules:33 `ifndef CFLAGS` no longer
# fires, so its defaults have to be reproduced here: -MMD generates the .d
# files that make incremental rebuilds correct, and without -O2 the build is
# unoptimised.
#
# Note the missing -Wall, which build.rules:34 does include. hostap compiles
# with its own -Wextra -Werror (Makefile:60,67), so adding -Wall does not just
# surface more warnings -- it promotes them to hard errors across a vendor tree
# we do not control. It fails on, for example, the unused `i` at
# src/ap/ap_config.c:849, which is declared for CONFIG_WPS || CONFIG_HS20 but
# only used under CONFIG_WPS. -Wunused-variable comes from -Wall, not -Wextra,
# so hostap's intended warning level stays intact without it.
HOSTAP_CFLAGS="-MMD -O2 -g"
HOSTAP_CFLAGS+=" -D_GNU_SOURCE -I$ROOT/morse_cli"
HOSTAP_CFLAGS+=" -Wno-deprecated-declarations"
# gcc 14+ (Ubuntu 24.04 / JetPack 7) makes implicit-function-declaration an
# error by default. hostap appends its own -Werror after our flags
# (Makefile:60,67), but -Wno-error= for a specific warning still wins over a
# later blanket -Werror, so this survives that ordering.
HOSTAP_CFLAGS+=" -Wno-error=implicit-function-declaration"

# Warnings that newer compilers added and that hostap's -Werror turns fatal on
# vendor code we do not control. These cannot be added unconditionally: gcc
# rejects -Wno-error= for a warning it does not know ("no option -W...") as a
# hard error, so listing one here would break every older gcc. Probe first.
#
#   -Wunterminated-string-initialization: added to -Wextra in gcc 14, fires 45
#   times on the vendor's own src/utils/morse.c (the cc_list country-code
#   tables, which intentionally store 2 chars in char[2] with no NUL).
cflag_supported() {
  echo 'int main(void){return 0;}' |
    "${CC:-gcc}" -x c "$1" -c - -o /dev/null 2>/dev/null
}
for _flag in -Wno-error=unterminated-string-initialization; do
  if cflag_supported "$_flag"; then
    HOSTAP_CFLAGS+=" $_flag"
  fi
done
unset _flag
HOSTAP_LIBS="-lnl-3 -lnl-genl-3 -lm -lpthread -lcrypto -lssl"

# hostap stamps the binary with `git describe --dirty=+`
# (wpa_supplicant/Makefile:71-78). The MorseMicro fork carries only unannotated
# tags, so that prints "fatal: no annotated tags can describe ..." on stderr.
# It is noise rather than a failure -- $(shell) yields empty, the `ifneq` guard
# then skips the define -- but the version string it would have produced is
# redundant next to MORSE_VERSION at Makefile:82, so turn the block off.
export CONFIG_NO_GITVER=y

# Options to flip relative to each component's shipped defconfig. The vendor
# script collapses these into single backslash-continued strings and then loops
# over them as if they were arrays, so every sed misses and both daemons get
# built straight from defconfig; real arrays here.
#
# Dropped from the vendor's list: CONFIG_DEBUG_SYSLOG_FACILITY. defconfig:433
# spells it "#CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON", which the "=y" sed
# below cannot match, and CONFIG_DEBUG_SYSLOG is already on at defconfig:431.
WPA_S_ENABLE=(
  CONFIG_DRIVER_NL80211_QCA
  CONFIG_EAP_MD5
  CONFIG_EAP_MSCHAPV2
  CONFIG_EAP_TLS
  CONFIG_EAP_TLSV1_3
  CONFIG_EAP_PEAP
  CONFIG_EAP_TTLS
  CONFIG_EAP_GTC
  CONFIG_EAP_PWD
  CONFIG_WPS_ER
  CONFIG_WPS_REG_DISABLE_OPEN
  CONFIG_WPS_NFC
  CONFIG_SAE_PK
  CONFIG_MESH
)

# The vendor script lists CONFIG_BGSCAN_SIMPLE in both its enables and its
# disables. defconfig:642 already has it on, so the enable is a no-op and the
# disable is the operative one -- hence turning it off here. Move it to
# WPA_S_ENABLE if you want background scanning for roaming.
WPA_S_DISABLE=(
  CONFIG_BGSCAN_SIMPLE
)

HOSTAPD_DISABLE=()

HOSTAPD_ENABLE=(
  CONFIG_DRIVER_NL80211_QCA
  CONFIG_EAP
  CONFIG_EAP_MD5
  CONFIG_EAP_EKE
  CONFIG_EAP_MSCHAPV2
  CONFIG_EAP_PEAP
  CONFIG_EAP_TLS
  CONFIG_EAP_TTLS
  CONFIG_EAP_GTC
  CONFIG_EAP_SIM
  CONFIG_EAP_AKA
  CONFIG_EAP_AKA_PRIME
  CONFIG_EAP_PAX
  CONFIG_EAP_PSK
  CONFIG_EAP_PWD
  CONFIG_EAP_SAKE
  CONFIG_EAP_GPSK
  CONFIG_EAP_GPSK_SHA256
  CONFIG_EAP_FAST
  CONFIG_EAP_TEAP
  CONFIG_WPS
  CONFIG_WPS_UPNP
  CONFIG_WPS_NFC
  CONFIG_EAP_IKEV2
  CONFIG_EAP_TNC
  CONFIG_RADIUS_SERVER
  CONFIG_SAE
  CONFIG_SAE_PK
  CONFIG_TLSV11
  CONFIG_TLSV12
)

# $2 and $3 are space-separated option lists (pass arrays as "${arr[*]}").
#
# They have to be re-split into arrays here: bash cannot pass an array by value,
# so `local enabled=$2` yields a scalar, and "${enabled[@]}" over a scalar
# expands to a single element holding the whole joined string. Every sed then
# looks for an option literally named "CONFIG_A CONFIG_B ..." and silently
# matches nothing -- which is how both daemons ended up built straight from
# defconfig. `read -ra` splits without exposing the values to globbing.
write_hostap_config() {
  local dir=$1 opt
  local -a enabled disabled
  read -ra enabled <<<"$2"
  read -ra disabled <<<"$3"

  cp "$dir/defconfig" "$dir/.config"
  for opt in "${enabled[@]}"; do
    sed -i -e "s/^#$opt=y/$opt=y/" "$dir/.config"
  done
  for opt in "${disabled[@]}"; do
    sed -i -e "s/^$opt=y/#$opt=y/" "$dir/.config"
  done

  # A sed that matches nothing is not an error, so an option that is absent
  # from defconfig or spelled differently would fail exactly as silently as the
  # bug above. Check the end state instead of trusting the substitutions.
  for opt in "${enabled[@]}"; do
    if ! grep -qE "^$opt=y" "$dir/.config"; then
      >&2 echo "$dir/.config: failed to enable $opt (absent from defconfig?)"
      exit 1
    fi
  done
  for opt in "${disabled[@]}"; do
    if ! grep -qE "^#$opt=y" "$dir/.config"; then
      >&2 echo "$dir/.config: failed to disable $opt (absent from defconfig?)"
      exit 1
    fi
  done
}

log "Building wpa_supplicant_s1g..."
write_hostap_config hostap/wpa_supplicant "${WPA_S_ENABLE[*]}" "${WPA_S_DISABLE[*]}"
make -C hostap/wpa_supplicant clean
CFLAGS="$HOSTAP_CFLAGS" LIBS="$HOSTAP_LIBS" \
  make -j"$(nproc)" -C hostap/wpa_supplicant

log "Building hostapd_s1g..."
write_hostap_config hostap/hostapd "${HOSTAPD_ENABLE[*]}" "${HOSTAPD_DISABLE[*]-}"
make -C hostap/hostapd clean
CFLAGS="$HOSTAP_CFLAGS" LIBS="$HOSTAP_LIBS" \
  make -j"$(nproc)" -C hostap/hostapd

# ---------------------------------------------------------------------------
# morse_cli
# ---------------------------------------------------------------------------

# With CFLAGS unset the Makefile adds -I${SYSROOT}/usr/include/libnl3 itself,
# which resolves to the distro headers on a native build.
log "Building morse_cli..."
make -C morse_cli clean
make -j"$(nproc)" -C morse_cli CONFIG_MORSE_TRANS_NL80211=1

# ---------------------------------------------------------------------------
# Install userspace
# ---------------------------------------------------------------------------

log "Installing userspace tools into $BINDIR"
as_root install -d "$BINDIR"
as_root install -m 0755 -t "$BINDIR" \
  hostap/wpa_supplicant/wpa_supplicant_s1g \
  hostap/wpa_supplicant/wpa_cli_s1g \
  hostap/wpa_supplicant/wpa_passphrase_s1g \
  hostap/hostapd/hostapd_s1g \
  hostap/hostapd/hostapd_cli_s1g \
  morse_cli/morse_cli

log "Refreshing module dependencies"
as_root depmod -a

cat <<EOF

Done.

  Driver:    dkms status -m $PACKAGE_NAME
  Load it:   sudo modprobe morse
  Firmware:  /lib/firmware/morse
  Tools:     $BINDIR (hostapd_s1g, wpa_supplicant_s1g, morse_cli, ...)

Regdomain is pinned to $COUNTRY via /etc/modprobe.d/morse.conf; re-run with
COUNTRY=<cc> to change it.
EOF
