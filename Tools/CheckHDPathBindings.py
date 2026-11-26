#!/usr/bin/env python3
"""Exercise retiring HD editor bindings with native SwiftUI on the Mac.

Uses the production binding adapter and OathDatabase draft model unchanged.
No windows, simulator, device, wallet secrets, database or network requests.
SwiftPM may fetch build dependencies on its first run.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-hd-path-bindings-") as temporary:
    work = Path(temporary)
    sources = work / "Sources/HDPathBindingChecks"
    sources.mkdir(parents=True)
    editor = (root / "OathAtmosphere/Home/OathHDPathEditor.swift").read_text()
    # The UIKit editor below this boundary is compiled by the generic iOS build.
    # Test its exact binding implementation, including SwiftUI transaction handling.
    adapter, _ = editor.split("/// Shared EVM/Solana editor.", 1)
    (sources / "OathHDPathBindings.swift").write_text(adapter)
    shutil.copyfile(root / "Tools/CheckHDPathBindings.swift", sources / "CheckHDPathBindings.swift")
    (work / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "HDPathBindingChecks", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "HDPathBindingChecks", dependencies: ["OathDatabase"])],
    swiftLanguageModes: [.v6])
''' % json.dumps(str(root / "Packages/OathDatabase")))
    subprocess.run(["swift", "run", "--build-system", "native", "--package-path", str(work),
                    "--scratch-path", os.environ.get("OATH_HD_BINDINGS_SCRATCH", "/tmp/oath-hd-path-bindings-host-build"),
                    "HDPathBindingChecks"], check=True)
