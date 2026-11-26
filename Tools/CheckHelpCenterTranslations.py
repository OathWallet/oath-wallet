#!/usr/bin/env python3
"""Offline coverage/source/name checks for app-only Help Center translations."""
import argparse
import json
from pathlib import Path
import re
from CheckLocalizationCatalog import BRANDS, normalized

ROOT = Path(__file__).resolve().parents[1]
NAMES = re.compile(BRANDS.pattern + r'|\b(?:BIP-39|EVM|NFT|HD|QR|iOS|Phantom|Trust Wallet|Devnet|Testnet|Apple|Permit2|TON)\b|care@oathwallet\.org')


def source_strings(catalog):
    values = {f'category.{row["id"]}': row['title'] for row in catalog['categories']}
    for row in catalog['articles']:
        for field in ('title', 'summary'):
            values[f'article.{row["id"]}.{field}'] = row[field]
    return values


def audit(catalog, translations, languages):
    errors = []
    source = source_strings(catalog)
    if translations.get('version') != 1 or translations.get('source') != source:
        errors.append('Translation source differs from current published article titles/summaries')
    locales = translations.get('localizations', {})
    if set(locales) != set(languages) - {'en'}:
        errors.append('Translation locales differ from the supported app languages')
    for locale, values in locales.items():
        if set(values) != set(source):
            errors.append(f'{locale}: missing or unexpected article/category fields')
        for key, english in source.items():
            value = values.get(key)
            if not isinstance(value, str) or not value.strip() or len(value) > 4_000:
                errors.append(f'{locale}/{key}: missing, empty or oversized text')
                continue
            if normalized(value) == normalized(english):
                errors.append(f'{locale}/{key}: untranslated English')
            if re.search(r'ZXQ|\[\d{3}\]', value, re.I):
                errors.append(f'{locale}/{key}: unresolved translation marker')
            for name in set(NAMES.findall(english)):
                if name not in value:
                    errors.append(f'{locale}/{key}: canonical name missing: {name}')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, default=ROOT / 'OathApp/Resources')
    args = parser.parse_args()
    catalog = json.loads((args.resources / 'HelpCenterArticles.json').read_text())
    translations = json.loads((args.resources / 'HelpCenterTranslations.json').read_text())
    languages = [row['code'] for row in json.loads((ROOT / 'Design/Localization/languages.json').read_text())]
    errors = audit(catalog, translations, languages)
    if errors:
        print('\n'.join(errors))
        raise SystemExit(f'Help Center translation audit failed: {len(errors)} findings')
    print(f'PASS: {len(source_strings(catalog))} fields across {len(languages)} languages, exact source coverage and canonical names')
