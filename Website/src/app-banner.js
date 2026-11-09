// Apple's native Safari banner needs only the App Store ID. No app-argument:
// website URLs and query strings must not be forwarded into wallet actions.
// https://developer.apple.com/documentation/webkit/promoting-apps-with-smart-app-banners
export const appBanner = '<meta name="apple-itunes-app" content="app-id=6780187283">';

export async function applyAppBanner(request, response) {
  if (request.method !== 'GET' || !response.ok || response.body === null ||
      !response.headers.get('Content-Type')?.includes('text/html')) return response;
  let path = new URL(request.url).pathname;
  try { path = decodeURIComponent(path); } catch {}
  // Embedded design documents and ownership-verification files are not pages.
  if (path.endsWith('.dc.html') || /\/yandex_[a-f0-9]+\.html$/i.test(path)) return response;
  const html = await response.text();
  const updated = html.replace(/<head\b[^>]*>[\s\S]*?<\/head>/i, head => {
    const clean = head.replace(/<meta\b(?=[^>]*\bname\s*=\s*(["'])apple-itunes-app\1)[^>]*>/gi, '');
    return clean.replace(/<\/head>/i, appBanner + '</head>');
  });
  const headers = new Headers(response.headers);
  if (updated !== html) { headers.delete('Content-Length'); headers.delete('ETag'); }
  return new Response(updated, {status:response.status, statusText:response.statusText, headers});
}
