import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import release from '../content/published-source-release.json' with {type:'json'};
import evidence from '../content/release-evidence.json' with {type:'json'};
import features from '../content/features.json' with {type:'json'};
import guidance from '../content/priority-guidance.json' with {type:'json'};
import help from '../src/help/content.json' with {type:'json'};
import tokens from '../src/tokens-manifest.json' with {type:'json'};
import {currentStatus} from '../src/agent-content.js';

test('every current release identity agrees with the published version, build and revision',()=>{
  for(const item of [evidence,features,guidance,tokens.source,currentStatus,currentStatus.guide_source]){
    assert.equal(item.version,release.version);
    assert.equal(item.build,release.build);
    const revision=item.source_commit??item.sourceCommit??item.revision;
    if(revision)assert.equal(revision,release.source_commit);
  }
  for(const article of help.articles){
    assert.equal(article.app_version,`Oath ${release.version} (${release.build})`);
    assert.equal(article.screenshot_version,'Historical app capture');
  }
  assert.equal(currentStatus.app_store.build,null);
  assert.equal(currentStatus.distribution_status,'SOURCE_RELEASE_PUBLISHED');
});

test('published page copy contains no retired Oath release labels or mismatched build labels',async()=>{
  const root=new URL('../public/',import.meta.url),failures=[];
  const retired=/(?<![\w.])v?(?:4\.0\.(?:0|3)|4\.1\.(?:2|3|14|15)|5\.0\.\d+|5\.1\.0)(?!\w|\.\d)/;
  async function inspect(dir){
    for(const item of await readdir(dir,{withFileTypes:true})){
      const path=new URL(item.name+(item.isDirectory()?'/':''),dir);
      if(item.isDirectory()){await inspect(path);continue;}
      if(!/\.(html|md)$/.test(item.name))continue;
      if(path.pathname.includes('/compatibility/2026-11-26.'))continue;
      let text=await readFile(path,'utf8');
      text=text.replace(/<script\b[^>]*>[\s\S]*?<\/script>|<style\b[^>]*>[\s\S]*?<\/style>|<!--[\s\S]*?-->/gi,'');
      text=text.replace(/<[^>]+>/g,' ').replace(/\]\(https?:\/\/[^)]+\)/g,']').replace(/https?:\/\/[^\s<>]+/g,'');
      const match=retired.exec(text)??/\b5\.1\.2\s*\((?!112\))\d+\)|\bbuild\s+(?!112\b)\d+/i.exec(text);
      if(match)failures.push(path.pathname.slice(root.pathname.length)+': '+text.slice(Math.max(0,match.index-40),match.index+80).replace(/\s+/g,' '));
    }
  }
  await inspect(root);
  assert.deepEqual(failures,[]);
});
