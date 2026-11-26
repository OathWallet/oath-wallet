#!/usr/bin/env python3
"""Host-only regression for the macOS Settings missing-environment crash.

Compiles Home's actual presentation expressions into a detached macOS hosting
fixture. No simulator, app wallet data, Keychain, or network is used.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def body_after(source: str, marker: str) -> str:
    start = source.index('{', source.index(marker))
    depth = 1
    for end in range(start + 1, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if not depth:
                return source[start + 1:end].strip()
    raise AssertionError('Unclosed production presentation')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home-source', type=Path, help='Optional pre-fix source for a negative-control run')
    args = parser.parse_args()
    source = (args.home_source or ROOT / 'OathAtmosphere/Home/OathHomeScreen.swift').read_text()
    if not args.home_source:
        root = (ROOT / 'OathApp/OathAtmosphereApp.swift').read_text()
        assert 'let settings: OathAppSettings' in source, 'Home must retain the scene settings explicitly'
        assert 'OathHomeScreen(profile: session.displayedProfile, session: session, settings: settings,' in root
    shared = ''
    if 'private func walletContent(_ destination: WalletDestination)' in source:
        cover = body_after(source, '.fullScreenCover(isPresented: $showsAppSettings')
        assert cover == 'walletContent(.settings(.app))'
        sheet = body_after(source, '.sheet(item: $sheet')
        assert 'case .wallet(let destination): walletContent(destination)' in ' '.join(sheet.split())
        body = body_after(source, 'private func walletContent(_ destination: WalletDestination)')
        shared = f'''enum WalletDestination {{
        case settings(OathWalletSettingsScreen.Destination), add(String)
    }}
    func walletContent(_ destination: WalletDestination) -> some View {{
        {body}
    }}'''
        settings = 'walletContent(.settings(destination))'
        wallet = 'walletContent(.add(start))'
    else:
        # Keep the optional pre-fix reproduction usable with its original covers.
        assert args.home_source
        settings = body_after(source, '.fullScreenCover(item: $settingsDestination').split(' in\n', 1)[1]
        wallet = body_after(source, '.fullScreenCover(item: $walletFlow').split(' in\n', 1)[1]
    generated = f'''import SwiftUI
@MainActor struct ProductionPresentation {{
    let settings: OathAppSettings
    let session: OathWalletSession
    let strings = FixtureStrings()
    {shared}
    func settingsContent(destination: OathWalletSettingsScreen.Destination) -> some View {{
        {settings}
    }}
    func walletContent(start: String) -> some View {{
        {wallet}
    }}
}}
'''
    with tempfile.TemporaryDirectory(prefix='oath-settings-presentation-') as directory:
        work = Path(directory)
        (work / 'Production.swift').write_text(generated)
        executable = work / 'OathSettingsPresentationCheck'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                        '-target', 'arm64-apple-macos14.0',
                        str(ROOT / 'Tools/SettingsPresentationRegression/Probe.swift'),
                        str(work / 'Production.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    main()
