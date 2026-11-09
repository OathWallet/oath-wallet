// Retire the former trading screens and their assets/APIs before other routing
// or static asset fallbacks can expose an old copy of the interface.
export function handleRetiredTradingPages(request) {
  const url = new URL(request.url);
  if (!/^\/(?:ousd|swaps?)(?:\/|\.(?:html|md)$|$)/i.test(url.pathname)) return null;
  return new Response(request.method === 'HEAD' ? null : 'This page is no longer available.', {
    status: 410,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    }
  });
}
