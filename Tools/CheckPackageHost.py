#!/usr/bin/env python3
"""Run package tests on the Mac, isolating process-wide diagnostics configuration.

No simulator, device, or opt-in live-test flags are enabled. Tests with a custom
recorder run in fresh processes because production configuration is one-shot.
This also separates shared transport caches used by their related test suites.
Logs and JSON results stay in the supplied scratch directory.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time


def recorder_suites(package):
    suites = set()
    for source in sorted((package / 'Tests').rglob('*.swift')):
        if source.name.startswith('._'):
            continue
        text = source.read_text()
        if 'OathDiagnostics.configure(' in text:
            suites.update(re.findall(r'\bclass\s+(\w+)\s*:\s*[^\n{]*\bXCTestCase\b', text))
    return sorted(suites)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', choices=['OathAnkr', 'OathDatabase', 'OathMarketData', 'OathBitcoin'])
    parser.add_argument('--scratch', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    package = root / 'Packages' / args.package
    scratch = (args.scratch or Path(tempfile.gettempdir()) / 'oath-package-host' / args.package).resolve()
    reports = scratch / 'validation-results'
    reports.mkdir(parents=True, exist_ok=True)
    suites = recorder_suites(package)
    command = ['swift', 'test', '--package-path', str(package), '--scratch-path', str(scratch), '--build-system', 'native']
    results = []

    def run(name, arguments):
        started = time.monotonic()
        log = reports / (name + '.log')
        with log.open('w') as output:
            completed = subprocess.run(arguments, cwd=root, stdout=output, stderr=subprocess.STDOUT)
        summaries = re.findall(r'Executed \d+ tests?[^\n]*', log.read_text(errors='replace'))
        row = dict(suite=name, exit=completed.returncode,
                   summary=summaries[-1] if summaries else None,
                   seconds=round(time.monotonic() - started, 2))
        results.append(row)
        (reports / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f"{'PASS' if completed.returncode == 0 else 'FAIL'} {name}: {row['summary'] or 'see ' + str(log)}", flush=True)
        return completed.returncode

    skip = ['--skip', '|'.join(re.escape(suite) + r'[/.]' for suite in suites)] if suites else []
    run('core', command + skip)
    if 'Build complete!' not in (reports / 'core.log').read_text(errors='replace'):
        return 1
    for suite in suites:
        run(suite, command + ['--skip-build', '--filter', re.escape(suite) + r'[/.]'])
    return int(any(row['exit'] for row in results))


if __name__ == '__main__':
    raise SystemExit(main())
