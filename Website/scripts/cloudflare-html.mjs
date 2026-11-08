// Cloudflare AI Labyrinth inserts an empty, hidden nofollow link with a changing
// ID. Ignore only this observed edge-owned element when comparing Git content.
// Unknown attributes, visible text, other hosts and other paths remain intact.
// https://developers.cloudflare.com/bots/additional-configurations/ai-labyrinth/
export function stripCloudflareLabyrinth(html, origin) {
  return html.replace(/<a href="(https:\/\/[a-z0-9.-]+\/cdn-cgi\/content\?id=[A-Za-z0-9._-]{1,1024})" aria-hidden="true" rel="nofollow noopener" style="display: none !important; visibility: hidden !important"><\/a>/g,
    (element, href) => new URL(href).origin === origin ? '' : element);
}
