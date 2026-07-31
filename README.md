# MM8108 Driver Setup

Builds and installs the Morse Micro MM8108 (802.11ah / HaLow) stack on an Ubuntu device.

NOTE: Does not cross-compile and is expected to be run directly on the target device.

The card is driven over USB (`CONFIG_MORSE_USB`), which is what the GW16167 M.2
2230 E-key module uses. If the card does not appear, check the link before the
driver: `lsusb -d 325b:` should show `325b:8100`. Not every M.2 E-key slot wires
up USB 2.0, and the driver cannot see a card that is only on PCIe lanes.

## Install

```sh
git clone --recurse-submodules <this repo>
cd morse-micro
./morse_micro_install.sh
```

Installs:

- `morse.ko` + `dot11ah.ko` via DKMS, so they rebuild on kernel upgrades
- firmware and BCFs into `/lib/firmware/morse`
- `hostapd_s1g`, `wpa_supplicant_s1g`, `morse_cli` and friends into `$BINDIR`

Environment overrides: `BINDIR` (default `/usr/local/sbin`) and `COUNTRY`
(default `US`, baked into both the module and `/etc/modprobe.d/morse.conf`).

Uninstall with `./morse_micro_install.sh --uninstall`.
Removal is deliberately not a DKMS `POST_REMOVE` hook,
because DKMS removals are per-kernel
and would drop the firmware during routine old-kernel cleanup.

## Layout

| Path | What |
| --- | --- |
| `morse_micro_install.sh` | The only thing you need to run |
| `dkms.conf` | Driver build config; staged into `/usr/src/morse-2.0.0` |
| `install-firmware.sh` | DKMS `POST_INSTALL` hook, installs firmware |
| `patches/` | Fixups applied to `morse_driver` by DKMS at build time |
| `morse_driver/`, `morse-firmware/`, `hostap/`, `morse_cli/` | Vendor submodules, unmodified |

Openssl, libnl and libusb come from the distro; nothing is built out of tree.
