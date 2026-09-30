#!/usr/bin/env python3
"""Read-only bundle validation. Does not run the app or register its widget."""
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
channel = sys.argv[2]
identity = {'dev': ('ClaudeBar Dev', 'ClaudeBarDev', 'com.claudebar.app.dev', 'claudebar-dev'),
            'release': ('ClaudeBar', 'ClaudeBar', 'com.claudebar.app', 'claudebar')}[channel]
name, executable, bundle_id, scheme = identity
widget = app / 'Contents/PlugIns/ClaudeBarWidget.appex'
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
with (widget / 'Contents/Info.plist').open('rb') as stream:
    widget_info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == bundle_id
assert info['CFBundleExecutable'] == executable
assert info['CFBundleDisplayName'] == name
assert info['ClaudeBarBuildChannel'] == channel
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == [scheme]
assert widget_info['CFBundleIdentifier'] == bundle_id + '.widget'
version = (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
assert info['CFBundleShortVersionString'] == widget_info['CFBundleShortVersionString'] == version
assert info['CFBundleVersion'] == widget_info['CFBundleVersion'] == version
assert (app / 'Contents/MacOS' / executable).is_file()
if channel == 'dev':
    assert (app / 'Contents/Resources/AppIcon.icns').read_bytes() == (Path(__file__).resolve().parents[1] / 'Sources/AppIcon-Dev.icns').read_bytes()
assert (widget / 'Contents/MacOS/ClaudeBarWidget').is_file()
for bundle in [app, widget]:
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    assert entitlements['com.apple.security.application-groups'] == [bundle_id + '.widget']
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'PASS: {channel} bundle, widget, URL scheme, entitlements and signature ({app})')
