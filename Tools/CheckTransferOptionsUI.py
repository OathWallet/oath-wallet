#!/usr/bin/env python3
"""Opt-in check of the production four-line editor inside a nested options sheet."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator-check', action='store_true')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not args.simulator_check:
    parser.error('State a concrete keyboard/layout uncertainty before simulator use.')
root = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='oath-transfer-options-') as directory:
    work = Path(directory)
    shutil.copytree(root / 'Tools/TransferOptionsValidation', work / 'Fixture', ignore=shutil.ignore_patterns('._*'))
    def read(name): return (root / name).read_text()
    # Copy the real sheet and the exact network/byte-limit declarations it uses,
    # excluding signing, wallet keys, providers and unrelated Bitcoin machinery.
    (work / 'Options.swift').write_text(read('OathAtmosphere/Send/OathSendOptionsSheet.swift').replace('import OathBitcoin', ''))
    network = read('Packages/OathBitcoin/Sources/OathBitcoin/UTXONetwork.swift').split('    public var maximumMoney', 1)[0]
    options = read('Packages/OathBitcoin/Sources/OathBitcoin/BitcoinSendOptions.swift').split('    public func validate', 1)[0]
    (work / 'Rules.swift').write_text(network + '}\n' + options + '}\n')
    style = read('OathAtmosphere/Shared/OathInputStyle.swift')
    (work / 'InputStyle.swift').write_text(style.split('/// Paste belongs', 1)[0] + 'extension View {' + style.rsplit('extension View {', 1)[1])
    hairline = read('OathAtmosphere/Shared/OathRefinedListRow.swift').split('/// One row system', 1)[0]
    (work / 'Hairline.swift').write_text(hairline.replace('import OathTokenImages', ''))
    direction = read('OathAtmosphere/Localization/OathLanguageSettings.swift').split('@MainActor enum OathLayoutDirection', 1)[1].split('private struct OathLanguageEnvironmentKey', 1)[0]
    (work / 'Direction.swift').write_text('import SwiftUI\nimport UIKit\n@MainActor enum OathLayoutDirection' + direction)
    (work / 'NeutralColors.swift').write_text(read('OathAtmosphere/OathColorway.swift').split('/// Named and custom accents', 1)[0])
    (work / 'SceneAppearance.swift').write_text(read('OathAtmosphere/Shared/OathSceneAppearance.swift').replace('import OathDatabase', ''))
    catalog = json.loads(read('OathApp/Resources/Localizable.xcstrings'))['strings']
    (work / 'Strings.json').write_text(json.dumps({lang: {key: entry.get('localizations', {}).get(lang, {}).get('stringUnit', {}).get('value', key)
        for key, entry in catalog.items()} for lang in ['en', 'ar']}))
    production = ['Shared/OathMultilineTextInput.swift', 'Shared/OathKeyboardAccessory.swift', 'Shared/OathTextInputFocus.swift',
                  'Localization/OathTypography.swift', 'Localization/OathStringKey.swift']
    spec = {'name': 'TransferOptions', 'options': {'deploymentTarget': {'iOS': '17.0'}},
        'settings': {'base': {'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGNING_ALLOWED': 'NO'}},
        'packages': {'OathDiagnostics': {'path': str(root / 'Packages/OathDiagnostics')}},
        'targets': {
            'Fixture': {'type': 'application', 'platform': 'iOS',
                'sources': ['Fixture/App.swift', 'Fixture/Support.swift', 'Options.swift', 'Rules.swift', 'InputStyle.swift',
                            'Hairline.swift', 'Direction.swift', 'NeutralColors.swift', 'SceneAppearance.swift', 'Strings.json']
                    + [str(root / 'OathAtmosphere' / name) for name in production],
                'dependencies': [{'package': 'OathDiagnostics'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.tests.transfer-options',
                    'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
            'UITests': {'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': ['Fixture/Tests.swift'],
                'dependencies': [{'target': 'Fixture'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.tests.transfer-options.tests'}}}},
        'schemes': {'Fixture': {'build': {'targets': {'Fixture': 'all'}}, 'test': {'targets': ['UITests']}}}}
    (work / 'project.yml').write_text(json.dumps(spec))
    subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True, capture_output=True)
    device = subprocess.check_output(['xcrun', 'simctl', 'create', 'Oath Transfer Options ' + uuid.uuid4().hex[:8],
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], text=True).strip()
    try:
        with (args.output / 'test.log').open('w') as log:
            result = subprocess.run(['xcodebuild', '-project', str(work / 'TransferOptions.xcodeproj'), '-scheme', 'Fixture',
                '-destination', 'platform=iOS Simulator,id=' + device, '-parallel-testing-enabled', 'NO',
                '-derivedDataPath', str(work / 'build'), '-resultBundlePath', str(args.output / 'Tests.xcresult'), 'test'],
                stdout=log, stderr=subprocess.STDOUT, timeout=600)
        result.check_returncode()
        print('PASS: production options sheet/editor/accessory, four-line scrolling, hide keyboard, save and cancel in LTR/RTL')
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True, check=True, timeout=60)
