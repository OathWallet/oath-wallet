#!/usr/bin/env python3
"""Opt-in native wallet-family drag regression. Uses fake wallets and a disposable simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import uuid


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('State the unresolved native drag concern first, then opt in with --simulator-check.')
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-wallet-family-') as temporary:
        work = Path(temporary)
        spec = {
            'name': 'WalletFamilyProbe', 'options': {'deploymentTarget': {'iOS': '26.0'}},
            'packages': {'OathDatabase': {'path': str(root / 'Packages/OathDatabase')}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0',
                                  'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'WalletFamilyProbe': {
                    'type': 'application', 'platform': 'iOS',
                    'sources': [str(root / 'Tools/WalletFamilyReorder/Probe.swift'),
                                str(root / 'OathAtmosphere/Home/OathWalletFamilyList.swift')],
                    'dependencies': [{'package': 'OathDatabase'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.family-reorder-probe',
                                          'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'ReorderUITests': {
                    'type': 'bundle.ui-testing', 'platform': 'iOS',
                    'sources': [str(root / 'Tools/WalletFamilyReorder/ReorderUITests.swift')],
                    'dependencies': [{'target': 'WalletFamilyProbe'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.family-reorder-probe.tests'}}}},
            'schemes': {'WalletFamilyProbe': {'build': {'targets': {'WalletFamilyProbe': 'all', 'ReorderUITests': ['test']}},
                                             'test': {'targets': ['ReorderUITests']}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work / 'project.yml'))
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath Wallet Family ' + uuid.uuid4().hex[:8],
                         'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max',
                         'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output / 'test.log').open('w') as log:
                result = subprocess.run([
                    'xcodebuild', '-project', str(work / 'WalletFamilyProbe.xcodeproj'), '-scheme', 'WalletFamilyProbe',
                    '-destination', 'platform=iOS Simulator,id=' + device, '-derivedDataPath', str(work / 'build'),
                    '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-resultBundlePath', str(args.output / 'Reorder.xcresult'), 'test'
                ], stdout=log, stderr=subprocess.STDOUT, timeout=900)
            result.check_returncode()
            print('PASS: native family movement, child boundaries and independent deletion')
        finally:
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
                subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)


if __name__ == '__main__':
    main()
