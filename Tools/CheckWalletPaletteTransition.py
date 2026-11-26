#!/usr/bin/env python3
"""Opt-in focused simulator check of SwiftUI palette interpolation into Metal."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-check', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.simulator_check:
        parser.error('Requires a stated runtime concern and --simulator-check')
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    device = None
    recorder = None
    with tempfile.TemporaryDirectory(prefix='oath-palette-') as temporary:
        work = Path(temporary)
        sources = list((root / 'OathAtmosphere').glob('OathArtwork*.swift'))
        sources += [root / 'OathAtmosphere' / name for name in [
            'OathBackground.swift', 'OathColorway.swift', 'OathRenderer.swift',
            'OathLogoTexture.swift', 'OathCustomArtworkPoster.swift', 'OathOnboardingLayout.swift',
            'Shared/OathActionMetrics.swift']]
        for source in sources:
            text = source.read_text()
            if source.name == 'OathRenderer.swift':
                text = text.replace('let paletteChanged = silkColors != colors',
                    'PaletteProbe.record(colors, renderer: self)\n        let paletteChanged = silkColors != colors')
                text = text.replace('case .presented:', 'case .presented:\n                PaletteProbe.presented += 1')
            (work / source.name).write_text(text)
        shutil.copy(root / 'Tools/WalletPaletteTransition/Probe.swift', work / 'Probe.swift')
        shutil.copy(root / 'Shaders/OathSilk.metal', work / 'OathSilk.metal')
        shutil.copy(root / 'OathApp/Resources/OathGlassNormals.png', work / 'OathGlassNormals.png')
        for image in (root / 'OathApp/Resources/Startup').glob('*'):
            if image.suffix in ('.jpg', '.png') and not image.name.startswith('._'):
                shutil.copy(image, work / image.name)
        spec = {'name': 'PaletteProbe', 'options': {'deploymentTarget': {'iOS': '17.0'}},
            'packages': {'OathDiagnostics': {'path': str(root / 'Packages/OathDiagnostics')}},
            'targets': {'PaletteProbe': {'type': 'application', 'platform': 'iOS',
                'sources': ['.'], 'dependencies': [{'package': 'OathDiagnostics'}],
                'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.oathwallet.palette-probe',
                    'GENERATE_INFOPLIST_FILE': 'YES', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES',
                    'CODE_SIGNING_ALLOWED': 'NO', 'SWIFT_VERSION': '6.0', 'ARCHS': 'arm64'}}}}}
        (work / 'project.yml').write_text(json.dumps(spec))
        run('xcodegen', 'generate', '--spec', str(work / 'project.yml'))
        build = subprocess.run(['xcodebuild', '-project', str(work / 'PaletteProbe.xcodeproj'),
            '-scheme', 'PaletteProbe', '-destination', 'generic/platform=iOS Simulator',
            '-derivedDataPath', str(work / 'build'), 'CODE_SIGNING_ALLOWED=NO', 'build'],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
        (args.output / 'build.log').write_text(build.stdout)
        build.check_returncode()
        try:
            device = run('xcrun', 'simctl', 'create', 'Oath Palette ' + uuid.uuid4().hex[:8],
                'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max',
                'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            run('xcrun', 'simctl', 'boot', device)
            run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=180)
            run('xcrun', 'simctl', 'install', device,
                str(work / 'build/Build/Products/Debug-iphonesimulator/PaletteProbe.app'))
            recorder = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo',
                str(args.output / 'transition.mp4')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run('xcrun', 'simctl', 'launch', device, 'org.oathwallet.palette-probe')
            container = Path(run('xcrun', 'simctl', 'get_app_container', device, 'org.oathwallet.palette-probe', 'data'))
            result = container / 'Documents/result.json'
            deadline = time.monotonic() + 45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.25)
            metrics = json.loads(result.read_text())
            (args.output / 'result.json').write_text(json.dumps(metrics, indent=2))
            samples = metrics['samples']
            assert metrics['renderers'] == 1, 'Canvas recreated during wallet color switch'
            assert metrics['presented'] > 10, 'Real Metal frames did not present'
            unique = lambda stage: {tuple(round(v, 5) for v in color) for color in samples[stage]}
            assert len(unique('same')) == 1, 'Equivalent blue palette should not animate'
            assert len(unique('red')) > 5, 'Red palette snapped instead of interpolating'
            assert len(unique('retarget')) > 5, 'Rapid switch did not interpolate'
            distance = lambda a, b: sum((x-y)**2 for x,y in zip(a,b))**0.5
            assert distance(samples['red'][-1], samples['reduced'][-1]) < 0.0001
            assert distance(samples['retarget'][-1], samples['same'][-1]) < 0.0001
            assert distance(samples['green'][-1], samples['retarget'][0]) < 0.1, 'Retarget jumped'
            run('xcrun', 'simctl', 'terminate', device, 'org.oathwallet.palette-probe')
            result.unlink()
            run('xcrun', 'simctl', 'launch', device, 'org.oathwallet.palette-probe', '-oath-artwork-reduce-motion')
            deadline = time.monotonic() + 30
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.25)
            reduced = json.loads(result.read_text())
            (args.output / 'reduce-motion.json').write_text(json.dumps(reduced, indent=2))
            assert reduced['renderers'] == 1 and reduced['presented'] > 0
            for stage in ('red', 'green', 'retarget', 'reduced'):
                values = {tuple(round(v, 5) for v in color) for color in reduced['samples'][stage]}
                assert len(values) == 1, 'Reduce Motion should skip interpolation'
            print('PASS: real Metal frames, intermediate colors, same-color no-op, rapid retarget, Reduce Motion; one renderer')
        finally:
            if recorder:
                import signal
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=30)
            if device:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True, timeout=60)
                subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=60)


if __name__ == '__main__':
    main()
