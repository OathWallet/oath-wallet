#!/usr/bin/env python3
"""Host-only checks for the production welcome capsule sequence and bundled logos."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sources = [
    "OathAtmosphere/OathFeatureRotation.swift",
    "OathAtmosphere/Import/OathImportCatalog.swift",
    "OathAtmosphere/Localization/OathStringKey.swift",
    "OathAtmosphere/Localization/OathLocalization.swift",
    "OathAtmosphere/Localization/OathLanguageCatalog.swift",
]
with tempfile.TemporaryDirectory(prefix="oath-feature-rotation-") as directory:
    executable = Path(directory) / "check"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-warnings-as-errors",
        *[str(ROOT / path) for path in sources],
        str(ROOT / "Tools/CheckFeatureRotation.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)

    # Ask the production model for its artwork names instead of duplicating
    # the featured-chain list in this resource-availability check.
    main = Path(directory) / "main.swift"
    main.write_text(
        'import Foundation\n'
        'print(String(decoding: try JSONEncoder().encode('
        'OathFeatureRotation.receiveChains.map(\\.logoAsset)), as: UTF8.self))\n'
    )
    subprocess.run([
        "swiftc", *[str(ROOT / path) for path in sources],
        str(main), "-o", str(executable),
    ], check=True)
    for logo in json.loads(subprocess.check_output([str(executable)])):
        folder = ROOT / "OathApp/Assets.xcassets/Networks" / f"{logo}.imageset"
        catalog = json.loads((folder / "Contents.json").read_text())
        images = [row["filename"] for row in catalog["images"] if "filename" in row]
        assert images and all((folder / image).is_file() for image in images), logo
    print("PASS: all 12 chain logos are bundled for immediate first presentation")
