#!/usr/bin/env python3
"""Opt-in focused iOS check for native toolbar sizing and List geometry."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()

def declaration(path, marker):
    text = (ROOT / path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('State the unresolved native toolbar concern before opting into a simulator check.')
    args.output.mkdir(parents=True, exist_ok=True)
    header = (ROOT / 'OathAtmosphere/Home/OathHomeHeaderSurface.swift').read_text()
    declarations = header[header.index('struct OathHomeToolbar:'):]
    declarations += '\n' + declaration('OathAtmosphere/Home/OathWalletSidebar.swift', 'struct OathWalletSidebarButton<')
    for marker in ['enum OathWalletSummaryStyle', 'struct OathBalanceText:', 'struct OathWalletBalance:']:
        declarations += '\n' + declaration('OathAtmosphere/Home/OathWalletSummary.swift', marker)
    declarations += '\n' + (ROOT / 'OathAtmosphere/Shared/OathBalanceConcealment.swift').read_text()
    probe = (ROOT / 'Tools/HomeToolbarRegression/Probe.swift').read_text().replace('// PRODUCTION_DECLARATIONS', declarations)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-home-toolbar-ui-') as temporary:
        work = Path(temporary)
        (work / 'Probe.swift').write_text(probe)
        spec = {'name': 'HomeToolbarProbe', 'options': {'deploymentTarget': {'iOS': '26.0'}},
            'packages': {'OathNativeRefresh': {'path': str(ROOT / 'Packages/OathNativeRefresh')}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '5.0', 'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'HomeToolbarProbe': {'type': 'application', 'platform': 'iOS', 'sources': [str(work / 'Probe.swift')],
                    'dependencies': [{'package': 'OathNativeRefresh'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.home-toolbar-probe', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'ToolbarUITests': {'type': 'bundle.ui-testing', 'platform': 'iOS',
                    'sources': [str(ROOT / 'Tools/HomeToolbarRegression/ToolbarUITests.swift')],
                    'dependencies': [{'target': 'HomeToolbarProbe'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.home-toolbar-probe.tests'}}}},
            'schemes': {'HomeToolbarProbe': {'build': {'targets': {'HomeToolbarProbe': 'all', 'ToolbarUITests': ['test']}},
                'test': {'targets': ['ToolbarUITests']}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work / 'project.yml'))
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath Home Toolbar ' + uuid.uuid4().hex[:8],
                'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output / 'test.log').open('w') as log:
                result = subprocess.run(['xcodebuild', '-project', str(work / 'HomeToolbarProbe.xcodeproj'),
                    '-scheme', 'HomeToolbarProbe', '-destination', 'platform=iOS Simulator,id=' + device,
                    '-derivedDataPath', str(work / 'DerivedData'), '-resultBundlePath', str(args.output / 'Result.xcresult'),
                    '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', 'test'], stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise SystemExit('Native toolbar check failed; inspect ' + str(args.output / 'test.log'))
            print('PASS: one iOS simulator, synthetic wallet, native List scroll boundary, toolbar action, privacy and long-name layout')
        finally:
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True)
                subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True)

if __name__ == '__main__':
    main()
