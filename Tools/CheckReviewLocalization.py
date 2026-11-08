#!/usr/bin/env python3
"""Host tests of the production transaction presenter, decoder and all 57 catalogs.
Temporary resources and synthetic public transactions only; no network/device use.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch-path', type=Path,
                    help='Optional dedicated build cache. Concurrent runs must use different paths.')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='oath-review-localization-') as directory:
    work = Path(directory)
    source = work/'Sources/ReviewCore'; source.mkdir(parents=True)
    for name in ['Scanner/OathWalletConnectReviewLocalization.swift', 'Send/OathSendAmount.swift',
                 'Localization/OathLocalization.swift', 'Localization/OathLanguageCatalog.swift',
                 'Localization/OathStringKey.swift']:
        shutil.copyfile(root/'OathAtmosphere'/name, source/Path(name).name)
    tests = work/'Tests/ReviewTests'; tests.mkdir(parents=True)
    shutil.copyfile(root/'Tools/ReviewLocalizationValidation/ReviewTests.swift', tests/'ReviewTests.swift')
    bundle = work/'Translations.bundle'; bundle.mkdir()
    (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.oath.reviewtests','CFBundleDevelopmentRegion':'en'}))
    catalog = json.loads((root/'OathApp/Resources/Localizable.xcstrings').read_text())['strings']
    for language in json.loads((root/'Design/Localization/languages.json').read_text()):
        code = language['code']; target = bundle/(code+'.lproj'); target.mkdir()
        values = {key:entry['localizations'][code]['stringUnit']['value'] for key,entry in catalog.items() if code in entry.get('localizations', {})}
        (target/'Localizable.strings').write_bytes(plistlib.dumps(values))
    (work/'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ReviewCore", platforms: [.macOS(.v14)],
 dependencies: [.package(path: %s)], targets: [
 .target(name: "ReviewCore", dependencies: ["OathAnkr"]),
 .testTarget(name: "ReviewTests", dependencies: ["ReviewCore", "OathAnkr"])])
''' % json.dumps(str(root/'Packages/OathAnkr')))
    env = os.environ.copy(); env['OATH_REVIEW_TRANSLATIONS'] = str(bundle)
    subprocess.run(['swift','test','--package-path',str(work),'--scratch-path',str(args.scratch_path or work/'Build')], env=env, check=True)
