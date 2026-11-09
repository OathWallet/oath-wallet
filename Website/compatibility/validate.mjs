import assert from 'node:assert/strict';
export function validateEdition(data) {
 assert.equal(data.schemaVersion,1);
 assert.match(data.edition,/^\d{4}-\d{2}-\d{2}$/);
 const e=data.evidence;
 assert.equal(e.versions.oath,'5.0.2'); assert.equal(e.versions.build,104);
 assert.match(e.versions.sourceCommit,/^[a-f0-9]{40}$/);
 assert.equal(e.versions.walletCore,'4.8.4');
 assert.equal(e.referenceLibrary.checks.length,18);
 for(const c of e.referenceLibrary.checks){assert.equal(c.status,'passed');assert.ok(['source-assertion','library-vector'].includes(c.kind));}
 for(const c of e.oathCore.cases)assert.ok(['passed','skipped'].includes(c.status));
 assert.equal(new Set([...e.referenceLibrary.checks,...e.oathCore.cases].map(c=>c.id)).size,e.referenceLibrary.checks.length+e.oathCore.cases.length);
 assert.equal(e.referenceLibrary.checks.filter(c=>c.kind==='source-assertion').length,e.sourceReview.assertions);
 assert.equal(e.oathCore.failed,0);
 assert.equal(e.oathCore.passed,e.oathCore.cases.filter(c=>c.status==='passed').length);
 assert.equal(e.oathCore.skipped,e.oathCore.cases.filter(c=>c.status==='skipped').length);
 assert.equal(e.oathCore.executed,e.oathCore.passed+e.oathCore.skipped);
 assert.equal(e.oathCore.cases.find(c=>c.id.includes('CoreFundedRecovery'))?.status,'skipped');
 const checks=new Map([...e.referenceLibrary.checks,...e.oathCore.cases].map(c=>[c.id,c]));
 const levels=new Set(data.levels.map(l=>l.id)); const ids=new Set();
 for(const row of [...data.rows,...data.bitcoin]) {
  assert.match(row.id,/^[a-z][a-z0-9-]+$/);assert.ok(!ids.has(row.id));ids.add(row.id);
  for(const id of row.checks)assert.equal(checks.get(id)?.status,'passed',id);
  if(row.wallet){
   assert.ok(levels.has(row.evidenceLevel));assert.ok(row.limitation.length>40);
   if(row.evidenceLevel==='core')assert.ok(row.checks.some(id=>e.oathCore.cases.some(c=>c.id===id)));
   if(row.evidenceLevel==='reference')assert.ok(row.checks.some(id=>checks.get(id)?.kind==='library-vector'));
   if(row.evidenceLevel==='unverified')assert.equal(row.checks.length,0);
   if(row.guide)assert.equal(new URL(row.guide).origin,'https://articles.oathwallet.org');
  }
 }
 for(const app of data.thirdPartyApps){assert.equal(app.testedVersion,null);assert.match(app.status,/Not installed/);}
 for(const source of e.sources){assert.match(source.sha256,/^[a-f0-9]{64}$/);assert.ok(!source.path.startsWith('/')&&!source.path.includes('..'));}
 for(const source of data.sources)assert.equal(new URL(source.url).protocol,'https:');
 // Public reports contain results, not fixture recovery material or machine paths.
 const json=JSON.stringify(data);
 assert.doesNotMatch(json,/abandon abandon|(?:xprv|yprv|zprv)[1-9A-HJ-NP-Za-km-z]{40,}|\/Users\/|\/Volumes\/|"(?:mnemonic|privateKey|seedHex|password)"\s*:/i);
 assert.ok(e.notPerformed.length>=5);
 assert.ok(data.changes.length>0);
 assert.equal(data.evidence.versions.sourceCommit,'d039b009d8c81b0497f2ac7e6abebfdf54ff8612');
 return data;
}
export function matrixCSV(data){
 const quote=value=>'"'+(/^[=+@-]/.test(String(value))?"'":'')+String(value).replaceAll('"','""')+'"';
 const columns=['edition','wallet','account','path','result','evidence','scope','limitation','url'];
 return [columns,...data.rows.map(r=>[data.edition,r.wallet,r.account,r.path,r.result,data.levels.find(l=>l.id===r.evidenceLevel).label,r.scope,r.limitation,`https://oathwallet.org/compatibility/${data.edition}#${r.id}`])].map(r=>r.map(quote).join(',')).join('\r\n')+'\r\n';
}
