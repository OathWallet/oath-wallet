#!/usr/bin/env python3
"""Prepare a bundled index from a previously downloaded public CoinGecko directory.

No credentials or network access. Production Swift codecs validate identities.
The original bundle is replaced atomically only after successful preparation.
"""
import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('input', type=Path, help='Successful coins/list?include_platform=true JSON response')
parser.add_argument('--networks', nargs='+', help='Refresh only these networks, preserving other bundled entries')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = root / 'Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json'
with tempfile.TemporaryDirectory(prefix='oath-discovery-prepare-') as directory:
    work = Path(directory)
    (work / 'Sources/Prepare').mkdir(parents=True)
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "Prepare", platforms: [.macOS("15.5")],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "Prepare", dependencies: ["OathAnkr"])])
''' % json.dumps(str(root / 'Packages/OathAnkr')))
    (work / 'Sources/Prepare/main.swift').write_text('''import Foundation
import OathAnkr
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let data = try Data(contentsOf: input)
let entries = try TokenDiscoveryCatalog.decode(data)
let requested = Set(CommandLine.arguments.dropFirst(3))
let coverage = Set(entries.map(\\.network))
guard requested.isEmpty ? coverage == Set(TokenDiscoveryNetworks.platforms.keys)
    : requested.isSubset(of: coverage) && requested.isSubset(of: Set(TokenDiscoveryNetworks.platforms.keys)) else {
    fatalError("Incomplete supported-network coverage; bundle unchanged")
}
try TokenDiscoveryCatalog.prepareSnapshot(data).write(to: output, options: .atomic)
print("Prepared \\(entries.count) canonical public token identities across \\(Set(entries.map(\\.network)).count) networks")
''')
    prepared = work / 'prepared.json'
    subprocess.run(['swift', 'run', '--package-path', str(work), '--scratch-path',
        '/tmp/oath-discovery-preparer', 'Prepare', str(args.input.resolve()), str(prepared), *(args.networks or [])], check=True)
    if args.networks:
        selected = set(args.networks)
        previous = json.loads(output.read_text())['entries']
        old = {(r['network'], r['reference']): r for r in previous}
        entries = [r for r in previous if r['network'] not in selected]
        incoming = [r for r in json.loads(prepared.read_text())['entries'] if r['network'] in selected]
        for row in incoming:
            cached = old.get((row['network'], row['reference']), {})
            if cached.get('coinID') == row['coinID']:
                for field in ('decimals', 'logo'):
                    if row.get(field) is None and cached.get(field) is not None:
                        row[field] = cached[field]
        present = {(r['network'], r['reference']) for r in incoming}
        # Official Asset Hub issuer registrations also supply entries absent
        # from CoinGecko's directory. Never merge unrelated stale listings.
        incoming += [r for r in previous if r['network'] == 'polkadot' and 'polkadot' in selected
                     and r['reference'] in ('assets:1337', 'assets:1984')
                     and (r['network'], r['reference']) not in present]
        entries += incoming
        prepared.write_text(json.dumps({'format': 1, 'entries': sorted(entries, key=lambda r: (r['network'], r['reference']))}, separators=(',', ':')))
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as file:
        file.write(prepared.read_bytes())
        pending = file.name
    os.replace(pending, output)
