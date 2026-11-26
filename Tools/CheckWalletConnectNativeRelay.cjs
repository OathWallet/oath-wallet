/* Real JS dApp peer for OathWalletConnectLiveUITests. No funds are sent.
 * All signatures/URIs stay local; only fixed stages and verification booleans
 * enter the public report. The native peer uses an isolated public test vector. */
process.env.DISABLE_GLOBAL_CORE = 'true';
const fs = require('node:fs');
const {randomUUID} = require('node:crypto');
const {SignClient} = require('@walletconnect/sign-client');
const {Wallet, verifyMessage, verifyTypedData, hexlify, toUtf8Bytes} = require('ethers');
for (const method of ['log','info','warn','error','debug']) console[method] = () => {};
const matrix = JSON.parse(process.env.OATH_WC_EVM_MATRIX || '[]');
const chains = matrix.length ? matrix.map(row => 'eip155:' + row.chainID) : ['eip155:1','eip155:42161'];
const report = {layer:'Real native iOS wallet and JS dApp over WalletConnect relay; isolated public test vector; no funds sent', checks: [], stage: 'initializing'};
const reportPath = '/tmp/oath-wc-native-relay-public.json';
const save = stage => { report.stage = stage; fs.writeFileSync(reportPath, JSON.stringify(report, null, 2), {mode:0o600}); };
const pass = name => { report.checks.push({name, passed:true}); save(name); };
const timeout = setTimeout(() => { save('timeout'); process.stdout.write('Native relay check timed out.\n'); process.exit(1); }, matrix.length ? 1200000 : 600000);
function memory() {
  const values = new Map();
  return {getKeys:async()=>[...values.keys()],getEntries:async()=>[...values.entries()],getItem:async k=>values.get(k),setItem:async(k,v)=>{values.set(k,v);},removeItem:async k=>{values.delete(k);}};
}
(async()=>{
  const dapp = await SignClient.init({projectId:process.env.OATH_WC_PROJECT_ID,
    metadata:{name:'Oath Review Lab',description:'Isolated native WalletConnect validation',url:'https://oathwallet.org',icons:['https://oathwallet.org/wallet-logo.png']},
    customStoragePrefix:'oath-native-peer-'+randomUUID(),logger:'silent',storage:memory()});
  const {uri,approval} = await dapp.connect({requiredNamespaces:{eip155:{chains,methods:['personal_sign','eth_signTypedData_v4','wallet_switchEthereumChain','eth_accounts','eth_chainId'],events:['accountsChanged','chainChanged']}}});
  fs.writeFileSync(process.env.OATH_WC_FIXTURE_PATH, JSON.stringify({uri}), {mode:0o600});
  save('waiting-native-approval');
  const session = await approval();
  const address = new Wallet('0x'+'01'.repeat(32)).address;
  if (!session.namespaces.eip155.accounts.some(a=>a.endsWith(address))) throw Error('account');
  pass('native-session-approved');
  let chain='eip155:1';
  const request = (method,params) => dapp.request({topic:session.topic,chainId:chain,request:{method,params}});
  // Do not wait for the native Connected page to close before authenticating.
  const [accounts, chainID] = await Promise.all([request('eth_accounts', []), request('eth_chainId', [])]);
  if (!accounts.some(a => a.toLowerCase() === address.toLowerCase()) || chainID !== '0x1') throw Error('discovery');
  pass('native-post-connect-discovery');
  if (matrix.length) {
    if (matrix.length !== 30) throw Error('Update native UI matrix count');
    for (const row of matrix) {
      chain='eip155:'+row.chainID;
      if (!session.namespaces.eip155.accounts.includes(chain+':'+address)) throw Error('matrix account');
      const accounts=await request('eth_accounts',[]), chainID=await request('eth_chainId',[]);
      if (!accounts.some(a=>a.toLowerCase()===address.toLowerCase()) || chainID!=='0x'+row.chainID.toString(16)) throw Error('matrix discovery');
      save('waiting-'+row.name);
      const message='Oath isolated connection test: '+chain;
      if (verifyMessage(message,await request('personal_sign',[hexlify(toUtf8Bytes(message)),address]))!==address) throw Error('matrix signature');
      report.checks.push({name:row.name,chain,connection:true,accountDiscovery:true,signatureIndependentlyVerified:true,transaction:'NOT TESTED'}); save('verified-'+row.name);
    }
    chain='eip155:1';
  } else {
  const message='Oath native WalletConnect validation';
  save('waiting-message');
  if (verifyMessage(message,await request('personal_sign',[hexlify(toUtf8Bytes(message)),address]))!==address) throw Error('message');
  pass('native-personal-sign-verified');
  const domain={name:'Oath Review Lab',version:'1',chainId:1,verifyingContract:'0x0000000000000000000000000000000000000001'};
  const domainTypes=[{name:'name',type:'string'},{name:'version',type:'string'},{name:'chainId',type:'uint256'},{name:'verifyingContract',type:'address'}];
  const types={Note:[{name:'contents',type:'string'},{name:'owner',type:'address'}]};
  const value={contents:'Public native test',owner:address};
  save('waiting-typed');
  let signature=await request('eth_signTypedData_v4',[address,JSON.stringify({domain,types:{EIP712Domain:domainTypes,...types},primaryType:'Note',message:value})]);
  if (verifyTypedData(domain,types,value,signature)!==address) throw Error('typed');
  pass('native-typed-data-verified');
  const signin=`oathwallet.org wants you to sign in with your Ethereum account:\n${address}\n\nSign in to the isolated Oath test.\n\nURI: https://oathwallet.org\nVersion: 1\nChain ID: 1\nNonce: Test12345678\nIssued At: ${new Date().toISOString()}`;
  save('waiting-signin');
  if (verifyMessage(signin,await request('personal_sign',[hexlify(toUtf8Bytes(signin)),address]))!==address) throw Error('signin');
  pass('native-siwe-verified');
  const permitTypes={Permit:[{name:'owner',type:'address'},{name:'spender',type:'address'},{name:'value',type:'uint256'},{name:'nonce',type:'uint256'},{name:'deadline',type:'uint256'}]};
  const permit={owner:address,spender:'0x0000000000000000000000000000000000000002',value:'0',nonce:'0',deadline:String(Math.floor(Date.now()/1000)+600)};
  save('waiting-permit');
  signature=await request('eth_signTypedData_v4',[address,JSON.stringify({domain,types:{EIP712Domain:domainTypes,...permitTypes},primaryType:'Permit',message:permit})]);
  if (verifyTypedData(domain,permitTypes,permit,signature)!==address) throw Error('permit');
  pass('native-permit-verified');
  }
  save('waiting-switch');
  const switched=await request('wallet_switchEthereumChain',[{chainId:'0xa4b1'}]);
  if (switched!==null) throw Error('switch');
  chain='eip155:42161';
  if (await request('eth_chainId',[])!=='0xa4b1') throw Error('chain');
  pass('native-network-switch-verified');
  save('waiting-rejection');
  let rejected=false;
  try { await request('personal_sign',[hexlify(toUtf8Bytes('Reject this native test')),address]); }
  catch(error) { rejected=error.code===4001; }
  if (!rejected) throw Error('rejection');
  pass('native-user-rejection-verified');
  save('waiting-disconnect');
  await new Promise(resolve=>dapp.once('session_delete',resolve));
  if (dapp.session.getAll().some(s=>s.topic===session.topic)) throw Error('disconnect');
  pass('native-disconnect-verified');
  clearTimeout(timeout); save('passed'); process.stdout.write('PASS: native relay consent, independent signatures, network switch, rejection and disconnect.\n'); process.exit(0);
})().catch(error=>{clearTimeout(timeout);report.failedStage=report.stage;if(Number.isSafeInteger(error.code))report.errorCode=error.code;save('failed');process.stdout.write('FAIL: native relay; see fixed-stage public report.\n');process.exit(1);});
