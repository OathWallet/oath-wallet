#!/usr/bin/env python3
"""Opt-in isolated keyboard/accessory check; no wallet, signing, or phone."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
parser = argparse.ArgumentParser()
parser.add_argument('--simulator-check', action='store_true')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not args.simulator_check:
    parser.error('State the unresolved keyboard/accessory concern before opting in.')
root = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='oath-browser-address-') as directory:
    work = Path(directory)
    names = ['OathBrowserModel.swift', 'OathBrowserPolicy.swift', 'OathBrowserTabs.swift', 'OathBrowserBottomBar.swift']
    for name in names:
        shutil.copyfile(root/'OathAtmosphere/Browser'/name, work/name)
    shared = ['OathTextInput.swift', 'OathTextInputFocus.swift', 'OathEntryTextField.swift', 'OathKeyboardAccessory.swift']
    for name in shared:
        shutil.copyfile(root/'OathAtmosphere/Shared'/name, work/name)
    for name in ['AddressBarSupport.swift', 'AddressBarUITests.swift']:
        shutil.copyfile(root/'Tools/BrowserValidation'/name, work/name)
    spec = {'name':'AddressBarFixture', 'options':{'deploymentTarget':{'iOS':'27.0'}},
        'settings':{'base':{'SWIFT_VERSION':'6.0','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGNING_ALLOWED':'NO'}},
        'packages':{'OathDiagnostics':{'path':str(root/'Packages/OathDiagnostics')}},
        'targets':{
            'AddressBarFixture':{'type':'application','platform':'iOS','sources':['AddressBarSupport.swift']+names+shared,
                'dependencies':[{'package':'OathDiagnostics'}],
                'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'org.oathwallet.tests.addressbar','INFOPLIST_KEY_UILaunchScreen_Generation':'YES'}}},
            'AddressBarUITests':{'type':'bundle.ui-testing','platform':'iOS','sources':['AddressBarUITests.swift'],
                'dependencies':[{'target':'AddressBarFixture'}],
                'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'org.oathwallet.tests.addressbar.uitests'}}}},
        'schemes':{'AddressBarFixture':{'build':{'targets':{'AddressBarFixture':'all'}},'test':{'targets':['AddressBarUITests']}}}}
    (work/'project.yml').write_text(json.dumps(spec))
    subprocess.run(['xcodegen','generate','--spec',str(work/'project.yml')],check=True,capture_output=True)
    device = subprocess.check_output(['xcrun','simctl','create','Oath Address '+uuid.uuid4().hex[:8],
        'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max','com.apple.CoreSimulator.SimRuntime.iOS-27-0'],text=True).strip()
    try:
        subprocess.run(['xcrun','simctl','boot',device],check=True,capture_output=True,timeout=60)
        with (args.output/'boot.log').open('w') as log:
            subprocess.run(['xcrun','simctl','bootstatus',device,'-b'],check=True,stdout=log,stderr=subprocess.STDOUT,timeout=180)
        with (args.output/'test.log').open('w') as log:
            result = subprocess.run(['xcodebuild','-project',str(work/'AddressBarFixture.xcodeproj'),'-scheme','AddressBarFixture',
                '-destination','platform=iOS Simulator,id='+device,'-parallel-testing-enabled','NO',
                '-derivedDataPath',str(work/'build'),'-resultBundlePath',str(args.output/'AddressBar.xcresult'),
                'test'], stdout=log,stderr=subprocess.STDOUT,timeout=360)
        result.check_returncode()
        print('PASS: inline keyboard/accessory placement and new-tab focus.')
    finally:
        subprocess.run(['xcrun','simctl','shutdown',device],capture_output=True,timeout=30)
        subprocess.run(['xcrun','simctl','delete',device],capture_output=True,timeout=30)
