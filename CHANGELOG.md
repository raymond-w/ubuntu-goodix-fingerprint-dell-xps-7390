# Changelog

## 1.95.2+tod1-1goodix2

- The package now installs a systemd sleep hook,
  `/usr/lib/systemd/system-sleep/fprint-reset`, that stops fprintd and resets
  the sensor with `usbreset` after resume. Fixes fingerprint login failing at
  the GDM screen after suspend ("Open FDT baseline did not stabilize" /
  "Device was already claimed"). See `docs/SUSPEND-RESUME.md`.
- The package now depends on `usbutils` (provides `usbreset`).
- Status table in the README updated: verification and GDM login confirmed.

## 1.95.2+tod1-1goodix1

- Initial version: libfprint 1.95.2+tod1 with the goodix53x5 driver, installed
  under `/opt/libfprint-goodix`, plus a systemd drop-in pointing fprintd at it.
