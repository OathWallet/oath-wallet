#!/usr/bin/env python3
"""Offline validation of Oath's archive orientations and all binary/dSYM UUIDs.

This checks the actual distribution artifact, not just project settings. It does
not upload, sign, install or launch anything and is not App Store validation.
"""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def orientation_errors(info):
    errors = []
    portrait = ["UIInterfaceOrientationPortrait"]
    for key in ("UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"):
        if info.get(key) != portrait:
            errors.append(f"{key} must declare the shared portrait-only policy as an array")
    if info.get("UIRequiresFullScreen") is not True:
        errors.append("Portrait-only iPad support requires UIRequiresFullScreen = true")
    return errors


def build_ids(binary):
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(binary)],
                            text=True, capture_output=True, check=True)
    pairs = re.findall(r"UUID: ([A-F0-9-]+) \(([^)]+)\)", result.stdout)
    if not pairs:
        raise ValueError(f"No build UUID in {binary.name}")
    return set(pairs)


def audit(archive):
    metadata = read_plist(archive / "Info.plist")
    app = archive / "Products" / metadata["ApplicationProperties"]["ApplicationPath"]
    info = read_plist(app / "Info.plist")
    errors = orientation_errors(info)
    symbol_ids = set()
    for dsym in (archive / "dSYMs").glob("*.dSYM"):
        for dwarf in (dsym / "Contents/Resources/DWARF").iterdir():
            if dwarf.is_file() and not dwarf.name.startswith("._"):
                symbol_ids.update(build_ids(dwarf))
    binaries = [app / info["CFBundleExecutable"]]
    for framework in (app / "Frameworks").glob("*.framework"):
        framework_info = read_plist(framework / "Info.plist")
        binaries.append(framework / framework_info["CFBundleExecutable"])
    for binary in binaries:
        missing = build_ids(binary) - symbol_ids
        if missing:
            errors.append(f"Missing matching dSYM for {binary.name}: {sorted(missing)}")
    return errors, len(binaries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    errors, count = audit(args.archive)
    for error in errors:
        print(f"ERROR: {error}")
    if not errors:
        print(f"Archive passed: portrait/full-screen declarations and matching dSYMs for all {count} binaries.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
