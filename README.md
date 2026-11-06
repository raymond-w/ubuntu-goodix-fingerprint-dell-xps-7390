# Goodix HTK32 (27c6:5385) fingerprint reader on Ubuntu

Helper scripts that build a **self-contained `.deb`** which adds support for the
Goodix HTK32 fingerprint sensor (`27c6:5385`) to Ubuntu's `fprintd`.

```
$ lsusb | grep 27c6
Bus 001 Device 004: ID 27c6:5385 Shenzhen Goodix Technology Co.,Ltd. Fingerprint Reader
```

If `fprintd-enroll` tells you `No devices available`, this is probably your sensor.

> **This repository does not contain the driver.** The driver is a third-party
> libfprint fork by [AndyHazz](https://github.com/AndyHazz/goodix53x5-libfprint).
> This repo only automates fetching it, integrating it into Ubuntu's own
> libfprint source, and packaging the result. It is not affiliated with Goodix,
> Dell, Canonical, the libfprint project, or the driver's author.

## Why this exists

Mainline libfprint does not support this sensor; support has been requested
since 2018 ([libfprint issue #43](https://gitlab.freedesktop.org/libfprint/libfprint/issues/43)).
The driver fork adds it, but it is distributed as source plus an Arch (AUR)
package. Ubuntu users have to build it themselves, and the driver's meson patch
does not apply cleanly to the libfprint version Ubuntu ships (1.95.x), because
it was written for upstream 1.94.10.

These scripts handle that and produce a package you can install and remove
cleanly.

## Status

Tested by the author on:

| | |
|---|---|
| Distribution | Ubuntu 26.10 ("stonking") |
| libfprint | `1:1.95.2+tod1-1ubuntu2` (Ubuntu's source package) |
| Sensor | `27c6:5385` |
| Sensor detected by fprintd | works |
| Enrollment (`fprintd-enroll`) | works (8 stages complete) |
| Verification (`fprintd-verify`) | *not yet confirmed here, update before publishing* |
| Login / `sudo` via PAM | *not yet confirmed here, update before publishing* |
| Suspend / resume | *not yet confirmed here, update before publishing* |

The driver also lists `27c6:5335` and `27c6:5395`. Those are untested with these
scripts.

Other libfprint versions may need manual meson edits; see
[Other versions](#other-libfprint-versions).

## How it works

```
                 Ubuntu's libfprint source          third-party driver
                 (apt source libfprint)             (AndyHazz/goodix53x5-libfprint)
                            \                            /
                             \                          /
                      scripts/prepare-source.sh  (copy driver, patch meson)
                                     |
                           scripts/build-deb.sh   (meson + ninja, dpkg-shlibdeps)
                                     |
                  libfprint-goodix53x5-opt_<version>_amd64.deb
                                     |
        installs to /opt/libfprint-goodix  +  a systemd drop-in for fprintd
```

- The package installs its own copy of libfprint under `/opt/libfprint-goodix`.
  **It does not replace or modify Ubuntu's `libfprint-2-2` package**, so apt
  upgrades of the system library are unaffected.
- A systemd drop-in (`/usr/lib/systemd/system/fprintd.service.d/goodix53x5.conf`)
  sets `LD_LIBRARY_PATH` so that `fprintd` loads that copy.
- The driver detaches the kernel's `cdc_acm` driver from the sensor itself when
  it opens the device, so no udev rule is needed.
- Removing the package restores stock behaviour.

## Quick start

### 1. Enable source repositories

Ubuntu uses the deb822 format in `/etc/apt/sources.list.d/ubuntu.sources`:

```bash
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
grep Types /etc/apt/sources.list.d/ubuntu.sources     # should show "deb deb-src"
sudo apt update
```

### 2. Install build dependencies

```bash
sudo apt build-dep libfprint-2-2
sudo apt install git build-essential meson ninja-build pkg-config dpkg-dev \
                 libopencv-dev libssl-dev fprintd libpam-fprintd
```

The driver needs OpenCV (for its SIFT-based matcher) and OpenSSL. If the build
later reports a missing header or tool, install the matching `-dev` package.

### 3. Prepare the source tree

```bash
git clone <this-repository-url> goodix-htk32-ubuntu
cd goodix-htk32-ubuntu
bash scripts/prepare-source.sh
```

This clones the driver into `work/`, runs `apt source libfprint`, copies the
driver in, applies the meson integration and verifies the result. The driver
commit that was used is recorded in `work/DRIVER_COMMIT`.

### 4. Build the package

```bash
bash scripts/build-deb.sh
```

Compiler warnings from OpenCV headers are normal. The result is written to
`out/libfprint-goodix53x5-opt_<version>_amd64.deb`. The package's dependencies
are computed from the built libraries, so a package built on one Ubuntu release
should only be installed on that release.

### 5. Install and enroll

```bash
sudo apt install ./out/libfprint-goodix53x5-opt_*.deb
fprintd-list "$USER"        # should show "Goodix HTK32 Fingerprint Sensor"
fprintd-enroll
fprintd-verify
```

The sensor is small (108x88 px). During enrollment lift your finger between
touches and vary the position slightly each time.

### 6. (Optional) Use it for login and `sudo`

Only do this once `fprintd-verify` works reliably, and keep a root shell open
in another terminal while you change PAM settings:

```bash
sudo -s                       # in a second terminal; leave it open
sudo pam-auth-update          # in the first: tick "Fingerprint authentication"
```

Your password continues to work as a fallback.

## Uninstall

```bash
sudo apt remove libfprint-goodix53x5-opt
```

fprintd goes back to Ubuntu's libfprint. Enrolled prints stay in
`/var/lib/fprint/<user>/goodix53x5/`; delete them with `fprintd-delete "$USER"`
or by removing that directory.

## Keeping it working after updates

The package is built against one specific libfprint source version. If Ubuntu
updates `libfprint` or `fprintd` and fingerprint stops working, rebuild:

```bash
rm -rf work/libfprint-*                 # keep work/goodix53x5-libfprint
bash scripts/prepare-source.sh
REVISION=2 bash scripts/build-deb.sh       # package version follows the source
sudo apt install ./out/libfprint-goodix53x5-opt_*.deb
```

## Other libfprint versions

`prepare-source.sh` was written for `1.95.2+tod1`. On that version, the
driver's `meson-integration.patch` applies in part; the two rejected hunks
(the `driver_sources` entry and the `driver_helper_mapping` entry) are added
by `scripts/apply-meson-edits.py`, which is idempotent.

On another version the edit script may stop with a message saying which anchor
it could not find. Add these by hand:

1. In `libfprint/meson.build`, in the `driver_sources` dictionary, an entry
   `'goodix53x5'` listing the `drivers/goodix53x5/goodix53x5*.c` files (the
   list is in the script).
2. In the top-level `meson.build`, in `driver_helper_mapping`:
   `'goodix53x5' : [ 'openssl' ],`

## Security considerations

- **You are installing third-party code that runs inside `fprintd`**, the
  daemon that handles biometric authentication. The driver is young and has
  little review. Read the source (`work/goodix53x5-libfprint/`) before
  installing, and consider pinning a commit you have reviewed with
  `DRIVER_REF=<commit> bash scripts/prepare-source.sh`.
- Keep password login working. Don't remove it because fingerprint works.
- Fingerprints are not secrets; a fingerprint login is a convenience, not
  strong authentication. Think twice before enabling it for `sudo` on a
  machine that holds sensitive data.
- The `.deb` is built locally and is not signed. Don't install `.deb` files
  someone else built from this repo without checking them.

## Layout

```
scripts/prepare-source.sh      fetch Ubuntu's libfprint source + driver, integrate them
scripts/apply-meson-edits.py   the two meson edits the driver's patch can't apply on 1.95.x
scripts/build-deb.sh           build and package, producing out/*.deb
docs/TROUBLESHOOTING.md        common problems
work/                          (generated) sources and driver checkout
out/                           (generated) the .deb
```

## Reporting problems

Please include: your Ubuntu version, `apt policy libfprint-2-2`, `lsusb | grep 27c6`,
the output of the script that failed, and for runtime problems the output of
`sudo journalctl -u fprintd -b --no-pager | tail -60`.

Problems with the driver itself (matching quality, crashes, other sensors)
belong in the
[driver repository](https://github.com/AndyHazz/goodix53x5-libfprint).

## Credits

- The Goodix HTK32 driver and its SIGFM matcher: [AndyHazz](https://github.com/AndyHazz/goodix53x5-libfprint).
- [libfprint](https://gitlab.freedesktop.org/libfprint/libfprint) and
  [fprintd](https://gitlab.freedesktop.org/libfprint/fprintd).

## License

LGPL-2.1-or-later, matching libfprint and the driver; see [LICENSE](LICENSE).
The driver and libfprint are separate projects under their own licenses.
# ubuntu-goodix-fingerprint-dell-xps-7390
