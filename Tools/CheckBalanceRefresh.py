#!/usr/bin/env python3
"""Controlled host regressions only; never starts a device, simulator or live provider test."""
from pathlib import Path
import argparse
import json
import re
import subprocess
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--scratch", default="/tmp/oath-balance-refresh-host")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
matrix = json.loads((root / "Tools/BalanceRefreshCoverage.json").read_text())
# Check identities against the compiled production enum, as well as Home formatting.
subprocess.run(["python3", str(root / "Tools/CheckHomePortfolio.py")], check=True, cwd=root)
sources = "\n".join(p.read_text() for p in (root / "Packages/OathDatabase/Tests/OathDatabaseTests").glob("*.swift") if not p.name.startswith("._"))
for test in matrix.values():
    suite, method = test.split(".")
    assert re.search(r"class\s+" + suite + r"\b", sources), suite
    assert "func " + method + "(" in sources, method
regressions = ["PortfolioRefreshCoordinatorTests", "AnkrVerifiedRefreshTests", "RefreshCatalogTests",
               "IndexedEVMLedgerTests.testAllIndexedChainsPreserveCachedBalancesWhenBothProvidersFail", "ExchangeRateTests",
               "AptosLedgerTests.testTokenFailure", "AptosLedgerTests.testDiscoveryFailure", "NearLedgerTests.testContractFailure"]
tests = sorted(set(matrix.values()) | set(regressions))
# A custom diagnostics recorder can only be installed once per process.
isolated = ["AnkrVerifiedRefreshTests", "RefreshCatalogTests"]
batches = [[test for test in tests if test.split(".")[0] not in isolated]]
batches += [[suite] for suite in isolated]
for batch in batches:
    subprocess.run(["swift", "test", "--package-path", str(root / "Packages/OathDatabase"),
                    "--scratch-path", args.scratch, "--build-system", "native", "--filter",
                    "|".join(batch)], check=True, cwd=root)
subprocess.run(["python3", str(root / "Tools/CheckRefreshActions.py")], check=True, cwd=root)
print(f"PASS: all {len(matrix)} enabled chains, reconciliation, observer recovery, fiat and unchanged refresh presentation")
