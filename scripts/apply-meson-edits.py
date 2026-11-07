#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Apply the meson edits that the driver's own meson-integration.patch cannot
apply to Ubuntu's libfprint 1.95.2+tod1 source tree.

The patch was written for upstream libfprint 1.94.10. On 1.95.2+tod1 six of
its eight hunks apply (with offsets) and two are rejected:

  libfprint/meson.build : the 'goodix53x5' entry in `driver_sources`
                          (1.95.x uses files(...) blocks, not plain lists)
  meson.build           : the 'goodix53x5' entry in `driver_helper_mapping`
                          (the neighbouring lines differ)

This script adds exactly those two entries. It is idempotent: running it on a
tree that already has them changes nothing.

Usage: apply-meson-edits.py /path/to/libfprint-source
"""

import pathlib
import sys

DRIVER_SOURCES = [
    "goodix53x5",
    "goodix53x5-proto",
    "goodix53x5-crypto",
    "goodix53x5-transport",
    "goodix53x5-commands",
    "goodix53x5-session",
    "goodix53x5-scan",
    "goodix53x5-enroll",
    "goodix53x5-auth",
    "goodix53x5-match",
    "goodix53x5-calibration",
    "goodix53x5-image",
]


def fail(msg: str) -> None:
    sys.exit(f"error: {msg}")


def edit_driver_sources(src: pathlib.Path) -> None:
    path = src / "libfprint" / "meson.build"
    text = path.read_text()

    if "'goodix53x5': files(" in text or "'goodix53x5' :" in text:
        print(f"{path}: driver_sources entry already present, skipping")
        return

    anchor = (
        "    'goodixmoc': files(\n"
        "        'drivers/goodixmoc/goodix.c',\n"
        "        'drivers/goodixmoc/goodix_proto.c',\n"
        "    ),\n"
    )
    if text.count(anchor) != 1:
        fail(
            f"{path}: could not find the 'goodixmoc' files(...) block exactly "
            "once. This script targets libfprint 1.95.x; for other versions "
            "add the 'goodix53x5' entry to driver_sources by hand (see README)."
        )

    files = "".join(
        f"        'drivers/goodix53x5/{name}.c',\n" for name in DRIVER_SOURCES
    )
    entry = "    'goodix53x5': files(\n" + files + "    ),\n"
    path.write_text(text.replace(anchor, anchor + entry))
    print(f"{path}: added driver_sources entry")


def edit_helper_mapping(src: pathlib.Path) -> None:
    path = src / "meson.build"
    text = path.read_text()

    if "'goodix53x5' : [ 'openssl' ]" in text:
        print(f"{path}: driver_helper_mapping entry already present, skipping")
        return

    anchor = "    'uru4000' : [ 'openssl' ],\n"
    if text.count(anchor) != 1:
        fail(
            f"{path}: could not find the 'uru4000' mapping line exactly once. "
            "Add \"'goodix53x5' : [ 'openssl' ],\" to driver_helper_mapping "
            "by hand (see README)."
        )

    path.write_text(
        text.replace(anchor, anchor + "    'goodix53x5' : [ 'openssl' ],\n")
    )
    print(f"{path}: added driver_helper_mapping entry")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = pathlib.Path(sys.argv[1])
    for rel in ("meson.build", "libfprint/meson.build"):
        if not (src / rel).is_file():
            fail(f"{src / rel} not found; is this a libfprint source tree?")
    edit_driver_sources(src)
    edit_helper_mapping(src)


if __name__ == "__main__":
    main()
