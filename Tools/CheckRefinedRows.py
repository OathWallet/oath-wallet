#!/usr/bin/env python3
"""Render production rows and price labels on the Mac; never starts a simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-refined-rows-") as temporary:
    work = Path(temporary)
    row = (root / "OathAtmosphere/Shared/OathRefinedListRow.swift").read_text()
    row = row.replace("import OathTokenImages", "")
    style = (root / "Packages/OathTokenImages/Sources/OathTokenImages/TokenArtworkStyle.swift").read_text()
    row += "\nenum TokenArtworkStyle {" + style.split("public enum TokenArtworkStyle {", 1)[1].split("}\n", 1)[0] + "}\n"
    (work / "Row.swift").write_text(row)
    price = (root / "OathAtmosphere/Home/OathHomeAssetRow.swift").read_text()
    # Keep the real label and preference anchor, without the UIKit asset tree.
    price = price.split("struct OathAssetUnitPrice:", 1)[1].split("extension View {", 1)[0]
    (work / "Price.swift").write_text("import SwiftUI\nstruct OathAssetUnitPrice:" + price)
    executable = work / "RowChecks"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                    str(work / "Row.swift"), str(work / "Price.swift"),
                    str(root / "OathAtmosphere/Home/OathAssetAmountFormat.swift"),
                    str(root / "Tools/CheckRefinedRows.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
