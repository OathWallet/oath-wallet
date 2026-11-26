#!/usr/bin/env python3
"""Bundle every published Help Center article for private, offline native search.

Run manually when publishing help content. --check verifies the bundle against
the live sitemap/content without changing files. Never reads app or wallet data.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'OathApp/Resources/HelpCenterArticles.json'
ORIGIN = 'https://help.oathwallet.org'
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}


def fetch(path):
    with urlopen(Request(ORIGIN + path, headers={'User-Agent': 'Oath-Help-Catalog/1.0'}), timeout=30) as response:
        if not response.url.startswith(ORIGIN + '/'):
            raise ValueError('Help page redirected outside the Help Center')
        data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValueError('Help page exceeds catalog limit')
        return data.decode('utf-8')


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.title = []
        self.category = None
        self.category_title = []
        self.summary = ''
        self.body = []
        self.canonical = None
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'meta' and attrs.get('name') == 'description':
            self.summary = attrs['content']
        if tag == 'link' and attrs.get('rel') == 'canonical':
            self.canonical = attrs['href']
        if tag == 'a' and attrs.get('class') == 'category-label':
            self.category = attrs['href'].removeprefix('/collections/')
        if tag not in VOID:
            self.stack.append((tag, attrs))

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                return

    def handle_data(self, text):
        if any(t == 'h1' for t, _ in self.stack):
            self.title.append(text)
        if any(a.get('class') == 'category-label' for _, a in self.stack):
            self.category_title.append(text)
        if any(t == 'article' for t, _ in self.stack) and not any(
            t in {'script', 'style', 'nav'} or a.get('class') in {'meta', 'article-feedback'} or a.get('id') == 'related'
            for t, a in self.stack
        ):
            self.body.append(text)


def clean(parts):
    return ' '.join(' '.join(parts).split())


def article(path):
    page = Page(fetch(path))
    slug = path.removeprefix('/articles/')
    if (not re.fullmatch(r'[a-z0-9-]+', slug) or not page.category or not page.title
            or not page.summary or len(clean(page.body)) < 80 or page.canonical != ORIGIN + path):
        raise ValueError('Incomplete article: ' + path)
    return {'id': slug, 'categoryID': page.category, 'title': clean(page.title),
            'summary': page.summary, 'body': clean(page.body)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    sitemap = ET.fromstring(fetch('/sitemap.xml'))
    urls = [node.text for node in sitemap.findall('{*}url/{*}loc')]
    paths = [url.removeprefix(ORIGIN) for url in urls if url.startswith(ORIGIN + '/articles/')]
    collection_paths = [url.removeprefix(ORIGIN) for url in urls if url.startswith(ORIGIN + '/collections/')]
    if not paths or len(paths) != len(set(paths)):
        raise ValueError('Empty or duplicate sitemap articles')
    with ThreadPoolExecutor(max_workers=8) as pool:
        articles = list(pool.map(article, paths))
        pages = list(pool.map(lambda path: Page(fetch(path)), collection_paths))
    categories = [{'id': path.removeprefix('/collections/'), 'title': clean(page.title)}
                  for path, page in zip(collection_paths, pages)]
    if not all(c['title'] for c in categories) or set(a['categoryID'] for a in articles) != set(c['id'] for c in categories):
        raise ValueError('Article categories do not match published collections')
    payload = {'version': 1, 'generatedAt': datetime.now(timezone.utc).strftime('%Y-%m-%d'),
               'categories': categories, 'articles': articles}
    if args.check:
        bundled = json.loads(DESTINATION.read_text())
        if any(bundled.get(key) != payload[key] for key in ['version', 'categories', 'articles']):
            raise ValueError('Bundled catalog differs from the published Help Center; regenerate it')
    else:
        DESTINATION.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    print(f"{'Verified' if args.check else 'Bundled'} {len(articles)} articles in {len(categories)} categories")


if __name__ == '__main__':
    main()
