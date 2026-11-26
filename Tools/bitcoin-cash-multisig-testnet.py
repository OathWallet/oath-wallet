#!/usr/bin/env python3
"""Disposable BCH multisig chipnet transport; no keys are read.
Uses verified TLS and a post-fork BCHN checkpoint to distinguish chipnet.
Usage: python3 Tools/bitcoin-cash-multisig-testnet.py /tmp/oath-bch-multisig-public fetch|broadcast|observe|verify
"""
import hashlib
import json
import socket
import ssl
import sys
from pathlib import Path

root = Path(sys.argv[1])
mode = sys.argv[2]
assert mode in ('fetch', 'broadcast', 'observe', 'verify')
peers = [('chipnet.imaginary.cash', 50002), ('chipnet.c3-soft.com', 64002)]
def connect(host, port):
    return ssl.create_default_context().wrap_socket(socket.create_connection((host, port), timeout=8), server_hostname=host)

verified_peers = 0
for host, port in peers:
    try:
        with connect(host, port) as connection:
            connection.settimeout(20)
            stream = connection.makefile('rwb')
            request_id = 0
            def rpc(method, params):
                global request_id
                request_id += 1
                stream.write((json.dumps({'id': request_id, 'method': method, 'params': params}) + '\n').encode())
                stream.flush()
                while True:
                    reply = json.loads(stream.readline())
                    if reply.get('id') == request_id:
                        break
                if reply.get('error'):
                    # Public test data only; no key or user-wallet data enters
                    # this tool. Keep provider rejection reasons diagnosable.
                    reason = str(reply['error'].get('message', '')).split('\n[')[0][:250]
                    raise RuntimeError(method + ': ' + str(reply['error'].get('code', 'error')) + ' ' + reason)
                return reply['result']
            rpc('server.version', ['Oath isolated BCH chipnet send test', '1.5'])
            header = bytes.fromhex(rpc('blockchain.block.header', [121957]))
            assert hashlib.sha256(hashlib.sha256(header).digest()).digest()[::-1].hex() == '0000000056087dee73fb66178ca70da89dfd0be098b1a63cf6fe93934cd04c78'
            if mode == 'fetch':
                public = json.loads((root / 'public.json').read_text())
                addresses = public.get('addresses', [public])
                rows = []
                for address in addresses:
                    for utxo in rpc('blockchain.scripthash.listunspent', [address['scriptHash'], 'exclude_tokens']):
                        rows.append(dict(utxo, raw=rpc('blockchain.transaction.get', [utxo['tx_hash']]),
                                         change=address.get('change', 0), index=address.get('index', 0), type=address.get('type', 44)))
                if not rows:
                    raise RuntimeError('No outputs visible on this peer')
                (root / 'utxos.json').write_text(json.dumps(rows))
                print('BCH chipnet funding verified:', len(rows), 'outputs,', sum(row['value'] for row in rows), 'satoshis')
            elif mode == 'broadcast':
                signed = json.loads((root / 'signed.json').read_text())
                assert signed['network'] == 'chipnet'
                # Repeating this command rebroadcasts only identical bytes.
                txid = rpc('blockchain.transaction.broadcast', [signed['raw']])
                assert txid == signed['txid']
                assert rpc('blockchain.transaction.get', [txid]) == signed['raw']
                path = root / 'receipts.json'
                receipts = json.loads(path.read_text()) if path.exists() else []
                if not any(item['txid'] == txid for item in receipts):
                    receipts.append({'network':'BCH chipnet','peer':host,'txid':txid,'inputs':signed['inputs'],
                                     'fee':signed['fee'],'byteIdentical':True,'step':signed['step']})
                path.write_text(json.dumps(receipts, indent=2))
                (root / ('transaction-' + txid + '.json')).write_text(json.dumps(signed))
                (root / 'public.json').write_text(json.dumps({'addresses':signed['nextAddresses'],'step':signed['step']+1}))
                print('BCH chipnet transfer accepted and retrieved byte-for-byte:', txid)
            else:
                receipts = json.loads((root / 'receipts.json').read_text())
                for receipt in receipts:
                    txid = receipt['txid']
                    signed = json.loads((root / ('transaction-' + txid + '.json')).read_text())
                    assert rpc('blockchain.transaction.get', [txid]) == signed['raw']
                    history = rpc('blockchain.scripthash.get_history', [signed['nextAddresses'][0]['scriptHash']])
                    height = next(item['height'] for item in history if item['tx_hash'] == txid)
                    if mode == 'verify':
                        assert height > 0, 'Public transfer is still unconfirmed'
                    evidence = {'height': height, 'merkleProof': False, 'byteIdentical': True}
                    if height > 0:
                        proof = rpc('blockchain.transaction.get_merkle', [txid, height])
                        header = bytes.fromhex(rpc('blockchain.block.header', [height]))
                        node, position = bytes.fromhex(txid)[::-1], proof['pos']
                        for item in proof['merkle']:
                            sibling = bytes.fromhex(item)[::-1]
                            pair = sibling + node if position & 1 else node + sibling
                            node = hashlib.sha256(hashlib.sha256(pair).digest()).digest()
                            position >>= 1
                        assert position == 0 and header[36:68] == node
                        evidence['merkleProof'] = True
                    field = 'verified' if mode == 'verify' else 'observed'
                    receipt.setdefault(field, {})[host] = evidence
                    # Multisig fixture sends the entire balance through six policies.
                    # Verify each spent policy is empty and the final one received
                    # exactly the reviewed amount, independently on every peer.
                    if 'received' in signed:
                        balance = rpc('blockchain.scripthash.get_balance', [signed['nextAddresses'][0]['scriptHash']])
                        total = balance['confirmed'] + balance['unconfirmed']
                        expected = signed['received'] if receipt is receipts[-1] else 0
                        assert total == expected, 'Multisig final balance mismatch'
                        if receipt is not receipts[-1]:
                            following = receipts[receipts.index(receipt) + 1]['txid']
                            assert any(item['tx_hash'] == following for item in history), 'Missing outgoing history'
                        receipt[field][host]['balanceAfterSequence'] = total
                (root / 'receipts.json').write_text(json.dumps(receipts, indent=2))
                verified_peers += 1
                print('Confirmed' if mode == 'verify' else 'Observed', 'all', len(receipts), 'BCH chipnet sends, balances and history on', host)
            if mode not in ('verify', 'observe'):
                break
    except Exception as error:
        print('Peer unavailable:', host, type(error).__name__)
        if isinstance(error, (RuntimeError, AssertionError)):
            print(str(error))
else:
    if mode not in ('verify', 'observe') or verified_peers != len(peers):
        raise SystemExit('Not all required BCH chipnet peer checks completed')
