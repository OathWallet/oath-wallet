import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import contact from '../content/security-contact.json' with {type: 'json'};
import {renderSecurityTxt} from '../src/security-txt.js';

// Expiry is deliberately reviewed, never silently extended by a build or fetch.
const day = 86400000;
const expires = Date.parse(contact.expires);
assert.match(contact.expires, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
assert.ok(expires > Date.now() + 30 * day,
  'Review security-contact.json and renew security.txt: fewer than 30 days remain.');
assert.ok(expires < Date.now() + 366 * day, 'security.txt expiry must be less than a year away.');
assert.ok(Date.parse(contact.reviewedOn) <= Date.now(), 'Security contact review cannot be future-dated.');
assert.ok(contact.contacts.length > 0);
for (const uri of [...contact.contacts, contact.policy]) {
  const parsed = new URL(uri);
  assert.ok(['https:', 'mailto:'].includes(parsed.protocol));
  assert.ok(!/[\r\n]/.test(uri));
}
await writeFile(new URL('../public/.well-known/security.txt', import.meta.url), renderSecurityTxt('oathwallet.org'));
console.log(`Validated security.txt for ${contact.hosts.length} website hosts; reviewed ${contact.reviewedOn}, expires ${contact.expires}.`);
