#!/usr/bin/env python3
"""Host-test Home's production reminder scheduling with a suspended local claim.

Only the database transport and surrounding navigation/session state are fakes.
No wallet secrets, network, simulator or device are used.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator-check', action='store_true', help='Opt in only for an unresolved native presentation concern')
parser.add_argument('--output', type=Path, help='Native test log and result bundle destination')
args = parser.parse_args()
if args.simulator_check and args.output is None:
    parser.error('--simulator-check requires --output')
home = (ROOT / 'OathAtmosphere/Home/OathHomeScreen.swift').read_text()
state = home[home.index('    // A committed offer'):home.index('    @Environment(\\.oathLocalizer)')]
logic = home[home.index('    private var nextSecurityNotice:'):home.index('    @ViewBuilder private var savedHistoryUpdates:')]
availability = home[home.index('    private var shouldPreparePortfolio:'):home.index('    private var balanceHistoryVisible:')]
queue = (ROOT / 'Packages/OathDatabase/Sources/OathDatabase/WalletSecurityNoticeQueue.swift').read_text()
records = (ROOT / 'Packages/OathDatabase/Sources/OathDatabase/Records.swift').read_text()
offer = records[records.index('public enum WalletBackupOffer:'):records.index('public struct WalletRecord:')]
offer = offer.replace(', DatabaseValueConvertible', '')
cloud = (ROOT / 'Packages/OathDatabase/Sources/OathDatabase/CloudBackups.swift').read_text()
status = cloud[cloud.index('public enum WalletCloudBackupStatus:'):cloud.index('extension OathDatabase')]
fixture = (ROOT / 'Tools/BackupOfferPresentationRegression/Host.swift').read_text()
production = (state + availability + logic).replace('@State ', '').replace('private ', '')
production = production.replace('Task {', 'Task { [self] in')
fixture = fixture.replace('// PRODUCTION_SCHEDULING', production)
with tempfile.TemporaryDirectory(prefix='oath-backup-presentation-') as directory:
    work = Path(directory)
    source = work / 'Check.swift'
    source.write_text(queue + offer + status + fixture)
    executable = work / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                    '-parse-as-library', str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

if args.simulator_check:
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='oath-backup-native-') as directory:
        work = Path(directory)
        native = fixture.split('@main struct Check {')[0]
        native = native.replace('import Foundation', 'import Foundation\nimport SwiftUI\nimport XCTest')
        native = native.replace('@MainActor final class Home {', '@MainActor @Observable final class Home {')
        (work / 'Production.swift').write_text(queue + offer + status + native)
        start = home.index('    private var walletNavigation: some View {')
        start = home.index('                .background {', start)
        appearance = home[start:home.index('                // Asset details', start)]
        appearance = appearance.replace('homeHasAppeared', 'home.homeHasAppeared').replace('presentNextSecurityNotice()', 'home.presentNextSecurityNotice()')
        tests = (ROOT / 'Tools/BackupOfferPresentationRegression/Native.swift').read_text()
        (work / 'Tests.swift').write_text(tests.replace('// PRODUCTION_BACKUP_APPEARANCE', appearance))
        (work / 'App.swift').write_text('import SwiftUI\n@main struct Probe: App { var body: some Scene { WindowGroup { Color.clear } } }')
        spec = {
            'name': 'BackupProbe', 'options': {'deploymentTarget': {'iOS': '17.0'}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'BackupProbe': {'type': 'application', 'platform': 'iOS', 'sources': ['App.swift'],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.backup-probe', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'ProbeTests': {'type': 'bundle.unit-test', 'platform': 'iOS',
                    'sources': ['Production.swift', 'Tests.swift', str(ROOT / 'OathAtmosphere/Shared/OathAutofocus.swift'),
                                str(ROOT / 'OathAtmosphere/Shared/OathAutofocusGate.swift')],
                    'dependencies': [{'target': 'BackupProbe'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.backup-probe.tests'}}}},
            'schemes': {'BackupProbe': {'build': {'targets': {'BackupProbe': 'all', 'ProbeTests': ['test']}},
                'test': {'targets': ['ProbeTests']}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        subprocess.run(['xcodegen', 'generate', '--spec', str(work / 'project.yml')], check=True, capture_output=True)
        device = subprocess.check_output(['xcrun', 'simctl', 'create', 'Oath Backup Probe ' + uuid.uuid4().hex[:8],
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'], text=True).strip()
        try:
            with (args.output / 'test.log').open('w') as log:
                result = subprocess.run(['xcodebuild', '-project', str(work / 'BackupProbe.xcodeproj'), '-scheme', 'BackupProbe',
                    '-destination', 'platform=iOS Simulator,id=' + device, '-derivedDataPath', str(work / 'build'),
                    '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                    '-resultBundlePath', str(args.output / 'Native.xcresult'), 'test'],
                    stdout=log, stderr=subprocess.STDOUT, timeout=480)
            result.check_returncode()
            print('PASS: native sheet during looping Home animation, editor dismissal, ongoing background updates and no duplicate presentation.')
        finally:
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
            subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)
