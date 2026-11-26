#!/usr/bin/env python3
"""Focused opt-in History scroll regression using production list/row layout and synthetic data."""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=180).stdout.strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--history-source', type=Path)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('Identify an unresolved runtime concern before opting into a simulator check.')
    args.output.mkdir(parents=True, exist_ok=True)
    history = (args.history_source or ROOT / 'OathAtmosphere/Assets/OathChainActivityScreen.swift').read_text()
    layout = history[history.index('    private var activityContent: some View {'):history.index('        .background(Color(uiColor: OathSurfaceColors.groupedCanvas)')]
    layout += '    }\n'
    rows = history[history.index('struct OathActivityRows: View {'):history.index('/// Asset identity remains visible')]
    style = (ROOT / 'OathAtmosphere/Home/OathSettingsStyle.swift').read_text()
    style = style[style.index('struct OathSettingsRowButtonStyle: ButtonStyle {'):style.index('\nextension View {', style.index('struct OathSettingsRowButtonStyle: ButtonStyle {'))]
    # The destructive-only styling environment is irrelevant to transaction taps.
    style = style.replace('.environment(\\.oathDestructiveRow, true)', '')
    probe = (ROOT / 'Tools/HistoryScrollRegression/Probe.swift').read_text().replace('    // PRODUCTION_LIST', layout)
    device = None
    with tempfile.TemporaryDirectory(prefix='oath-history-scroll-') as directory:
        work = Path(directory)
        typography = (ROOT/'OathAtmosphere/Localization/OathTypography.swift').read_text().replace('import OathDiagnostics\n', '')
        direction = (ROOT/'OathAtmosphere/Localization/OathLanguageSettings.swift').read_text()
        direction = direction[direction.index('@MainActor enum OathLayoutDirection {'):direction.index('private struct OathLanguageEnvironmentKey:')]
        tabs = (ROOT/'OathAtmosphere/Home/OathHomeBottomSearch.swift').read_text()
        tabs = tabs[:tabs.index('/// Keep one search controller')]
        (work / 'Probe.swift').write_text(probe + '\n' + rows + '\n' + style + '\n' + typography + '\n' + direction + '\n' + tabs)
        spec = {
            'name': 'HistoryScrollProbe', 'options': {'deploymentTarget': {'iOS': '26.0'}},
            'settings': {'base': {'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0', 'GENERATE_INFOPLIST_FILE': 'YES'}},
            'targets': {
                'HistoryScrollProbe': {'type':'application', 'platform':'iOS',
                    'sources': [str(work/'Probe.swift'), str(ROOT/'OathAtmosphere/Shared/OathRefinedListRow.swift'), str(ROOT/'OathAtmosphere/Localization/OathStringKey.swift')],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER':'org.oathwallet.history-scroll-probe', 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES'}}},
                'ScrollUITests': {'type':'bundle.ui-testing', 'platform':'iOS', 'sources':[str(ROOT/'Tools/HistoryScrollRegression/ScrollUITests.swift')],
                    'dependencies':[{'target':'HistoryScrollProbe'}], 'settings': {'base':{'PRODUCT_BUNDLE_IDENTIFIER':'org.oathwallet.history-scroll-probe.tests'}}}},
            'schemes': {'HistoryScrollProbe': {'build':{'targets':{'HistoryScrollProbe':'all','ScrollUITests':['test']}}, 'test':{'targets':['ScrollUITests']}}}}
        (work/'project.yml').write_text(json.dumps(spec))
        run('xcodegen','generate','--spec',str(work/'project.yml'))
        try:
            device = run('xcrun','simctl','create','Oath History Check '+uuid.uuid4().hex[:8], 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max','com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            with (args.output/'test.log').open('w') as log:
                result = subprocess.run(['xcodebuild','-project',str(work/'HistoryScrollProbe.xcodeproj'),'-scheme','HistoryScrollProbe',
                    '-destination','platform=iOS Simulator,id='+device,'-derivedDataPath',str(work/'build'),
                    '-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-resultBundlePath',str(args.output/'Scroll.xcresult'),'test'],stdout=log,stderr=subprocess.STDOUT,timeout=600)
            result.check_returncode()
            print('PASS: native swipes reveal older transactions and scrolled rows open their receipts (synthetic History fixture).')
        finally:
            if device:
                subprocess.run(['xcrun','simctl','shutdown',device],capture_output=True,timeout=60)
                subprocess.run(['xcrun','simctl','delete',device],check=True,capture_output=True,timeout=60)
if __name__ == '__main__': main()
