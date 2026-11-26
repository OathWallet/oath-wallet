#!/usr/bin/env python3
"""Host checks: compile the production coordinator unchanged; no wallets/network."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="oath-sidebar-check-") as temporary:
    executable = str(Path(temporary) / "check")
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
        str(ROOT / "OathAtmosphere/Home/OathWalletSidebarModel.swift"),
        str(ROOT / "Tools/WalletSidebarTests.swift"), "-o", executable], check=True)
    subprocess.run([executable], check=True)

# Integration contracts complement behavioral tests, not runtime UI evidence.
home = (ROOT / "OathAtmosphere/Home/OathHomeScreen.swift").read_text()
change = home.split('.onChange(of: profile?.id)', 1)[1].split('.sheet(item:', 1)[0]
assert "selectedTab =" not in change, "Wallet switches must retain the main tab"
for fragment in ['assetPath.removeAll()', 'historyQuery = ""', 'historyFilters = .init()', 'query = ""', 'searchScope = .all', 'tokenSearch.reset()']:
    assert fragment in change
assert 'startsAtAddWallet: true' in home
assert '.navigate(.support): openURL(OathSupportLinks.help)' in home
assert 'await session.selectWallet(uuid)' in home
assert 'await sidebarBalances.observe(session: session)' in home
assert '!sidebar.isVisible' in home
assert '.id(profile?.id)' in home, 'History routes must be scoped to the wallet'
toolbar = (ROOT / "OathAtmosphere/Home/OathHomeHeaderSurface.swift").read_text()
assert 'OathWalletSidebarButton(accessibilityValue:' in toolbar.split('struct OathHomeToolbar:', 1)[1]
history_root = home.split('private var historyNavigation:', 1)[1].split('private var searchNavigation:', 1)[0]
assert '.id(accountScopeIdentity)' in history_root
assert '.searchable(text: $historyQuery' in history_root
assert 'NavigationStack {' in history_root and '.toolbar(.visible, for: .tabBar)' in history_root
assert 'Tab(value: .history)' in home and '.tag(OathHomeTab.history)' in home
assert '.accessibilityIdentifier("home.history")' not in toolbar
assert 'assetPath.isEmpty && !historyVisible' in home, 'Receipt back swipes must not open the sidebar'
assert sum(path.read_text().count('OathWalletSidebarButton(')
           for path in (ROOT / "OathAtmosphere").rglob("*.swift") if not path.name.startswith("._")) == 1, \
    'Show the wallet switcher only on Home'
print("PASS: tab preservation, old-wallet routes/search clearing and existing-flow integration contracts")
