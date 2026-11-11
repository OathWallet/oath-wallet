"""Production checks with urllib's own user agent, no cookies, credentials or JavaScript."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import json
import re

from sitemaps import collect_sitemaps

MAIN = 'https://oathwallet.org'
HELP = 'https://help.oathwallet.org'
ARTICLES = 'https://articles.oathwallet.org'
NEWS = 'https://news.oathwallet.org'
WWW = 'https://www.oathwallet.org'


class Direct(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def read(url, media, method='GET', accept=None):
    req = Request(url, method=method, headers={'Accept': accept} if accept else {})
    try:
        response = build_opener(Direct).open(req, timeout=30)
    except HTTPError as error:
        with error:
            raise ValueError(f'{method} {url}: HTTP {error.code}, ray={error.headers.get("CF-Ray")}') from error
    with response:
        mime = response.headers.get_content_type()
        matches = mime.startswith('image/') if media == 'image/*' else mime == media
        if response.status != 200 or not matches or response.headers.get('cf-mitigated') == 'challenge':
            raise ValueError(f'{method} {url}: HTTP {response.status} {mime}, expected {media}')
        data = response.read()
        if bool(data) != (method == 'GET'):
            raise ValueError(f'{method} {url}: unexpected body length {len(data)}')
        return data


def check_file(item):
    url, media = item
    body = read(url, media)
    read(url, media, 'HEAD')
    return body


def check_redirect(url, status, destination):
    for method in ('GET', 'HEAD'):
        try:
            with build_opener(Direct).open(Request(url, method=method), timeout=30):
                raise ValueError(f'{method} {url}: expected redirect')
        except HTTPError as error:
            with error:
                if (error.code, error.headers.get('Location')) != (status, destination):
                    raise ValueError(f'{method} {url}: unexpected HTTP {error.code} or Location') from error


def main():
    manifest = json.loads((Path(__file__).resolve().parents[1] / 'src/tokens-manifest.json').read_text())
    listed = set()
    sitemap_files = 0
    for host in (MAIN, ARTICLES, HELP):
        urls, reports = collect_sitemaps(host + '/sitemap.xml', lambda url: check_file((url, 'application/xml')))
        listed.update(urls)
        sitemap_files += len(reports)
    token_urls = {url for url in listed if urlsplit(url).path == '/tokens'
                  or urlsplit(url).path.startswith('/tokens/') or urlsplit(url).path.endswith('/tokens')}
    directory = MAIN + manifest['documents']
    count = manifest['documentPages']

    def read_index(page):
        url = directory if page == 1 else f'{directory}?page={page}'
        data = json.loads(read(url, 'application/json'))
        expected_next = f'{directory}?page={page + 1}' if page < count else None
        if data['next'] != expected_next or not 1 <= len(data['documents']) <= 100:
            raise ValueError(f'Broken token document pagination at {url}')
        return data['documents']

    samples = set(manifest['samples']) | {'/tokens', '/tokens?page=2'}
    networks = {n['slug'] for n in manifest['networks'].values()}
    samples.update('/networks/' + network + '/tokens' for network in networks)
    if {p.split('/')[-1] for p in manifest['samples'] if p.count('/') == 3} != networks:
        raise ValueError('The release sample must cover every token-capable network')

    def check_token(path):
        url = MAIN + path
        md = urlsplit(url)
        md_url = md._replace(path=md.path + '.md').geturl()
        check_file((url, 'text/html'))
        explicit = check_file((md_url, 'text/markdown'))
        if f'Canonical: {url}'.encode() not in explicit or read(url, 'text/markdown', accept='text/markdown') != explicit:
            raise ValueError(f'Incorrect Markdown representation: {url}')

    with ThreadPoolExecutor(max_workers=4) as pool:
        seen = set()
        for batch in pool.map(read_index, range(1, count + 1)):
            for doc in batch:
                url = doc['url']
                parts = urlsplit(url)
                if url in seen or doc['markdown_url'] != parts._replace(path=parts.path + '.md').geturl():
                    raise ValueError(f'Duplicate or malformed token document: {url}')
                seen.add(url)
        if seen != token_urls:
            raise ValueError(f'Sitemap and token directory differ by {len(seen ^ token_urls)} URLs')
        list(pool.map(check_token, sorted(samples)))

        files = [
            (MAIN + '/mcp', 'application/json'),
            (MAIN + '/.well-known/mcp/server-card.json', 'application/json'),
            (MAIN + '/.well-known/apple-app-site-association', 'application/json'),
            (MAIN + '/site.webmanifest', 'application/manifest+json'),
            (MAIN + '/og/guide-tron.png', 'image/png'),
            (MAIN + '/llms-full.txt', 'text/plain'),
            (MAIN + '/compatibility/2026-11-09.csv', 'text/csv'),
            (MAIN + '/compatibility/2026-11-09.json', 'application/json'),
            (MAIN + '/token-data/' + manifest['version'] + '/manifest.json', 'application/json'),
            (HELP + '/search?q=backup', 'text/html'),
            (HELP + '/help/site-chrome.css', 'text/css'),
            (ARTICLES + '/site.webmanifest', 'application/manifest+json'),
            (ARTICLES + '/feed.xml', 'application/xml'),
            (ARTICLES + '/feed.json', 'application/json'),
            (NEWS + '/', 'text/html'),
            (NEWS + '/news/signup.css', 'text/css'),
            (NEWS + '/news/signup.js', 'text/javascript'),
        ]
        markup = read(MAIN + '/tokens', 'text/html').decode()
        image = re.search(r'src="(/token-artwork/[a-f0-9]+/[a-f0-9]+)"', markup)
        if not image:
            raise ValueError('No published token artwork on the directory')
        # Artwork can be PNG, SVG, WebP or another supported passive image format.
        files.append((MAIN + image[1], 'image/*'))
        for host in (MAIN, HELP, ARTICLES, NEWS):
            files.extend((host + path, mime) for path, mime in (
                ('/.well-known/security.txt', 'text/plain'), ('/robots.txt', 'text/plain'),
                ('/theme.css', 'text/css'), ('/theme.js', 'text/javascript'),
                ('/assets/fonts/oath-fonts.css', 'text/css'), ('/assets/brand/oath-logo.svg', 'image/svg+xml')))
        list(pool.map(check_file, files))

    for source, code, dest in (
            (WWW + '/tokens/usdt', 301, MAIN + '/tokens/usdt'),
            (WWW + '/security.txt', 308, MAIN + '/.well-known/security.txt'),
            (MAIN + '/newsletter', 308, NEWS + '/'), (MAIN + '/support', 308, HELP + '/')):
        check_redirect(source, code, dest)
    payload = json.dumps({'jsonrpc':'2.0', 'id':1, 'method':'tools/list'}).encode()
    req = Request(MAIN + '/mcp', data=payload, headers={'Content-Type':'application/json'})
    with build_opener(Direct).open(req, timeout=30) as response:
        tools = {tool['name'] for tool in json.load(response)['result']['tools']}
        if not {'read_document','list_documents','get_feature'} <= tools:
            raise ValueError('The public MCP tools could not be discovered')
    print(f'Default urllib: {sitemap_files} XML files, {len(listed):,} unique sitemap URLs; '
          f'{count} token index pages, {len(seen):,} matching documents; '
          f'{len(samples)} live HTML/Markdown samples across {len(networks)} token networks; '
          f'{len(files)} public files and 4 redirect routes verified with GET and HEAD; '
          f'{len(tools)} MCP tools discovered via JSON POST.')


if __name__ == '__main__':
    main()
