#!/usr/bin/env python3
"""Host-only regression checks for Help Center translation release validation."""
import copy
import unittest
from CheckHelpCenterTranslations import audit, source_strings


class HelpTranslationAuditTests(unittest.TestCase):
    def setUp(self):
        self.catalog = {
            'categories': [{'id': 'wallets', 'title': 'Your wallets'}],
            'articles': [{'id': 'example', 'title': 'Use Oath', 'summary': 'Open your wallet.'}],
        }
        self.document = {
            'version': 1, 'source': source_strings(self.catalog),
            'localizations': {'ar': {
                'category.wallets': 'محافظك', 'article.example.title': 'استخدام Oath',
                'article.example.summary': 'افتح محفظتك.',
            }},
        }

    def check_document(self, document):
        return audit(self.catalog, document, ['en', 'ar'])

    def test_complete_translation(self):
        self.assertEqual(self.check_document(self.document), [])

    def test_website_source_change_requires_translation_refresh(self):
        self.document['source']['article.example.title'] = 'Old title'
        self.assertTrue(self.check_document(self.document))

    def test_missing_locale_and_missing_field(self):
        for action in ('locale', 'field'):
            with self.subTest(action=action):
                changed = copy.deepcopy(self.document)
                if action == 'locale':
                    del changed['localizations']['ar']
                else:
                    del changed['localizations']['ar']['article.example.summary']
                self.assertTrue(self.check_document(changed))

    def test_corrupted_or_untranslated_fields(self):
        for value in ('', 'Use Oath', 'استخدام ZXQNAME0ZXQ', 'استخدام اسم آخر'):
            with self.subTest(value=value):
                changed = copy.deepcopy(self.document)
                changed['localizations']['ar']['article.example.title'] = value
                self.assertTrue(self.check_document(changed))


if __name__ == '__main__':
    unittest.main()
