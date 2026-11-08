#!/usr/bin/env python3
"""Regression fixtures for the real SwiftSyntax UI-text scanner; host only."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]

class SourceAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='oath-source-audit-test-')
        cls.work = Path(cls.temp.name)
        swift = Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip())
        host = swift.parent.parent/'lib/swift/host'
        sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
        cls.scanner = cls.work/'scan'
        subprocess.run([str(swift),'-target',platform.machine()+'-apple-macosx14.0','-sdk',sdk,'-I',str(host),'-L',str(host),'-lSwiftParser','-lSwiftSyntax','-Xlinker','-rpath','-Xlinker',str(host),str(ROOT/'Tools/ScanLocalizationSource.swift'),'-o',str(cls.scanner)],check=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def scan(self, source):
        (self.work/'Fixture.swift').write_text(source)
        (self.work/'files').write_text('Fixture.swift\n')
        subprocess.run([str(self.scanner),str(self.work),str(self.work/'files'),str(self.work/'out.json')],check=True,capture_output=True)
        return json.loads((self.work/'out.json').read_text())
    def testUIAndAccessibilityCopyAreDetected(self):
        records = self.scan('''Text("Missed label")
Label("Bookmark", systemImage: "bookmark")
TextField("Enter address", text: $address)
OathSettingsRow(title: "Untranslated", icon: "gear")
view.accessibilityLabel("Close the page")
view.navigationTitle("New screen")
Text(active ? "First branch" : "Second branch")
Text("نص غير مترجم")
''')
        labels = {x['text'] for x in records if x['directUI']}
        self.assertEqual(labels, {'Missed label','Bookmark','Enter address','Untranslated','Close the page','New screen','First branch','Second branch','نص غير مترجم'})
    def testProtocolConditionsAndDebugFixturesDoNotBecomeUI(self):
        records = self.scan('''Text(payload["TransactionType"].string ?? "")
Text(network == "stellar" ? strings.text(.send) : strings.text(.receive))
#if DEBUG && targetEnvironment(simulator)
Text("Fixture only")
#endif
Text(strings.text(.title))
''')
        self.assertFalse(any(x['directUI'] and x['text'] in {'TransactionType','stellar'} for x in records))
        debug = next(x for x in records if x['text']=='Fixture only')
        self.assertTrue(debug['debugOnly'])
        self.assertTrue(debug['directUI'])

if __name__=='__main__': unittest.main()
