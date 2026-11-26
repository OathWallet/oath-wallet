#!/usr/bin/env python3
"""Host-only import regressions using production parsing and public seed vectors."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-mnemonic-import-") as temporary:
    work = Path(temporary)
    sources = work / "Sources/MnemonicImportChecks"
    sources.mkdir(parents=True)
    for file in ["OathMnemonicValidator.swift", "OathRecoveryPhraseDraft.swift"]:
        shutil.copyfile(root / "OathAtmosphere/Import" / file, sources / file)
    shutil.copyfile(root / "Tools/CheckMnemonicImport.swift", sources / "CheckMnemonicImport.swift")
    packages = ["OathAezeed", "OathBitcoin", "OathDiagnostics"]
    dependencies = ", ".join(".package(path: " + json.dumps(str(root / "Packages" / name)) + ")" for name in packages)
    (work / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "MnemonicImportChecks", platforms: [.macOS("15.5")],
    dependencies: [%s],
    targets: [.executableTarget(name: "MnemonicImportChecks", dependencies: %s)],
    swiftLanguageModes: [.v6])
""" % (dependencies, json.dumps(packages)))
    subprocess.run(["swift", "run", "--jobs", "4", "--build-system", "native", "--package-path", str(work),
                    "--scratch-path", "/private/tmp/oath-mnemonic-import-host-build", "MnemonicImportChecks",
                    str(root / "OathApp/Resources/BIP39")], cwd=root, check=True)
