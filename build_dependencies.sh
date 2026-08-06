#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
SCRIPT_NAME="$0"

BINDIR=${BINDIR:-/usr/local/sbin}

# Not overridable. Kernel-upgrade rebuilds run from the staged
# /usr/src/morse-*/dkms.conf alone, with none of this script's environment, so
# the compiled-in regdomain is whatever CONFIG_MORSE_COUNTRY says there. Keep
# this in sync with drivers/morse/dkms.conf rather than letting the two drift.
COUNTRY=US

# --------------------------------------------------------------------------------
# Preamble
# --------------------------------------------------------------------------------

long_help() {
  >&2 echo "Build and install the offroad BATMAN stack. Assumes that this script is run directly on
one of the mesh nodes.

Does the following in order:

1. Build and install out-of-tree drivers for Morse Micro MM8108
  - morse.ko + dot11ah.ko via DKMS (rebuilt automatically on kernel upgrade)
  - firmware and BCFs into /lib/firmware/morse, via the DKMS POST_INSTALL hook

2. hostapd_s1g, wpa_supplicant_s1g and friends, morse_cli into \$BINDIR (${BINDIR:-/usr/local/sbin})

3. (If batman-adv-dkms is not available over apt) Build and install out-of-tree drivers
   for batman-adv

--uninstall reverses all of the above. It is a whole-stack removal, deliberately
separate from DKMS's own lifecycle: 'dkms remove' is per-kernel and fires during
routine kernel cleanup, so the firmware and userspace tools cannot be hooked to
it (see the POST_REMOVE note in drivers/morse/dkms.conf). Distro packages pulled
in as build dependencies (batctl and friends) are left alone.
"
}

usage() {
  >&2 echo "Usage: $SCRIPT_NAME [--no-morse] [--no-batman] [--uninstall]

Arguments:
  --no-morse    Do not build (or remove) the MM8108 drivers and CLI tools
  --no-batman   Do not build (or remove) the batman-adv kernel module
  --uninstall   Remove what this script installed, instead of installing
"
}

log() { >&2 echo "==> $*"; }
err() { >&2 echo "ERROR: $*"; }

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

die() {
  err "$*"
  exit 1
}

# Read the name and version from the package's dkms.conf rather than repeating
# them here, so the two cannot drift. Prints "<name> <version>".
dkms_pkg_id() {
  local dkms_conf="${1:?dkms directory not provided}/dkms.conf" name version
  [[ -f $dkms_conf ]] || die "$dkms_conf not present."
  name=$(sed -n 's/^PACKAGE_NAME="\(.*\)"$/\1/p' "$dkms_conf")
  version=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$dkms_conf")
  [[ -n $name && -n $version ]] ||
    die "$dkms_conf: could not read PACKAGE_NAME/PACKAGE_VERSION."
  echo "$name $version"
}

# Clear any previous registration of <name>/<version> so that a re-run is a
# no-op rather than "Error! DKMS tree already contains". Returns 0 if there was
# something to remove.
#
# `dkms status` alone is not enough of a check: the bookkeeping under
# /var/lib/dkms/<name>/<version> is what `dkms add` refuses to overwrite, and it
# outlives both the staged sources and (on some dkms versions) status reporting
# the module at all. Test for it directly, and sweep up whatever `dkms remove`
# leaves behind -- it declines to finish the job when the source tree it wants to
# consult is already gone.
dkms_deregister() {
  local pkg_name="${1:?package name not provided}"
  local pkg_version="${2:?package version not provided}"

  if dkms status -m "$pkg_name" -v "$pkg_version" 2>/dev/null | grep -q . ||
    [[ -d /var/lib/dkms/$pkg_name/$pkg_version ]]; then
    log "Removing previous DKMS registration of ${pkg_name}/${pkg_version}"
    as_root dkms remove -m "$pkg_name" -v "$pkg_version" --all || true
    as_root rm -rf "/var/lib/dkms/$pkg_name/$pkg_version"
    return 0
  fi
  return 1
}

install_dkms_pkg() {
  local drv_path="${1:?dkms directory not provided}"
  local id pkg_name pkg_version dkms_src

  if [[ ! -d /lib/modules/$(uname -r)/build ]]; then
    err "No kernel build tree at /lib/modules/$(uname -r)/build."
    err "    Install the headers for the running kernel before continuing"
    err "    (Jetson: 'apt install nvidia-l4t-kernel-headers')."
    exit 1
  fi

  id=$(dkms_pkg_id "$drv_path")
  read -r pkg_name pkg_version <<<"$id"
  dkms_src=/usr/src/${pkg_name}-${pkg_version}

  # Before restaging, not after: dkms's own removal wants the sources it was
  # registered against still in place.
  dkms_deregister "$pkg_name" "$pkg_version" || true

  # DKMS wants the sources under /usr/src/<name>-<version>. Copy rather than
  # symlink: dkms resolves the tree at build time on every kernel upgrade, and a
  # symlink into a user's home directory is a footgun once that tree moves.
  #
  # "$drv_path/." rather than "$drv_path/*": the glob would miss dotfiles, and
  # the submodules' .git are dotfiles that the find below has to see.
  log "Staging sources into $dkms_src..."
  as_root rm -rf "$dkms_src"
  as_root mkdir -p "$dkms_src"
  as_root cp -a "$drv_path/." "$dkms_src/"

  # Drop the submodules' git metadata; only the sources need to survive here.
  # No -type d: a submodule's .git is a *file* pointing back at this checkout's
  # .git/modules, which would dangle the moment the checkout moves.
  as_root find "$dkms_src" -name .git -prune -exec rm -rf {} +

  log "Building and installing via DKMS..."
  as_root dkms add -m "$pkg_name" -v "$pkg_version"
  as_root dkms build -m "$pkg_name" -v "$pkg_version"
  as_root dkms install -m "$pkg_name" -v "$pkg_version"

  log "Done."
  log "  Driver:    dkms status -m $pkg_name"
  log "  Load it:   sudo modprobe $pkg_name"
}

# --all, not -k $(uname -r): this is a whole-stack removal, so the module should
# go for every kernel it was ever autoinstalled for, not just the running one.
uninstall_dkms_pkg() {
  local drv_path="${1:?dkms directory not provided}"
  local id pkg_name pkg_version

  id=$(dkms_pkg_id "$drv_path")
  read -r pkg_name pkg_version <<<"$id"

  dkms_deregister "$pkg_name" "$pkg_version" ||
    log "${pkg_name}/${pkg_version} is not registered with DKMS"
  as_root rm -rf "/usr/src/${pkg_name}-${pkg_version}"
}

# --------------------------------------------------------------------------------
# Parse CLI flags
# --------------------------------------------------------------------------------

BUILD_MORSE_DRIVERS=1
BUILD_BATMAN_DRIVERS=1
UNINSTALL=0

# Built from the hostap/morse_cli trees and installed into $BINDIR. One list so
# that --uninstall cannot drift from what the build actually installs.
MORSE_TOOLS=(
  tools/hostap/wpa_supplicant/wpa_supplicant_s1g
  tools/hostap/wpa_supplicant/wpa_cli_s1g
  tools/hostap/wpa_supplicant/wpa_passphrase_s1g
  tools/hostap/hostapd/hostapd_s1g
  tools/hostap/hostapd/hostapd_cli_s1g
  tools/morse_cli/morse_cli
)

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-morse)
    BUILD_MORSE_DRIVERS=0
    shift
    ;;
  --no-batman)
    BUILD_BATMAN_DRIVERS=0
    shift
    ;;
  --uninstall)
    UNINSTALL=1
    shift
    ;;
  -h)
    usage
    exit 0
    ;;
  --help)
    usage
    long_help
    exit 0
    ;;
  *)
    err "Unknown argument $1"
    usage
    exit 1
    ;;
  esac
done

# --------------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------------

# Ahead of the dependency and submodule steps: removal needs neither, and should
# still work on a checkout whose submodules were never initialised.
if [[ $UNINSTALL == 1 ]]; then
  if [[ $BUILD_MORSE_DRIVERS == 1 ]]; then
    uninstall_dkms_pkg ./drivers/morse/

    log "Removing firmware from /lib/firmware/morse"
    as_root rm -rf /lib/firmware/morse

    log "Removing /etc/modprobe.d/morse.conf"
    as_root rm -f /etc/modprobe.d/morse.conf

    log "Removing userspace tools from $BINDIR"
    installed_tools=()
    for tool in "${MORSE_TOOLS[@]}"; do
      installed_tools+=("$BINDIR/$(basename "$tool")")
    done
    as_root rm -f "${installed_tools[@]}"
  fi

  if [[ $BUILD_BATMAN_DRIVERS == 1 ]]; then
    uninstall_dkms_pkg ./drivers/batman/
  fi

  log "Refreshing module dependencies"
  as_root depmod -a
  log "Done. Build dependencies installed from apt (batctl and friends) are left alone."
  exit 0
fi

# --------------------------------------------------------------------------------
# Install Dependencies + pull submodules
# --------------------------------------------------------------------------------

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
  batctl
  wireless-tools
  iw
)

missing=()
for pkg in "${APT_DEPS[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" ||
    missing+=("$pkg")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  log "Installing build dependencies (root required): ${missing[*]}"
  as_root apt-get update -y
  as_root apt-get install -y "${missing[@]}"
fi

log "Checking out submodules..."
git submodule update --init --recursive

if [[ $BUILD_MORSE_DRIVERS == 1 ]]; then
  install_dkms_pkg ./drivers/morse/
  log "Setting module parameters"
  as_root mkdir -p /etc/modprobe.d
  echo "options morse country=$COUNTRY" | as_root tee /etc/modprobe.d/morse.conf >/dev/null

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
  HOSTAP_CFLAGS+=" -D_GNU_SOURCE -I$SCRIPT_DIR/tools/morse_cli"
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
  write_hostap_config tools/hostap/wpa_supplicant "${WPA_S_ENABLE[*]}" "${WPA_S_DISABLE[*]}"
  make -C tools/hostap/wpa_supplicant clean
  CFLAGS="$HOSTAP_CFLAGS" LIBS="$HOSTAP_LIBS" \
    make -j"$(nproc)" -C tools/hostap/wpa_supplicant

  log "Building hostapd_s1g..."
  write_hostap_config tools/hostap/hostapd "${HOSTAPD_ENABLE[*]}" "${HOSTAPD_DISABLE[*]-}"
  make -C tools/hostap/hostapd clean
  CFLAGS="$HOSTAP_CFLAGS" LIBS="$HOSTAP_LIBS" \
    make -j"$(nproc)" -C tools/hostap/hostapd

  # With CFLAGS unset the Makefile adds -I${SYSROOT}/usr/include/libnl3 itself,
  # which resolves to the distro headers on a native build.
  log "Building morse_cli..."
  make -C tools/morse_cli clean
  make -j"$(nproc)" -C tools/morse_cli CONFIG_MORSE_TRANS_NL80211=1

  log "Installing userspace tools into $BINDIR"
  as_root install -d "$BINDIR"
  as_root install -m 0755 -t "$BINDIR" "${MORSE_TOOLS[@]}"
fi

if [[ $BUILD_BATMAN_DRIVERS == 1 ]]; then
  install_dkms_pkg ./drivers/batman/
fi

log "Refreshing module dependencies"
as_root depmod -a
log "Done"
