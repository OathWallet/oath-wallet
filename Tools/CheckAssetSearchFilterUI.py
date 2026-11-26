#!/usr/bin/env python3
"""Opt-in, isolated Home keyboard search row and nested-sheet regression."""
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
parser.add_argument('--test-name', action='append', help='UI test to run; repeat to select related regressions')
parser.add_argument('--layout-only', action='store_true', help='Only the focused native UIKit layout regression')
parser.add_argument('--ui-only', action='store_true', help='Skip artwork/layout unit tests for a focused UI check')
args = parser.parse_args()
if not args.simulator_check:
    parser.error('State the concrete runtime concern before opting in to simulator use.')
if args.ui_only and (args.layout_only or not args.test_name):
    parser.error('--ui-only requires --test-name and cannot be combined with --layout-only.')
root = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='oath-chain-filter-') as directory:
    work = Path(directory)
    shutil.copytree(root / 'Tools/AssetSearchFilterValidation', work / 'Fixture', ignore=shutil.ignore_patterns('._*'))
    settings = (root / 'OathAtmosphere/Home/OathSettingsStyle.swift').read_text().split('enum OathWalletCreationOptions', 1)[0]
    (work / 'SettingsRows.swift').write_text(settings.replace('import OathTokenImages', ''))
    direction = (root / 'OathAtmosphere/Localization/OathLanguageSettings.swift').read_text()
    direction = direction.split('@MainActor enum OathLayoutDirection', 1)[1].split('private struct OathLanguageEnvironmentKey', 1)[0]
    (work / 'LayoutDirection.swift').write_text('import SwiftUI\nimport UIKit\n@MainActor enum OathLayoutDirection' + direction)
    scene = (root / 'OathAtmosphere/Shared/OathSceneAppearance.swift').read_text().split('struct OathSceneAppearance', 1)[1]
    (work / 'SceneAppearance.swift').write_text('import SwiftUI\nimport UIKit\nstruct OathSceneAppearance' + scene)
    logo = (root / 'OathAtmosphere/Shared/OathNetworkLogo.swift').read_text().replace('import OathTokenImages', '')
    (work / 'NetworkLogo.swift').write_text(logo)
    catalog = (root / 'OathAtmosphere/Home/OathReceiveNetworkGuide.swift').read_text().split('struct OathReceiveExample:', 1)[1]
    (work / 'ArtworkCatalog.swift').write_text('import Foundation\nimport OathDiagnostics\nstruct OathReceiveExample:' + catalog)
    style = (root / 'Packages/OathTokenImages/Sources/OathTokenImages/TokenArtworkStyle.swift').read_text().split('public enum TokenArtworkStyle {', 1)[1].split('}', 1)[0]
    (work / 'ArtworkStyle.swift').write_text('import SwiftUI\npublic enum TokenArtworkStyle {' + style + '}\n')
    shutil.copyfile(root / 'OathApp/Resources/ReceiveAssets.json', work / 'ReceiveAssets.json')
    # Only bundled public chain logos; no credentials, vault or account services.
    shutil.copytree(root / 'OathApp/Assets.xcassets/Networks', work / 'Networks.xcassets', ignore=shutil.ignore_patterns('._*'))
    shutil.copytree(root / 'OathApp/Assets.xcassets/NetworkDisplay', work / 'Networks.xcassets/Display', ignore=shutil.ignore_patterns('._*'))
    catalog_data = json.loads((work / 'ReceiveAssets.json').read_text())
    for network, examples in catalog_data['networks'].items():
        for example in examples:
            if example['id'] == network + ':native' and example.get('usesRedesignedArtwork'):
                for name in [example['artwork'], example['artwork'] + '-display']:
                    for asset in (root / 'OathApp/Assets.xcassets').rglob(name + '.imageset'):
                        shutil.copytree(asset, work / 'Networks.xcassets' / asset.name, ignore=shutil.ignore_patterns('._*'), dirs_exist_ok=True)
    production = ['Home/OathHomeBottomSearch.swift', 'OathEmptyState.swift', 'OathEmptyStateLayout.swift', 'Import/OathImportCatalog.swift', 'Localization/OathTypography.swift',
                  'Tokens/OathAssetSearchScope.swift', 'Tokens/OathAssetSearchFilter.swift', 'Tokens/OathAssetSearchBar.swift', 'Shared/OathTextInputFocus.swift']
    spec = {
        'name': 'ChainFilter', 'options': {'deploymentTarget': {'iOS': '26.0'}},
        'settings': {'base': {'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGNING_ALLOWED': 'NO'}},
        'packages': {'OathDiagnostics': {'path': str(root / 'Packages/OathDiagnostics')}},
        'targets': {
            'Fixture': {'type': 'application', 'platform': 'iOS',
                'sources': ['Fixture/App.swift', 'Fixture/Support.swift', 'SettingsRows.swift', 'LayoutDirection.swift', 'SceneAppearance.swift',
                            'NetworkLogo.swift', 'ArtworkCatalog.swift', 'ArtworkStyle.swift', 'ReceiveAssets.json', 'Networks.xcassets']
                    + [str(root / 'OathAtmosphere' / name) for name in production],
                'dependencies': [{'package': 'OathDiagnostics'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.tests.chain-filter',
                    'ASSETCATALOG_COMPILER_APPICON_NAME': '',
                    'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
            'ArtworkTests': {'type': 'bundle.unit-test', 'platform': 'iOS', 'sources': ['Fixture/ArtworkTests.swift', 'Fixture/SearchRowLayoutTests.swift'],
                'dependencies': [{'target': 'Fixture'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.tests.chain-filter.artwork'}}},
            'FilterTests': {'type': 'bundle.ui-testing', 'platform': 'iOS', 'sources': ['Fixture/FilterTests.swift'],
                'dependencies': [{'target': 'Fixture'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.tests.chain-filter.tests'}}}},
        'schemes': {'Fixture': {'build': {'targets': {'Fixture': 'all'}}, 'test': {'targets': ['ArtworkTests', 'FilterTests']}}}}
    (work / 'project.yml').write_text(json.dumps(spec))
    subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True, capture_output=True)
    device = subprocess.check_output(['xcrun', 'simctl', 'create', 'Oath Chain Filter ' + uuid.uuid4().hex[:8],
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], text=True).strip()
    try:
        # Wait for this disposable device's services before XCTest installs its
        # host and runner. A booted state alone does not mean launchd is ready.
        subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, capture_output=True, timeout=60)
        with (args.output / 'boot.log').open('w') as boot_log:
            subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'],
                check=True, stdout=boot_log, stderr=subprocess.STDOUT, timeout=180)
        with (args.output / 'test.log').open('w') as log:
            result = subprocess.run(['xcodebuild', '-project', str(work / 'ChainFilter.xcodeproj'), '-scheme', 'Fixture',
                '-destination', 'platform=iOS Simulator,id=' + device, '-parallel-testing-enabled', 'NO',
                '-derivedDataPath', str(work / 'build'), '-resultBundlePath', str(args.output / 'Tests.xcresult')]
                + (['-only-testing:ArtworkTests/SearchRowLayoutTests'] if args.layout_only else
                   ([] if args.ui_only else ['-only-testing:ArtworkTests']) + ['-only-testing:FilterTests/FilterTests/' + name for name in args.test_name] if args.test_name else []) + ['test'],
                stdout=log, stderr=subprocess.STDOUT, timeout=600)
        result.check_returncode()
        if args.layout_only:
            print('PASS: focused production native search-row layout checks')
        elif args.ui_only:
            print('PASS: focused UI checks: ' + ', '.join(args.test_name))
        else:
            print('PASS: production artwork/layout checks and ' + (', '.join(args.test_name) if args.test_name else 'all native search UI regressions'))
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True, check=True, timeout=60)
