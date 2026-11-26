#!/usr/bin/env python3
"""Opt-in native back-gesture regression. Uses synthetic screens and a disposable simulator."""
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
        parser.error('State the unresolved native navigation concern first, then opt in with --simulator-check.')
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-native-back-') as temporary:
        work = Path(temporary)
        spec = {
            'name': 'BackGestureProbe', 'options': {'deploymentTarget': {'iOS': '26.0'}},
            'packages': {'OathNativeRefresh': {'path': str(root / 'Packages/OathNativeRefresh')}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0',
                                  'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'BackGestureProbe': {
                    'type': 'application', 'platform': 'iOS',
                    'sources': [str(root / 'Tools/NativeBackGesture/Probe.swift'),
                                str(root / 'OathAtmosphere/Shared/OathNativeBackGesture.swift')],
                    'dependencies': [{'package': 'OathNativeRefresh'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.back-gesture-probe',
                                          'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'GestureUITests': {
                    'type': 'bundle.ui-testing', 'platform': 'iOS',
                    'sources': [str(root / 'Tools/NativeBackGesture/GestureUITests.swift')],
                    'dependencies': [{'target': 'BackGestureProbe'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.back-gesture-probe.tests'}}}},
            'schemes': {'BackGestureProbe': {'build': {'targets': {'BackGestureProbe': 'all', 'GestureUITests': ['test']}},
                                             'test': {'targets': ['GestureUITests']}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work / 'project.yml'))
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath Native Back ' + uuid.uuid4().hex[:8],
                         'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max',
                         'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output / 'test.log').open('w') as log:
                result = subprocess.run([
                    'xcodebuild', '-project', str(work / 'BackGestureProbe.xcodeproj'), '-scheme', 'BackGestureProbe',
                    '-destination', 'platform=iOS Simulator,id=' + device, '-derivedDataPath', str(work / 'build'),
                    '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-resultBundlePath', str(args.output / 'Gestures.xcresult'), 'test'
                ], stdout=log, stderr=subprocess.STDOUT, timeout=900)
            result.check_returncode()
            print('PASS: native edge/content back, cancellation, RTL, nested navigation and protected screens')
        finally:
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
                subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)


if __name__ == '__main__':
    main()
