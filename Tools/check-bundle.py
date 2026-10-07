#!/usr/bin/env python3
"""Read-only bundle validation. Does not run the app or register its widget.

Every check is an explicit `check(...)` rather than a bare `assert`: this script
is the gate that decides whether a signed bundle may be reused by the build
cache, and `assert` is stripped by `PYTHONOPTIMIZE`/`python3 -O`. With asserts
alone, a user-level `PYTHONOPTIMIZE=1` made a bundle with the wrong App Group
print PASS and stay "verified" for every later build. `build.sh` also invokes
this with `-E -s` so the environment cannot change how it reads the bundle.
"""
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def check(condition, message):
    if not condition:
        raise SystemExit(f'FAIL: {message} ({app})')


app = Path(sys.argv[1])
channel = sys.argv[2]
identity = {'dev': ('ClaudeBar Dev', 'ClaudeBarDev', 'com.claudebar.app.dev', 'claudebar-dev'),
            'release': ('ClaudeBar', 'ClaudeBar', 'com.claudebar.app', 'claudebar')}[channel]
name, executable, bundle_id, scheme = identity
widget = app / 'Contents/PlugIns/ClaudeBarWidget.appex'
try:
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    with (widget / 'Contents/Info.plist').open('rb') as stream:
        widget_info = plistlib.load(stream)
except OSError as error:
    raise SystemExit(f'FAIL: unreadable bundle at {app}: {error}')

check(info['CFBundleIdentifier'] == bundle_id, f'CFBundleIdentifier is {info["CFBundleIdentifier"]!r}, want {bundle_id!r}')
check(info['CFBundleExecutable'] == executable, f'CFBundleExecutable is {info["CFBundleExecutable"]!r}, want {executable!r}')
check(info['CFBundleDisplayName'] == name, f'CFBundleDisplayName is {info["CFBundleDisplayName"]!r}, want {name!r}')
check(info['ClaudeBarBuildChannel'] == channel, f'ClaudeBarBuildChannel is {info.get("ClaudeBarBuildChannel")!r}, want {channel!r}')
check(info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == [scheme], 'URL scheme does not match the channel')
check(widget_info['CFBundleIdentifier'] == bundle_id + '.widget', 'widget bundle id does not follow the app id')
version = (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
check(info['CFBundleShortVersionString'] == version and widget_info['CFBundleShortVersionString'] == version,
      'CFBundleShortVersionString does not match VERSION')
check(info['CFBundleVersion'] == version and widget_info['CFBundleVersion'] == version,
      'CFBundleVersion does not match VERSION')
check((app / 'Contents/MacOS' / executable).is_file(), 'the app executable is missing')
cli_name = 'claudebar' if channel == 'release' else 'claudebar-dev'
cli = app / 'Contents/Helpers' / cli_name
check(cli.is_file() and cli.stat().st_mode & 0o111, 'the channel CLI executable is missing')
subprocess.run(['codesign', '--verify', '--strict', str(cli)], check=True)
cli_signature = subprocess.run(['codesign', '-dv', str(cli)], check=True, capture_output=True, text=True)
check(f'Identifier={bundle_id}.cli' in cli_signature.stderr.splitlines(), 'CLI signing identity does not match channel')
cli_version = json.loads(subprocess.check_output([str(cli), 'version', '--json'], text=True))
check(cli_version['channel'] == channel and cli_version['version'] == version, 'CLI compiled channel/version does not match app')
if channel == 'dev':
    # A dev build must wear the DEV icon; the release icon is the only other
    # possibility, and a swapped pair is how a dev build ships as a release.
    check((app / 'Contents/Resources/AppIcon.icns').read_bytes()
          == (Path(__file__).resolve().parents[1] / 'Sources/AppIcon-Dev.icns').read_bytes(),
          'the dev bundle is not carrying the DEV icon')
check((widget / 'Contents/MacOS/ClaudeBarWidget').is_file(), 'the widget executable is missing')
for bundle in [app, widget]:
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], check=True, capture_output=True)
    entitlements = plistlib.loads(result.stdout)
    check(entitlements['com.apple.security.application-groups'] == [bundle_id + '.widget'],
          f'{bundle.name} is not entitled to the {bundle_id}.widget group')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'PASS: {channel} bundle, widget, URL scheme, entitlements and signature ({app})')
