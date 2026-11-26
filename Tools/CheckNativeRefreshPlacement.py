#!/usr/bin/env python3
"""Opt-in UIKit placement/gesture regression using an isolated synthetic app."""
import argparse
import csv
import json
import statistics
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180).stdout.strip()


def check_band_trace(path, pale):
    with path.open() as stream:
        frames = [{key: float(value) for key, value in row.items()} for row in csv.DictReader(stream)]
    activation = next(frame["activated"] for frame in frames if frame["activated"])
    held = [frame for frame in frames if 1 <= frame["t"] - activation <= 3.3]
    if len(held) < 10:
        raise AssertionError("Missing held frames")
    rest = frames[0]
    height = statistics.median(frame["bandHeight"] for frame in held)
    for pool in ("coolX", "warmX"):
        positions = [frame[pool] for frame in held]
        assert max(positions) - min(positions) > 0.2, f"{pool} did not drift during the hold"
    assert all(f["edgeError"] <= 1 for f in frames if f["bandHeight"] > 1), "Aurora did not fill the visible band"
    for frame in held:
        assert abs(frame["bar"] - rest["bar"] - 92) <= 2, "toolbar travel"
        assert abs(frame["row"] - rest["row"] - 92) <= 2, "row travel"
        assert abs(frame["bandTop"]) <= 1 and abs(frame["bandHeight"] - height) <= 1, "band position"
        assert abs(frame["bar"] - (frame["bandTop"] + frame["bandHeight"]) - 12) <= 2, "gap below the band"
        assert abs(frame["spinnerY"] - (height - 43.5)) <= 2, "spinner position"
        assert frame["ink"] == (0 if pale else 1), "spinner contrast"
    pulling = [f for f in frames if f["pan"] == 2]
    inside_padding = [f for f in pulling if 2 < f["bandHeight"] < rest["bar"] - 13]
    assert len(inside_padding) >= 2, "missing initial pull samples"
    assert all(abs(f["bar"] - rest["bar"]) < 1 for f in inside_padding), "toolbar moved inside its resting padding"
    assert any(f["row"] > rest["row"] + 3 for f in inside_padding), "native list did not follow the finger"
    peak = max(pulling, key=lambda f: f["bandHeight"])
    bar_pull = peak["bar"] - rest["bar"]
    page_pull = peak["row"] - rest["row"]
    band_pull = peak["bandTop"] + peak["bandHeight"] - rest["bar"]
    assert band_pull >= 80 and abs(bar_pull - band_pull - 12) <= 2, "overpull toolbar spacing"
    beyond_padding = [f for f in pulling if f["bandHeight"] > rest["bar"]]
    assert all(abs((f["row"] - f["bar"]) - (peak["row"] - peak["bar"])) <= 2
               for f in beyond_padding), "rows separated from the toolbar after contact"
    for previous, current in zip(pulling, pulling[1:]):
        if current["bandHeight"] > previous["bandHeight"] + 1:
            assert current["row"] >= previous["row"] - 1, "list jumped backwards during the pull"
    changes = [held[i] for i in range(1, len(held)) if held[i]["step"] != held[i - 1]["step"]]
    assert len(changes) >= 10, "stationary spinner"
    intervals = [b["t"] - a["t"] for a, b in zip(changes, changes[1:])]
    assert abs(statistics.median(intervals) - 0.1) < 0.025, "spinner cadence"
    assert all((b["step"] - a["step"]) % 8 == 1 for a, b in zip(changes, changes[1:])
               if b["t"] - a["t"] < 0.14), "spinner direction"
    end = next(f["t"] for f in frames if f["t"] > activation + 3.3 and f["bandHeight"] < 0.05)
    closing = max(f["t"] for f in frames if activation + 3.3 < f["t"] < end and abs(f["bandHeight"] - height) < 0.25)
    assert abs(closing - activation - 3.5) <= 0.07, "display deadline"
    assert abs(end - closing - 0.28) <= 0.05, "return duration"
    returning = [f for f in frames if closing <= f["t"] <= end]
    assert len({f["step"] for f in returning if f["opacity"] > 0.25}) >= 2, "spinner froze during dismissal"
    for previous, current in zip(returning, returning[1:]):
        assert current["bar"] <= previous["bar"] + 0.5, "toolbar reversed during return"
        assert current["row"] <= previous["row"] + 0.5, "row reversed during return"
    for frame in returning:
        assert abs((frame["row"] - rest["row"]) - (frame["bar"] - rest["bar"])) <= 2, "row and toolbar returned out of step"
    assert sum(2 < f["bar"] - rest["bar"] < 90 for f in returning) >= 5, "missing intermediate return frames"
    print(f"{path.stem}: hold {height:.1f} pt, peak toolbar/page travel {bar_pull:.1f}/{page_pull:.1f} pt, "
          f"closing at {closing - activation:.3f}s in {end - closing:.3f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-check", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--wallet-band", action="store_true", help="Run the focused wallet band gesture and navigation fixture")
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max")
    parser.add_argument("--unmodified-baseline", action="store_true", help="Opt in to the known failing Apple ScrollView reproducer")
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error("State the unresolved runtime concern first, then opt in with --simulator-check.")
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    with tempfile.TemporaryDirectory(prefix="oath-refresh-placement-") as temporary:
        work = Path(temporary)
        shutil.copytree(root / "Tools/NativeRefreshPlacement", work / "Fixture",
                        ignore=shutil.ignore_patterns("._*"))
        # Exercise the actual shared selection row used by the balance-period
        # sheet, without compiling wallet or account services into this fixture.
        settings = (root / "OathAtmosphere/Home/OathSettingsStyle.swift").read_text()
        settings = settings.split("enum OathWalletCreationOptions", 1)[0].replace("import OathTokenImages", "")
        (work / "SettingsRows.swift").write_text(settings)
        spec = {
            "name": "RefreshPlacement", "options": {"deploymentTarget": {"iOS": "26.0"}},
            "packages": {"OathNativeRefresh": {"path": str(root / "Packages/OathNativeRefresh")}},
            "settings": {"base": {"CODE_SIGNING_ALLOWED": "NO", "SWIFT_VERSION": "6.0",
                                   "GENERATE_INFOPLIST_FILE": "YES"}},
            "targets": {
                "RefreshPlacement": {
                    "type": "application", "platform": "iOS", "sources": ["Fixture/Probe.swift", str(root / "OathAtmosphere/Home/OathHomeBodySurface.swift"),
                        str(root / "OathAtmosphere/OathEmptyStateLayout.swift")],
                    "dependencies": [{"package": "OathNativeRefresh"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.refresh-placement",
                        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"}}},
                "PlacementUITests": {
                    "type": "bundle.ui-testing", "platform": "iOS", "sources": ["Fixture/PlacementUITests.swift"],
                    "dependencies": [{"target": "RefreshPlacement"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.refresh-placement.tests"}}},
                "DirectionTests": {
                    "type": "bundle.unit-test", "platform": "iOS", "sources": ["Fixture/DirectionTests.swift", "Fixture/SettingsSupport.swift", "SettingsRows.swift"],
                    "dependencies": [{"target": "RefreshPlacement"}, {"package": "OathNativeRefresh"}],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "org.oathwallet.refresh-direction.tests"}}}
            },
            "schemes": {"RefreshPlacement": {
                "build": {"targets": {"RefreshPlacement": "all", "PlacementUITests": ["test"], "DirectionTests": ["test"]}},
                "test": {"targets": ["PlacementUITests", "DirectionTests"], "environmentVariables": {"OATH_REFRESH_BASELINE": "1" if args.unmodified_baseline else "0"}}}}
        }
        if args.wallet_band:
            spec["targets"]["RefreshPlacement"]["sources"] = ["Fixture/WalletBandProbe.swift"]
            spec["targets"]["PlacementUITests"]["sources"] = ["Fixture/WalletBandUITests.swift"]
            del spec["targets"]["DirectionTests"]
            scheme = spec["schemes"]["RefreshPlacement"]
            del scheme["build"]["targets"]["DirectionTests"]
            scheme["test"]["targets"] = ["PlacementUITests"]
        (work / "project.yml").write_text(json.dumps(spec))
        run("xcodegen", "generate", "--spec", str(work / "project.yml"))
        try:
            device = run("xcrun", "simctl", "create", "Oath Refresh Placement " + uuid.uuid4().hex[:8],
                         args.device_type,
                         "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
            with (args.output / "test.log").open("w") as log:
                result = subprocess.run([
                    "xcodebuild", "-project", str(work / "RefreshPlacement.xcodeproj"),
                    "-scheme", "RefreshPlacement", "-destination", "platform=iOS Simulator,id=" + device,
                    "-derivedDataPath", str(work / "build"), "-parallel-testing-enabled", "NO",
                    "-resultBundlePath", str(args.output / "Placement.xcresult"),
                    *["-only-testing:" + test for test in args.only_testing], "test"
                ], stdout=log, stderr=subprocess.STDOUT, timeout=600)
            result.check_returncode()
            if args.wallet_band:
                # Xcode may shut down a destination it booted after running tests.
                run("xcrun", "simctl", "bootstatus", device, "-b")
                container = Path(run("xcrun", "simctl", "get_app_container", device, "org.oathwallet.refresh-placement", "data"))
                for theme in ("light", "dark"):
                    trace = args.output / f"band-{theme}.csv"
                    shutil.copyfile(container / "tmp" / trace.name, trace)
                    check_band_trace(trace, pale=theme == "dark")
            print("PASS: " + (", ".join(args.only_testing) if args.only_testing else "native refresh placement and interaction regression suite"))
        finally:
            if device:
                subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
                subprocess.run(["xcrun", "simctl", "delete", device], check=True, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()
