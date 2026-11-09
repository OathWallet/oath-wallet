import contact from '../content/security-contact.json' with {type: 'json'};

export const securityTxtPath = '/.well-known/security.txt';
export const securityHosts = Object.freeze([...contact.hosts]);

export function renderSecurityTxt(host) {
  if (!securityHosts.includes(host)) throw new Error('Unknown security.txt host');
  return [
    '# Oath Wallet vulnerability reporting - RFC 9116',
    `# Reporting details reviewed: ${contact.reviewedOn}`,
    '# Use GitHub private vulnerability reporting as the preferred channel.',
    '# If unavailable, email care@oathwallet.org to arrange a private report.',
    ...contact.contacts.map(uri => `Contact: ${uri}`),
    `Expires: ${contact.expires}`,
    `Preferred-Languages: ${contact.preferredLanguages.join(', ')}`,
    `Canonical: https://${host}${securityTxtPath}`,
    `Policy: ${contact.policy}`,
    '',
    '# Read the policy for scope, safe testing rules and reward eligibility.',
    '# Do not send real recovery phrases, private keys, passwords or wallet backups.',
    '# This file does not authorize testing beyond the published policy.',
    ''
  ].join('\n');
}

// Handle these paths before host-specific HTML routing. No provider, session,
// JavaScript rendering or asset fetch is needed to discover the reporting route.
export function handleSecurityTxt(request) {
  const url = new URL(request.url);
  if (!securityHosts.includes(url.hostname)
      || ![securityTxtPath, '/security.txt'].includes(url.pathname)) return null;
  const headers = {
    'Content-Type': 'text/plain; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'public, max-age=3600, must-revalidate',
    'Access-Control-Allow-Origin': '*'
  };
  if (!['GET', 'HEAD'].includes(request.method)) {
    return new Response('Method not allowed\n', {
      status: 405, headers: {...headers, Allow: 'GET, HEAD', 'Cache-Control': 'no-store'}
    });
  }
  const host = url.hostname === 'www.oathwallet.org' ? 'oathwallet.org' : url.hostname;
  const canonical = `https://${host}${securityTxtPath}`;
  if (url.protocol !== 'https:' || url.hostname !== host || url.pathname !== securityTxtPath) {
    return new Response(null, {status: 308, headers: {...headers, Location: canonical}});
  }
  return new Response(request.method === 'HEAD' ? null : renderSecurityTxt(host), {
    headers: {...headers, Link: `<${canonical}>; rel="canonical"`}
  });
}
