#!/usr/bin/env python3
"""Check a built iOS diagnostics module without running a simulator or device.

Pass the generic iOS build's Products/Debug-iphoneos (or Release-iphoneos)
directory. Positive and negative compiler probes verify the public API; symbol
inspection verifies the event consumer was also omitted from the binary.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", type=Path)
    args = parser.parse_args()
    products = args.products.resolve()
    binary = products / "PackageFrameworks/OathDiagnostics.framework/OathDiagnostics"
    if not binary.is_file():
        raise SystemExit("Build the generic iOS app before checking its diagnostics boundary.")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    probes = [
        ("on-device API", '''
let file = URL(fileURLWithPath: "/tmp/diagnostic-fixture.json")
let box = DiagnosticOutbox(file: file, limit: 2)
OathDiagnostics.configure(file: file)
''', None),
        ("event consumer protocol", "let value: (any DiagnosticTransport)? = nil", "cannot find type 'DiagnosticTransport'"),
        ("recorder consumer injection", 'OathDiagnostics.configure(file: URL(fileURLWithPath: "/tmp/fixture"), transport: nil)', "extra argument 'transport'"),
        ("outbox consumer injection", 'let box = DiagnosticOutbox(file: URL(fileURLWithPath: "/tmp/fixture"), transport: nil)', "extra argument 'transport'"),
    ]
    with tempfile.TemporaryDirectory(prefix="oath-diagnostics-boundary-") as temporary:
        source = Path(temporary) / "Probe.swift"
        for label, code, expected in probes:
            source.write_text("import Foundation\nimport OathDiagnostics\n" + code + "\n")
            result = subprocess.run([
                "xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-sdk", sdk,
                "-target", "arm64-apple-ios17.0", "-I", str(products), str(source),
            ], capture_output=True, text=True)
            if expected is None:
                if result.returncode:
                    raise SystemExit(f"Positive probe failed: {label}\n{result.stderr}")
            elif result.returncode == 0 or expected not in result.stderr:
                raise SystemExit(f"Expected compiler rejection missing: {label}\n{result.stderr}")
    symbols = subprocess.check_output(["xcrun", "nm", str(binary)], text=True)
    symbols = subprocess.run(["xcrun", "swift-demangle"], input=symbols, text=True, capture_output=True, check=True).stdout
    if "DiagnosticTransport" in symbols or "transport:" in symbols or ".upload(" in symbols:
        raise SystemExit("The iOS diagnostics binary contains an event consumer hook.")
    print("iOS diagnostics boundary passed: on-device API accepted; 3 consumer APIs rejected; binary contains no consumer hooks.")


if __name__ == "__main__":
    main()
