#!/usr/bin/env python3
"""Compile without signing or launching devices, using a separate build cache.

Usage: python3 Tools/BuildiOS.py [--configuration Debug|Release] [--dry-run]
The checkout-specific cache avoids Xcode's interactive build database. A lock
also prevents two invocations of this helper from building into the same cache.
"""
import argparse
import fcntl
import hashlib
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    checkout = hashlib.sha256(str(root).encode()).hexdigest()[:12]
    cache = Path.home() / "Library/Caches/Oath/CommandLineBuilds" / checkout
    command = [
        "xcodebuild", "-project", str(root / "OathAtmosphere.xcodeproj"),
        "-scheme", "OathAtmosphere", "-configuration", args.configuration,
        "-destination", "generic/platform=iOS", "-derivedDataPath", str(cache / "DerivedData"),
        "-disableAutomaticPackageResolution", "-skipPackageUpdates",
        "CODE_SIGNING_ALLOWED=NO", "build",
    ]
    if args.dry_run:
        print(shlex.join(command))
        return 0
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "build.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another command-line build is already running for this checkout. "
                  "Wait for it to finish before retrying.", file=sys.stderr)
            return 75
        print(f"Command-line build cache: {cache / 'DerivedData'}", flush=True)
        # Keep the lock in the child too if the invoking helper is interrupted.
        return subprocess.run(command, cwd=root, pass_fds=(lock.fileno(),)).returncode


if __name__ == "__main__":
    raise SystemExit(main())
