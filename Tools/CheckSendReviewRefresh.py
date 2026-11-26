#!/usr/bin/env python3
"""Run production review preparation on macOS with deterministic database and RPC fixtures."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-send-review-probe-") as folder:
    work = Path(folder)
    sources = work / "Sources/ReviewProbe"
    sources.mkdir(parents=True)
    for name in ["OathSendBalanceIdentity.swift", "OathSendModel+BalancePreparation.swift"]:
        shutil.copy(root / "OathAtmosphere/Send" / name, sources)
    shutil.copy(root / "Tools/CheckSendReviewRefresh.swift", sources)
    dependency = json.dumps(str(root / "Packages/OathAnkr"))
    (work / "Package.swift").write_text(f"""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReviewProbe", platforms: [.macOS("15.5")],
    dependencies: [.package(path: {dependency})],
    targets: [.executableTarget(name: "ReviewProbe", dependencies: ["OathAnkr"])])
""")
    chains = sorted(json.loads((root / "Tools/SendPreparationCoverage.json").read_text()))
    subprocess.run(["swift", "run", "--build-system", "native", "--package-path", str(work),
                    "ReviewProbe", *chains], check=True)
