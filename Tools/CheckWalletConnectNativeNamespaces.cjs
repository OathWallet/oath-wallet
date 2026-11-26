/* Native consent/account mapping for every enabled non-EVM family. No signing
 * or transactions are implied by this check; the separate Swift bridge tests
 * independently verify those protocol paths. Uses an isolated public vector. */
process.env.DISABLE_GLOBAL_CORE = 'true';
const fs = require('node:fs'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const {SignClient} = require('@walletconnect/sign-client');
for (const name of ['log','info','warn','error','debug']) console[name] = () => {};
const rows = [
  ['bitcoin', 'bip122:00000008819873e925422c1ff0f99f7c', ['getAccountAddresses','signMessage'], ['bip122_addressesChanged']],
  ['solana', 'solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1', ['solana_getAccounts','solana_signMessage'], ['accountsChanged','chainChanged']],
  ['ton', 'ton:-3', ['ton_signData'], []],
  ['polkadot', 'polkadot:d6eec26135305a8ad257a20d00335728', ['polkadot_signMessage'], []],
  ['tron', 'tron:0xcd8690dc', ['tron_signMessage'], []],
  ['sui', 'sui:testnet', ['sui_getAccounts','sui_signPersonalMessage'], []],
  ['near', 'near:testnet', ['near_getAccounts','near_signTransaction'], []],
  ['stellar', 'stellar:testnet', ['stellar_signXDR'], []],
  ['xrpl', 'xrpl:1', ['xrpl_signTransaction'], []],
  ['thorchain', 'cosmos:thorchain', ['cosmos_getAccounts','cosmos_signAmino'], []],
];
for (const [,chain] of rows) assert(/^[-a-z0-9]{3,8}:[-a-zA-Z0-9_]{1,32}$/.test(chain), 'Invalid fixture CAIP-2 identifier');
const report = {layer:'Real native iOS wallet and JS dApp over WalletConnect relay; public BIP-39 vector; no funds sent', checks:[], stage:'initializing'};
const save = stage => { report.stage=stage; fs.writeFileSync('/tmp/oath-wc-native-relay-public.json',JSON.stringify(report,null,2),{mode:0o600}); };
const timer=setTimeout(()=>{save('timeout');process.exit(1)},300000);
const memory=()=>{const m=new Map();return {getKeys:async()=>[...m.keys()],getEntries:async()=>[...m.entries()],getItem:async k=>m.get(k),setItem:async(k,v)=>{m.set(k,v)},removeItem:async k=>{m.delete(k)}}};
(async()=>{
  const peer=await SignClient.init({projectId:process.env.OATH_WC_PROJECT_ID,logger:'silent',storage:memory(),customStoragePrefix:crypto.randomUUID(),
    metadata:{name:'Oath Review Lab',description:'Native multi-network consent validation',url:'https://oathwallet.org',icons:[]}});
  const requiredNamespaces=Object.fromEntries(rows.map(([,chain,methods,events])=>[chain.split(':')[0],{chains:[chain],methods,events}]));
  const {uri,approval}=await peer.connect({requiredNamespaces});
  fs.writeFileSync(process.env.OATH_WC_FIXTURE_PATH,JSON.stringify({uri}),{mode:0o600});save('waiting-native-approval');
  const session=await approval();
  for(const [name,chain,methods] of rows){
    const namespace=session.namespaces[chain.split(':')[0]];
    assert(namespace && namespace.accounts.some(a=>a.startsWith(chain+':') && a.length>chain.length+1));
    assert(methods.every(method=>namespace.methods.includes(method)));
    report.checks.push({name,chain,nativeConnection:true,nativeAccountMapping:true,nativeSignature:'NOT TESTED',transaction:'NOT TESTED'});
  }
  assert.equal(session.sessionProperties.tron_method_version,'v1');
  assert.equal(typeof session.sessionProperties.ton_getPublicKey,'string');
  assert(JSON.parse(session.sessionProperties.bip122_getAccountAddresses).length>0);
  save('waiting-native-disconnect');
  await new Promise(resolve=>peer.once('session_delete',resolve));
  assert(!peer.session.getAll().some(s=>s.topic===session.topic));
  report.disconnect=true;save('passed');clearTimeout(timer);
  process.stdout.write('PASS native consent, account mapping and disconnect for all 10 non-EVM families.\n');process.exit(0);
})().catch(error=>{clearTimeout(timer);report.failedStage=report.stage;if(Number.isSafeInteger(error.code))report.errorCode=error.code;save('failed');process.stdout.write('FAIL native namespace validation; see fixed-stage public report.\n');process.exit(1)});
