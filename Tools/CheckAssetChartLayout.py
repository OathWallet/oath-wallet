#!/usr/bin/env python3
"""Opt-in native List animation regression using only synthetic asset data."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def run(*args, timeout=120):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=timeout).stdout.strip()


def verify(frames):
    # Presentation-layer geometry catches movement between settled layouts.
    # Checking only the start/end frames missed the original 115pt header jump.
    phases = {phase: [f for f in frames if f["phase"] == phase]
              for phase in ("initial", "open", "close", "open2", "close2", "final")}
    assert all(phases.values()), "Every expansion/collapse phase must be sampled"
    assert all(all(key in f for key in ("header", "market", "transactions", "scrollOffset"))
               for f in frames), "A presentation marker was missing"
    initial = phases["initial"][-1]
    tolerance = 0.5  # subpixel rounding is allowed; layout movement is not
    header_motion = max(abs(f["header"][i] - initial["header"][i])
                        for f in frames for i in range(4))
    assert header_motion <= tolerance, f"Balance card moved/resized by {header_motion:.3f}pt"
    assert all(f["headerOpacity"] >= 0.99 for f in frames), "Balance card faded"
    assert all(abs(f["market"][1] - initial["market"][1]) <= tolerance for f in frames), \
        "The market card's top moved"
    assert all(abs(f["scrollOffset"] - initial["scrollOffset"]) <= tolerance for f in frames), \
        "Chart toggling changed the scroll position"

    collapsed = initial["transactions"][1]
    expanded = phases["open"][-1]["transactions"][1]
    travel = expanded - collapsed
    assert travel > 180, "Chart must still expand and move transactions below it"
    for phase in ("close", "close2", "final"):
        assert abs(phases[phase][-1]["transactions"][1] - collapsed) <= tolerance, \
            f"Transactions did not return after {phase}"
    for phase in ("open", "close"):
        intermediate = {round(f["transactions"][1], 1) for f in phases[phase]
                        if collapsed + 1 < f["transactions"][1] < expanded - 1}
        assert len(intermediate) >= 2, f"Transactions snapped instead of animating during {phase}"
    return {"frames": len(frames), "maximumHeaderMovement": header_motion,
            "transactionTravel": travel, "headerVisible": True, "scrollPositionUnchanged": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-check", action="store_true",
                        help="Opt in only for an unresolved runtime concern under AGENTS.md")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error("This check launches its own simulator; --simulator-check is required.")
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    with tempfile.TemporaryDirectory(prefix="oath-chart-probe-") as temporary:
        work = Path(temporary)
        shutil.copy(root / "Tools/Fixtures/AssetChartLayoutProbe.swift", work / "Probe.swift")
        spec = {
            "name": "OathChartProbe",
            "options": {"deploymentTarget": {"iOS": "17.0"}},
            "packages": {"OathNativeRefresh": {"path": str(root / "Packages/OathNativeRefresh")}},
            "targets": {"OathChartProbe": {
                "type": "application", "platform": "iOS",
                "sources": ["Probe.swift", str(root / "OathAtmosphere/Home/OathHomeBodySurface.swift"),
                            str(root / "OathAtmosphere/OathEmptyStateLayout.swift")],
                "dependencies": [{"package": "OathNativeRefresh"}],
                "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.chart-probe",
                    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                    "CODE_SIGNING_ALLOWED": "NO", "SWIFT_VERSION": "6.0"}}
            }}
        }
        (work / "project.yml").write_text(json.dumps(spec))
        run("xcodegen", "generate", "--spec", str(work / "project.yml"))
        build = subprocess.run([
            "xcodebuild", "-project", str(work / "OathChartProbe.xcodeproj"),
            "-scheme", "OathChartProbe", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(work / "build"), "CODE_SIGNING_ALLOWED=NO", "build"
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
        (args.output / "build.log").write_text(build.stdout)
        build.check_returncode()
        try:
            device = run("xcrun", "simctl", "create", "Oath Chart Probe " + uuid.uuid4().hex[:8],
                         "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", args.runtime)
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=180)
            run("xcrun", "simctl", "install", device,
                str(work / "build/Build/Products/Debug-iphonesimulator/OathChartProbe.app"))
            results = {}
            for mode in ("populated", "empty"):
                run("xcrun", "simctl", "launch", device, "org.oathwallet.chart-probe",
                    *(["--empty"] if mode == "empty" else []))
                container = Path(run("xcrun", "simctl", "get_app_container", device,
                                     "org.oathwallet.chart-probe", "data"))
                result = container / "Documents/result.json"
                deadline = time.monotonic() + 30
                while not result.exists() and time.monotonic() < deadline:
                    time.sleep(0.25)
                frames = json.loads(result.read_text())
                (args.output / f"{mode}.json").write_text(json.dumps(frames, indent=2) + "\n")
                results[mode] = verify(frames)
                run("xcrun", "simctl", "terminate", device, "org.oathwallet.chart-probe")
                result.unlink()
            (args.output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
            print("PASS: header stays visible and fixed; chart/transactions animate through repeated toggles")
        finally:
            if device:
                subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", device], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()
