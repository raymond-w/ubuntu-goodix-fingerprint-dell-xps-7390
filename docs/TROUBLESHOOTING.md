# Troubleshooting

## Build time

### `apt source libfprint` fails / "You must put some 'deb-src' URIs"

Source repositories are not enabled. In
`/etc/apt/sources.list.d/ubuntu.sources` change every `Types: deb` line to
`Types: deb deb-src`, then run `sudo apt update`. See the README.

### `prepare-source.sh`: "integration incomplete"

The script checks that the driver is wired into both `meson.build` files. The
message names the missing piece. Usually the libfprint version differs from
`1.95.2+tod1` and `apply-meson-edits.py` could not find its anchor lines. Make
the two edits by hand as described in the README ("Other libfprint versions"),
then run `./scripts/build-deb.sh`.

### `meson setup` complains about a missing dependency

Install the matching `-dev` package and run the build again with
`RECONFIGURE=1 ./scripts/build-deb.sh`. Common ones: `libopencv-dev`,
`libssl-dev`, `libnss3-dev`, `libgusb-dev`, `libgudev-1.0-dev`,
`libpixman-1-dev`, `libcairo2-dev`, `gobject-introspection`.
`sudo apt build-dep libfprint-2-2` pulls in most of them.

### Warnings from `opencv2/...` headers

Harmless; they come from OpenCV's own headers, not from the driver.

### Compile errors in `drivers/goodix53x5/*.c`

The driver was written for libfprint 1.94.x. If you build against a version
with different internal APIs, it may not compile. Report it in the driver
repository with the first error message and your libfprint version.

### `dpkg-shlibdeps produced no dependencies`

Run it by hand to see why:

```bash
cd /tmp && mkdir -p debian && printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > debian/control
dpkg-shlibdeps -O -l<staged-lib-dir> <staged-lib-dir>/libfprint-2.so.2.0.0
```

and make sure `dpkg-dev` is installed.

## Run time

### `fprintd-enroll`: "No devices available"

1. Check the sensor is present: `lsusb | grep 27c6:5385`.
2. Check the package is installed: `dpkg -l libfprint-goodix53x5-opt`.
3. Check that fprintd actually loads the new library:

   ```bash
   fprintd-list "$USER"                        # starts the daemon on demand
   sudo grep -o '/[^ ]*libfprint-2[^ ]*' /proc/$(pgrep -x fprintd)/maps | sort -u
   ```

   The paths should be under `/opt/libfprint-goodix`. If they point to `/usr/lib/...`:

   ```bash
   systemctl cat fprintd        # should list goodix53x5.conf with LD_LIBRARY_PATH
   sudo systemctl daemon-reload && sudo systemctl restart fprintd
   ```

### "Resource busy" / "failed to claim interface"

On this sensor the kernel's `cdc_acm` modem driver grabs the device. The driver
detaches it by itself when it opens the sensor, so `lsusb -t` showing
`Driver=cdc_acm` *before* the first use is normal.

If you still get claim errors, check what holds the device:

```bash
lsusb -t | grep -B1 -A1 27c6
dmesg | grep -i -E "goodix|cdc_acm|27c6"
```

As a manual test (not needed in the author's setup, and untested as a permanent
fix), unbind the kernel driver; the interface names follow the USB port
(here `1-10`), so list them first:

```bash
ls /sys/bus/usb/drivers/cdc_acm/
echo '1-10:1.0' | sudo tee /sys/bus/usb/drivers/cdc_acm/unbind
echo '1-10:1.1' | sudo tee /sys/bus/usb/drivers/cdc_acm/unbind
```

### Enrollment fails or is rejected as poor quality

- Clean and dry the finger and the sensor; press firmly but not hard.
- Lift the finger completely between touches and vary the position
  (centre, slightly left, slightly right, fingertip).
- Re-enroll: `fprintd-delete "$USER"` then `fprintd-enroll`.

### Stops working after suspend/resume

Typical signs: fingerprint fails at the GDM screen after a suspend while the
password works, and `fprintd-verify` fixes it temporarily. The journal shows
"Open FDT baseline did not stabilize" and "Device was already claimed".

The package installs a resume hook that resets the sensor. Check it is there:

```bash
ls -l /usr/lib/systemd/system-sleep/fprint-reset     # should be -rwxr-xr-x
command -v usbreset                                  # from the usbutils package
```

Details, manual installation without the deb, and what is still untested are
in [SUSPEND-RESUME.md](SUSPEND-RESUME.md). If it still fails with the hook in
place, capture the logs described there and open an issue.

### Debug logging

Enable verbose driver output, reproduce the problem, then read the journal:

```bash
sudo systemctl edit fprintd
```

```ini
[Service]
Environment=G_MESSAGES_DEBUG=all
```

```bash
sudo systemctl restart fprintd
fprintd-enroll          # or fprintd-verify
sudo journalctl -u fprintd -b --no-pager | tail -80
```

Remove the debug override afterwards with `sudo systemctl revert fprintd`.
That only deletes overrides you created in `/etc`; the package's own drop-in in
`/usr/lib/systemd/system/` is untouched.

### Back to stock

```bash
sudo apt remove libfprint-goodix53x5-opt
```
