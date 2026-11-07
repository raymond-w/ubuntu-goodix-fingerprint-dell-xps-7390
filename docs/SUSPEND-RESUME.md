# Fingerprint login fails after suspend

## Symptom

After the laptop has been suspended, fingerprint login on the GDM screen does
not work and the password does. Running `fprintd-verify` once in a terminal
"fixes" it until the next suspend. Sequence observed by the author:

```
login:  fingerprint fails, password works
logout
login:  fingerprint fails, password works
(terminal) fprintd-verify   -> works
logout
login:  fingerprint works
```

## Log signature

```
fprintd: Open FDT validation unstable, retrying (1/2)
fprintd: Open FDT validation unstable, retrying (2/2)
fprintd: Device open failed: Open FDT baseline did not stabilize
fprintd: Authorization denied ... to call method 'Claim' for device
         'Goodix HTK32 Fingerprint Sensor': Device was already claimed
```

and in the kernel log around the resume:

```
xhci_hcd 0000:07:00.0: xHC error in resume, USBSTS 0x401, Reinit
```

## Likely cause

FDT is the sensor's finger-detection calibration. After resume the sensor
appears to be left in a state where that calibration does not stabilise. The
failed open leaves the device claimed, so the next client (the GDM greeter) is
refused with "Device was already claimed", and PAM falls back to the password.
`fprintd-verify` works because by then the sensor has settled.

This is an interpretation of the logs, not something confirmed with the driver
author. A calibration that runs while a finger is resting on the sensor can
fail in the same way, so it is worth keeping the finger off the sensor until
the login prompt has fully appeared.

Restarting fprintd on resume does not help: fprintd exits after about 30
seconds of idle time and restarts on demand anyway, so the problem is the
sensor's state, not the daemon's.

## The fix: reset the sensor on resume

The package installs a systemd sleep hook,
`/usr/lib/systemd/system-sleep/fprint-reset` (mode 755):

```sh
#!/bin/sh
case "$1" in
  post)
    systemctl stop fprintd.service
    usbreset 27c6:5385
    ;;
esac
```

After resume it stops fprintd and resets the USB device, so the next open
starts from a clean state. `usbreset` comes from the `usbutils` package, which
the deb depends on.

Check that it is in place:

```bash
ls -l /usr/lib/systemd/system-sleep/fprint-reset     # should be -rwxr-xr-x
command -v usbreset
```

To test: suspend the laptop, wake it, log out to the GDM screen and use the
fingerprint.

### Without the deb

```bash
sudo install -m 755 packaging/system-sleep/fprint-reset \
    /usr/lib/systemd/system-sleep/fprint-reset
sudo apt install usbutils
```

Copy the file instead of symlinking it; systemd runs these scripts as root and
some setups are strict about links.

## Environment where this was seen

- Ubuntu 26.10, GNOME Shell 51
- kernel `7.3.0-070300rc3-generic`, a mainline release candidate (resume
  regressions are more common in release candidates)

## Not tried

- Whether the problem also occurs on Ubuntu's stock kernel. If it does not, the
  hook is only needed on that kernel.
- Disabling USB autosuspend for the sensor with a udev rule
  (`power/control` = `on` for `27c6:5385`).

If you try either, please report the result.

## Collecting logs after a failed resume

```bash
journalctl -b -u fprintd --no-pager | tail -50
journalctl -b -k | grep -E "PM:|xhci|27c6|Goodix" | tail -40
```

The USB port in kernel messages (`usb 1-10` on the author's machine) differs
between machines.
