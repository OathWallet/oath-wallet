#!/usr/bin/env python3
"""Host tests compile production URL policy and bookmarks. No simulator or wallet."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='oath-browser-host-') as directory:
    work = Path(directory)
    source = work/'Sources/BrowserCore'; source.mkdir(parents=True)
    for name in ['OathBrowserPolicy.swift', 'OathBrowserBookmarks.swift', 'OathBrowserTabs.swift']:
        shutil.copyfile(root/'OathAtmosphere/Browser'/name, source/name)
    tests = work/'Tests/BrowserTests'; tests.mkdir(parents=True)
    shutil.copyfile(root/'Tools/BrowserValidation/BrowserTests.swift', tests/'BrowserTests.swift')
    (work/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BrowserCore", platforms: [.macOS(.v14)],
 dependencies: [.package(path: ''' + json.dumps(str(root/'Packages/OathDiagnostics')) + ''')],
 targets: [.target(name: "BrowserCore", dependencies: ["OathDiagnostics"]),
 .testTarget(name: "BrowserTests", dependencies: ["BrowserCore"])])
''')
    subprocess.run(['swift', 'test', '--package-path', str(work), '--scratch-path', '/tmp/oath-browser-host-build'], check=True, timeout=180)
