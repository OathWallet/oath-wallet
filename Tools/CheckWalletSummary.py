#!/usr/bin/env python3
"""Render the production shared wallet summary on the Mac host; no simulator."""
from pathlib import Path
import re
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]


def declaration(path, name):
    text = (root / path).read_text()
    start = text.index(name)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


# The app entry points must retain the common composition, not merely import it.
for path in ["Home/OathHomeScreen.swift", "Assets/OathAssetDetailScreen.swift"]:
    source = (root / "OathAtmosphere" / path).read_text()
    summary = source.split("private func summary(", 1)[1].split("\n    private ", 1)[0]
    assert re.search(r"OathWalletSummary(?:\([^)]*\))?\s*\{", summary) and "OathWalletBalance(" in summary
    assert ".font(.system(size:" not in summary and "OathWalletSummaryLayout(" not in summary
    assert "OathWalletHeaderBackground" not in source
    assert "OathSurfaceColors.groupedCanvas" in source
    for action, icon in [("send", "paperplane"), ("receive", "qrcode")]:
        assert f'OathActionButton(title: strings.text(.{action}), icon: "{icon}", appearance: .wallet)' in source
    if path.startswith("Home/"):
        assert "OathWalletSummary(topInset: 16, bottomInset: 0)" in summary
        assert "timing: .fixed(.seconds(2))" in source and "try await session.refresh()" in source
    else:
        assert "timing: .fixed(.milliseconds(1_500))" in source and "action: refresh" in source
        assert "OathBalanceText(value: strings.invariant(format.native(holding.nativeDisplayValue, ticker: holding.symbol))" in summary

with tempfile.TemporaryDirectory(prefix="oath-wallet-summary-") as temporary:
    work = Path(temporary)
    # Compile the production layouts and button surface without UIKit navigation.
    buttons = "OathAtmosphere/Shared/OathActionButton.swift"
    layouts = work / "Layouts.swift"
    layouts.write_text("import SwiftUI\n" + declaration(
        "OathAtmosphere/Home/OathHomeBodySurface.swift", "struct OathWalletSummaryLayout<")
        + "\n" + declaration(buttons, "private struct OathActionAreaLayout:")
        + "\n" + declaration(buttons, "struct OathActionLabel:")
        + "\n" + declaration(buttons, "struct OathWalletActionStyle:")
        + "\nextension View {\n" + declaration(buttons, "func oathActionDimensions(")
        + "\nfunc oathActionArea(existingInset: CGFloat = 0) -> some View {"
          " OathActionAreaLayout(existingInset: existingInset) { self } } }\n")
    executable = work / "CheckWalletSummary"
    subprocess.run(["swiftc", str(layouts),
                    str(root / "OathAtmosphere/Shared/OathActionMetrics.swift"),
                    str(root / "OathAtmosphere/Shared/OathBalanceConcealment.swift"),
                    str(root / "OathAtmosphere/Home/OathWalletSummary.swift"),
                    str(root / "Tools/CheckWalletSummary.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable), *sys.argv[1:]], check=True)
