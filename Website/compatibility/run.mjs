// Runs only repository-owned public fixtures. No recovery input, network calls,
// simulator launch or transaction broadcast. Package resolution may use network.
import {readFile,writeFile,mkdir,access} from 'node:fs/promises';
import {execFileSync,spawnSync} from 'node:child_process';
import {resolve,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const [sourceArg,outputArg,packageArg]=process.argv.slice(2);
if(!sourceArg||!outputArg)throw Error('Usage: node Website/compatibility/run.mjs <released-checkout> <new-output-directory> [wallet-core-package-directory]');
const source=resolve(sourceArg),output=resolve(outputArg),root=fileURLToPath(new URL('../../',import.meta.url));
const revision='d039b009d8c81b0497f2ac7e6abebfdf54ff8612';
if(execFileSync('git',['rev-parse','HEAD'],{cwd:source,encoding:'utf8'}).trim()!==revision)throw Error('Use the pinned Oath 5.0.2 source revision.');
execFileSync('git',['diff','--exit-code','HEAD','--'],{cwd:source,stdio:'pipe'});
try{await access(join(output,'results.json'));throw Error('Choose a new output directory; existing results must not be replaced.');}catch(e){if(e.code!=='ENOENT')throw e;}
await mkdir(output,{recursive:true});
const packageDir=packageArg?resolve(packageArg):fileURLToPath(new URL('node_modules/@trustwallet/wallet-core',import.meta.url));
const referenceFile=join(output,'reference.json');
execFileSync(process.execPath,[join(root,'Website/scripts/verify-migration-compatibility.mjs'),source,packageDir,referenceFile],{stdio:'pipe'});
const reference=JSON.parse(await readFile(referenceFile,'utf8'));
const startedAt=new Date().toISOString();
if(process.platform!=='darwin')throw Error('OathBitcoin host tests require macOS. Reference output was saved; do not label the host tests passed.');
const filter='BitcoinKeysTests|ElectrumMnemonicTests';
const testEnvironment={...process.env}; delete testEnvironment.OATH_ELECTRUM_REGTEST_DIR;
const run=spawnSync('swift',['test','--package-path','Packages/OathBitcoin','--filter',filter],{cwd:source,encoding:'utf8',timeout:900000,maxBuffer:16*1024*1024,env:testEnvironment});
// The funded integration test remains opt-in and is excluded from this runner.
if(run.error)throw Error('Host test process failed: '+run.error.code);
const log=run.stdout+run.stderr;
await writeFile(join(output,'host-tests.log'),log);
if(run.status!==0)throw Error('Host tests did not pass. Review the local log; no successful report was created.');
const cases=[...log.matchAll(/Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|skipped) \(([0-9.]+) seconds\)/g)].map(([,suite,name,status,seconds])=>({id:suite.split('.').at(-1)+'.'+name,status,seconds:Number(seconds)}));
if(cases.length!==15||cases.filter(c=>c.status==='skipped').length!==1)throw Error('Unexpected test inventory; review instead of silently accepting a changed suite.');
const sources=[...reference.sources];
for(const path of ['Packages/OathBitcoin/Tests/OathBitcoinTests/BitcoinKeysTests.swift','Packages/OathBitcoin/Package.swift','Packages/OathBitcoin/Package.resolved'])sources.push({path,sha256:createHash('sha256').update(await readFile(join(source,path))).digest('hex')});
const versions={oath:'5.0.2',build:104,sourceCommit:revision,walletCore:'4.8.4',bitcoinDevKit:'3.1.1',swift:execFileSync('swift',['--version'],{encoding:'utf8'}).split('\n')[0],macOS:execFileSync('sw_vers',['-productVersion'],{encoding:'utf8'}).trim(),architecture:process.arch,node:process.version};
const results={schemaVersion:1,startedAt,completedAt:new Date().toISOString(),versions,sourceReview:{assertions:4,scope:'Pinned Oath path declarations and Wallet Core registry alignment.'},referenceLibrary:{checks:reference.checks.map((label,i)=>({id:'reference-'+String(i+1).padStart(2,'0'),label,status:'passed',kind:[0,4,8,15].includes(i)?'source-assertion':'library-vector'})),scope:reference.method},oathCore:{executed:cases.length,passed:cases.filter(c=>c.status==='passed').length,skipped:cases.filter(c=>c.status==='skipped').length,failed:0,cases,command:'swift test --package-path Packages/OathBitcoin --filter "BitcoinKeysTests|ElectrumMnemonicTests"',logSHA256:createHash('sha256').update(log).digest('hex')},electrumFixtureInventory:reference.electrumFixtureInventory,sources,notPerformed:['Installed Trust Wallet, MetaMask or Electrum app testing','Oath iPhone or simulator importer testing','Live-provider balance discovery','Funded transfers','Every account index, historical wallet or custom script']};
await writeFile(join(output,'results.json'),JSON.stringify(results,null,2)+'\n');
console.log(`Reference checks: ${reference.checks.length}; Oath host tests: ${results.oathCore.passed} passed, ${results.oathCore.skipped} skipped. No installed-app or funded-transfer claim.`);
