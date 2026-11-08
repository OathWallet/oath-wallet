// Opt-in, disposable Sui testnet simulation fixture. Uses only free faucet funds.
// SDK: npm install --prefix /tmp/oath-sui-object-live-sdk --cache /tmp/oath-sui-object-npm-cache @mysten/sui@2.37.0 --ignore-scripts
// Run with --run. The generated file contains public unsigned test data only.
// No key is persisted, and this script never signs or submits a transaction.
import fs from 'node:fs';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
if (!process.argv.includes('--run')) {
 console.log('Pass --run to fund a fresh disposable testnet sender and build an unsigned simulation fixture.');
 process.exit(0);
}
const require = createRequire((process.env.OATH_SUI_SDK_ROOT || '/tmp/oath-sui-object-live-sdk') + '/package.json');
const load = p => import(require.resolve('@mysten/sui/' + p));
const { Ed25519Keypair } = await load('keypairs/ed25519');
const { SuiGrpcClient } = await load('grpc');
const { Transaction } = await load('transactions');
const { requestSuiFromFaucetV3, getFaucetHost } = await load('faucet');
const client = new SuiGrpcClient({ network:'testnet', baseUrl:'https://fullnode.testnet.sui.io:443' });
let stage = 'network';
try {
 assert.equal((await client.getChainIdentifier()).chainIdentifier, '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD');
 const sender = Ed25519Keypair.generate().toSuiAddress(), recipient = Ed25519Keypair.generate().toSuiAddress();
 stage = 'faucet';
 await requestSuiFromFaucetV3({host:getFaucetHost('testnet'),recipient:sender,timeout:60000});
 stage = 'build';
 const tx = new Transaction(); tx.setSender(sender); tx.setGasBudget(50000000);
 const [kiosk, cap] = tx.moveCall({target:'0x2::kiosk::new'});
 tx.transferObjects([cap], tx.pure.address(recipient));
 tx.moveCall({target:'0x2::transfer::public_share_object',arguments:[kiosk],typeArguments:['0x2::kiosk::Kiosk']});
 const bytes = await tx.build({client});
 fs.writeFileSync('/tmp/oath-sui-object-live-fixture.json',JSON.stringify({network:'testnet',sender,recipient,transaction:Buffer.from(bytes).toString('base64')}),{mode:0o600});
 console.log('PASS: fresh faucet-only testnet transaction prepared; no signing or submission');
} catch(error) { console.error('FAILED stage='+stage+' type='+error.constructor.name); process.exitCode=1; }
