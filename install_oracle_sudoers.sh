#!/usr/bin/env bash
#
# install_oracle_sudoers.sh -- let batman_oracle.sh read the radio without a
# password prompt.
#
# batctl refuses to run without root, and `iw survey dump` reports noise and
# channel-busy time only to root -- unprivileged both come back empty, which is
# indistinguishable from a driver that does not report them. Every walk and
# soak row had blank tq, nexthop, noise_dbm and busy_pct until this existed,
# and those are exactly the columns that separate "the link degraded" from
# "something else started transmitting".
#
# The probe calls them through `sudo -n`, which fails rather than prompts: a
# probe runs once a second inside a walk and over BatchMode ssh, so a password
# prompt would hang the sampler instead of asking anyone anything. That is what
# this grants.
#
# Run it once per Jetson, as the user the oracle will run as:
#
#   ./install_oracle_sudoers.sh
#   SUDO_FOR=robot ./install_oracle_sudoers.sh   # grant to someone else
#
# NOT needed on the OpenWrt router: it runs as root and has no sudo.
#
# Read-only commands only. Nothing here can change the radio's configuration --
# `iw` is the one entry worth noting, since `iw dev ... set` exists; the rule
# grants the binary, so treat this as "trusted to read the radio", not as a
# no-op. Narrow it to `/usr/sbin/batctl` alone if that matters more than the
# survey columns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=halow-lib.sh
source "$SCRIPT_DIR/halow-lib.sh"
# shellcheck disable=SC2034  # read by log()/warn()/die() in the library
LOG_TAG=sudoers

SUDOERS_FILE=${SUDOERS_FILE:-/etc/sudoers.d/halow-oracle}

# Who to grant it to. SUDO_USER is set when this script is itself run under
# sudo, and is the right answer then: without it the rule would be written for
# root, who does not need it, and the invoking user would still be prompted.
SUDO_FOR=${SUDO_FOR:-${SUDO_USER:-$(id -un)}}

# The readers the probe calls. morse_cli is optional -- it ships with the Morse
# driver rather than the distro, and only `at` uses it.
REQUIRED_CMDS=(batctl iw)
OPTIONAL_CMDS=(morse_cli)

# resolve_cmd <name> -- absolute path, or empty.
#
# sudoers matches on the path as typed, so a relative or wrong one silently
# grants nothing. Searches sbin explicitly: a non-root user's PATH on Debian
# omits it, so `command -v batctl` fails for a binary that is installed and
# that sudo would find perfectly well.
resolve_cmd() {
  local name=$1 p d
  p=$(command -v "$name" 2>/dev/null || true)
  if [[ -z $p ]]; then
    for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
      [[ -x $d/$name ]] && { p=$d/$name; break; }
    done
  fi
  [[ -n $p ]] && readlink -f "$p"
}

main() {
  require_cmd sudo "apt install sudo"
  require_cmd visudo "apt install sudo"

  id -u "$SUDO_FOR" >/dev/null 2>&1 || die "no such user: $SUDO_FOR"

  local paths=() p name
  for name in "${REQUIRED_CMDS[@]}"; do
    p=$(resolve_cmd "$name")
    [[ -n $p ]] || die "$name not found; install it before granting rights to it"
    paths+=("$p")
    log "found $name at $p"
  done
  for name in "${OPTIONAL_CMDS[@]}"; do
    p=$(resolve_cmd "$name")
    if [[ -n $p ]]; then
      paths+=("$p")
      log "found $name at $p"
    else
      warn "$name not found; skipping (only 'at' uses it)"
    fi
  done

  local joined
  joined=$(
    IFS=,
    printf '%s' "${paths[*]}"
  )

  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2064  # expand tmp now, not at trap time
  trap "rm -f '$tmp'" EXIT

  cat >"$tmp" <<-EOF
	# Written by install_oracle_sudoers.sh -- do not edit by hand.
	#
	# batman_oracle.sh reads the radio through 'sudo -n'. Without this, batctl
	# returns nothing and 'iw survey dump' omits noise and channel-busy time,
	# and every sample row records those columns as empty.
	$SUDO_FOR ALL=(root) NOPASSWD: $joined
	EOF

  # Validate BEFORE installing. A malformed file in /etc/sudoers.d breaks sudo
  # for every user on the node, and on a field Jetson reached only over the
  # mesh that is not a recoverable mistake.
  visudo -cf "$tmp" >/dev/null ||
    die "generated sudoers file failed validation; nothing was installed"

  log "installing $SUDOERS_FILE for user $SUDO_FOR"
  # 0440 and root-owned, or sudo ignores the file and says nothing about why.
  sudo install -o root -g root -m 0440 "$tmp" "$SUDOERS_FILE"

  # Re-validate what actually landed, not what we generated. install can
  # succeed against a path that is not what was intended.
  sudo visudo -cf "$SUDOERS_FILE" >/dev/null ||
    die "installed file fails validation -- remove $SUDOERS_FILE NOW"

  log "installed. verifying..."

  local failed=0
  for p in "${paths[@]}"; do
    if sudo -n "$p" --version >/dev/null 2>&1 || sudo -n "$p" -v >/dev/null 2>&1; then
      log "  ok: sudo -n $p"
    else
      # Not fatal: several of these have no version flag that exits 0, so a
      # failure here is weak evidence. The real check is the oracle itself.
      warn "  could not confirm: sudo -n $p"
      failed=1
    fi
  done

  cat <<-EOF

	  granted to   $SUDO_FOR
	  commands     ${paths[*]}
	  file         $SUDOERS_FILE

	  Confirm against the radio:
	    sudo -n batctl meshif bat0 originators
	    ./batman_oracle.sh status

	  TQ, PEERS and BUSY% should now carry values instead of '-'.
	  To undo: sudo rm $SUDOERS_FILE

	EOF

  [[ $failed -eq 0 ]] || warn "some checks were inconclusive; trust 'status' over them"
}

main "$@"
