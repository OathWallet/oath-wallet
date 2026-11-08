#!/usr/bin/env python3
"""Syntax-aware UI literal guard and optional whole-source audit inventory.

The guard covers direct UI labels, not arbitrary data-flow. Review the inventory
for model-generated prose too. Protocol fields, token/chain names, debug fixtures,
recovery-file formats and user/dApp text must not be translated as app copy.
"""
import argparse
import json
from pathlib import Path
import re
import platform
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
# Exact reviewed data literals, not blanket path exclusions.
invariants = {'Bitcoin', 'THORChain', 'OP_RETURN', ' XLM', ' XRP', ' wei', ' NEAR', ' SOL', ' SUI', ' TON', ' RUNE', ' TRX', 'eip155:'}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--inventory', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='oath-localization-source-') as folder:
    work = Path(folder)
    roots = [root/'OathApp', root/'OathAtmosphere', *sorted((root/'Packages').glob('*/Sources'))]
    files = sorted(str(p.relative_to(root)) for base in roots for p in base.rglob('*.swift') if not p.name.startswith('._') and '.build' not in p.parts and 'Private' not in p.parts)
    listing = work/'files.txt'; listing.write_text('\n'.join(files))
    swift = Path(subprocess.check_output(['xcrun','--find','swiftc'], text=True).strip())
    host = swift.parent.parent/'lib/swift/host'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run([str(swift), '-target', platform.machine() + '-apple-macosx14.0', '-sdk', sdk, '-I', str(host), '-L', str(host), '-lSwiftParser', '-lSwiftSyntax', '-Xlinker', '-rpath', '-Xlinker', str(host), str(root/'Tools/ScanLocalizationSource.swift'), '-o', str(work/'scan')], check=True)
    inventory = work/'inventory.json'
    subprocess.run([str(work/'scan'), str(root), str(listing), str(inventory)], check=True)
    records = json.loads(inventory.read_text())
    findings = []
    for item in records:
        if item['debugOnly'] or not item['directUI'] or item['text'] in invariants: continue
        # A literal used as a dictionary key or as the condition of a ternary
        # expression is not the text displayed by the surrounding Text call.
        # Those records remain in the inventory for manual data-flow review.
        if any(character.isalpha() for character in re.sub(r'\\[nrt0]', '', item['text'])):
            findings.append(item)
    if args.inventory:
        args.inventory.parent.mkdir(parents=True, exist_ok=True)
        args.inventory.write_bytes(inventory.read_bytes())
    for item in findings: print(f"{item['file']}:{item['line']}: review UI literal {item['text']!r}")
    raise SystemExit(1 if findings else 0)
