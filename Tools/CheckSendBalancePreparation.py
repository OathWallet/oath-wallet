#!/usr/bin/env python3
"""Executable coverage of the production enabled-chain enum and Send paths.
Host tests with controlled transports only. Never launches an app or simulator.
Live preparation/unsigned quotes are a separate, explicitly opt-in command.
"""
from pathlib import Path
import argparse, json, os, re, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--matrix-only', action='store_true')
args = parser.parse_args()
matrix = json.loads((root/'Tools/SendPreparationCoverage.json').read_text())
with tempfile.TemporaryDirectory(prefix='oath-send-matrix-') as folder:
    work = Path(folder)
    source = work/'main.swift'
    source.write_text('import Foundation\nprint(String(decoding:try JSONEncoder().encode(OathImportChain.enabledCases.map(\\.rawValue)),as:UTF8.self))\n')
    inputs = ['Import/OathImportCatalog.swift', 'Localization/OathLocalization.swift',
              'Localization/OathLanguageCatalog.swift', 'Localization/OathStringKey.swift']
    subprocess.run(['swiftc', *[str(root/'OathAtmosphere'/s) for s in inputs], str(source), '-o', str(work/'chains')], check=True)
    chains = json.loads(subprocess.check_output([str(work/'chains')]))
assert set(matrix) == set(chains), f'Coverage differs from enabled enum: {set(matrix)^set(chains)}'
assert len(chains) == 42 and 'cronos' not in chains
for chain, entry in matrix.items():
    suite, method = entry['test'].split('.')
    text = (root/'Packages'/entry['package']/'Tests'/f"{entry['package']}Tests"/f'{suite}.swift').read_text()
    assert re.search(r'class\s+'+suite+r'\b',text) and 'func '+method+'(' in text, chain
print(f'PASS: exact enabled-chain enumeration and executable test references ({len(chains)} chains)',flush=True)
if args.matrix_only: raise SystemExit(0)
env = {k:v for k,v in os.environ.items() if not k.startswith('OATH_')}
for package in ['OathAnkr','OathDatabase','OathBitcoin']:
    filters = {v['test'] for v in matrix.values() if v['package']==package}
    if package == 'OathAnkr':
        filters |= {'SendBalancePreparationTests','SendReviewAmountsTests','SendEarlyEVMTests','SendEarlyEVMMultisigTests',
                    'EVMSendPreparationTests','EVMSendPendingTests','SolanaSendRPCRegressionTests',
                    'SuiSendTransportTests','XrplSendPreparationTests','StellarSendBoundaryTests',
                    'AptosSendTests','NearSendBoundaryTests','ThorchainSendTests','TronSendBoundaryTests',
                    'TonSendTests','PolkadotSendTests','EVMMultisigTests','XrplMultisigTests',
                    'StellarMultisigTests','SolanaMultisigPayerTests','AptosMultisigTests',
                    'TonMultisigTests','SuiMultisigTests','TronMultisigTests','ThorchainMultisigTests','NearMultisigBoundaryTests'}
    elif package == 'OathDatabase':
        filters |= {'BitcoinLedgerTests','BitcoinSendSettlementTests'}
    else:
        filters |= {'BitcoinSendTests','BitcoinCashSendTests','LitecoinSendTests','DogecoinSendTests',
                    'BitcoinMultisigTests','BitcoinCashMultisigTests','LitecoinMultisigTests','DogecoinMultisigTests',
                    'BitcoinSendOptionsTests','DiscoveryTests','UTXOFeeProviderTests','BitcoinFeeFallbackTests','AnkrUTXOFeeTests'}
    command = ['swift','test','--build-system','native','-j','4','--scratch-path',str(Path(tempfile.gettempdir())/('oath-feature-nov09-'+package.removeprefix('Oath').lower())),'--package-path',str(root/'Packages'/package)]
    # Diagnostics is deliberately configured once per process. Recorder suites
    # must run in separate processes; never weaken the production singleton.
    isolated = {
        'OathAnkr': ['ThorchainSendTests','XrplSendPreparationTests','EVMSendPreparationTests','SendQuoteExpiryTests','SendFeeFundingTests'],
        'OathBitcoin': ['UTXOFeeProviderTests.testPreferredFailoverPreservesAvailabilityAndInvalidQuoteDiagnostics'],
    }.get(package, [])
    subprocess.run(command + ['--filter','|'.join(sorted(filters)), *(['--skip','|'.join(isolated)] if isolated else [])],check=True,env=env,cwd=root)
    for suite in isolated:
        suite_env = dict(env)
        if suite == 'EVMSendPreparationTests': suite_env['OATH_EVM_PREPARATION_DIAGNOSTICS_TEST'] = '1'
        if suite == 'XrplSendPreparationTests': suite_env['OATH_XRPL_PREPARATION_DIAGNOSTICS_TEST'] = '1'
        if suite == 'SendQuoteExpiryTests': suite_env['OATH_QUOTE_EXPIRY_DIAGNOSTICS_TEST'] = '1'
        if suite == 'SendFeeFundingTests': suite_env['OATH_FEE_VALIDATION_DIAGNOSTICS_TEST'] = '1'
        subprocess.run(command + ['--filter',suite],check=True,env=suite_env,cwd=root)
print('PASS: selected controlled preparation, quote, reservation and authorization regressions')
