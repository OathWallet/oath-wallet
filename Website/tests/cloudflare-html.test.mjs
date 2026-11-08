import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {stripCloudflareLabyrinth} from '../scripts/cloudflare-html.mjs';

const origin = 'https://oathwallet.org';
const trap = '<a href="https://oathwallet.org/cdn-cgi/content?id=example-123.abc_DEF" aria-hidden="true" rel="nofollow noopener" style="display: none !important; visibility: hidden !important"></a>';
const content = '<main><h1>Oath</h1><a href="/security">Security</a></main>';

test('only the known empty edge element is removed; Git content must still match', () => {
  assert.equal(stripCloudflareLabyrinth(content, origin), content);
  assert.equal(stripCloudflareLabyrinth(trap + content + trap, origin), content);
  assert.notEqual(stripCloudflareLabyrinth(trap + content.replace('Oath', 'Changed'), origin), content);
  for (const changed of [
    trap.replace('oathwallet.org', 'other.example'),
    trap.replace('/cdn-cgi/content', '/ordinary-page'),
    trap.replace('aria-hidden="true"', 'aria-hidden="false"'),
    trap.replace('nofollow noopener', 'noopener'),
    trap.replace('display: none', 'display: block'),
    trap.replace('></a>', '>Visible content</a>'),
    trap.replace('<a ', '<a onclick="alert(1)" '),
    trap.replace('example-123.abc_DEF', 'example&amp;extra=value'),
  ]) assert.equal(stripCloudflareLabyrinth(changed + content, origin), changed + content);
});

test('the live link audit does not crawl Labyrinth and still checks ordinary nofollow links', () => {
  const result = spawnSync('python3', ['-c', `
import importlib.util, json, sys
sys.path.insert(0, 'scripts')
spec = importlib.util.spec_from_file_location('audit_search', 'scripts/audit-search.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
samples = json.load(sys.stdin)
results = []
for sample in samples:
    page = module.Page(); page.feed(sample); results.append(page.links)
print(json.dumps(results))
`], {
    cwd: fileURLToPath(new URL('../', import.meta.url)),
    input: JSON.stringify([
      trap + content,
      '<a rel="nofollow" href="/bug-bounty">Policy</a>',
      trap.replace('aria-hidden="true"', 'aria-hidden="false"'),
      trap.replace('oathwallet.org', 'other.example'),
      trap.replace('<a ', '<a data-other="true" '),
    ]), encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  const links = JSON.parse(result.stdout);
  assert.deepEqual(links[0], ['/security']);
  assert.deepEqual(links[1], ['/bug-bounty']);
  for (const remaining of links.slice(2)) assert.equal(remaining.length, 1);
});
